#!/usr/bin/env python3
"""Fetch public-domain botanical plates for the herbarium asset set.

Why real plates rather than generated images: the chosen art direction *is*
Victorian botanical plates, and Köhler's Medizinal-Pflanzen (1887) is the
reference itself rather than an approximation of it. The originals carry the
numbered dissection details in the margins that make a plate read as a
scientific record; that detail is what sells the herbarium idea, and it is
exactly what a text-to-image model tends to smear.

Everything here is public domain (published 1887, author died 1898). Attribution
is still recorded per plate, because a collection that cites its sources is the
point of the aesthetic.

Run: python3 Tools/fetch-plates.py [--limit N]
Writes: Assets/Plates/*.jpg and Assets/Plates/plates.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://commons.wikimedia.org/w/api.php"
UA = "lecture-notes-app/0.1 (https://github.com/toyeshhm; personal study tool)"
SOURCE_CATEGORY = "Köhler's Medizinal-Pflanzen"

OUT = Path(__file__).resolve().parent.parent / "Assets" / "Plates"


def _get(params: dict[str, str]) -> dict:
    url = API + "?" + urllib.parse.urlencode({**params, "format": "json"})
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as fh:
        return json.load(fh)


# A plate is only useful if we can name its species: the binomial is shown in the
# sidebar beside the course. Titles in the series are inconsistent
# ("File:Köhler Walnuss 1887.jpg", "File:Anthemis arvensis Koeh desc.jpg"), so
# anything that is not a clean "Genus species" is dropped rather than shown
# mangled.
BINOMIAL = re.compile(r"^([A-Z][a-z]+ [a-z][a-z-]+)")


def species_from_title(title: str) -> str:
    """'File:Elettaria cardamomum - Köhler-s ...-050.jpg' -> 'Elettaria cardamomum'."""
    name = title.removeprefix("File:").split(" - ")[0]
    name = re.sub(r"\.(jpg|jpeg|png)$", "", name, flags=re.I)
    match = BINOMIAL.match(re.sub(r"\s+", " ", name).strip())
    return match.group(1) if match else ""


def search_plates(limit: int) -> list[dict]:
    """Plates from the Köhler series, newest-relevance first."""
    out: list[dict] = []
    offset = 0
    seen_species: set[str] = set()

    while len(out) < limit and offset < 400:
        data = _get({
            "action": "query",
            "generator": "search",
            "gsrsearch": f'"{SOURCE_CATEGORY}"',
            "gsrnamespace": "6",
            "gsrlimit": "50",
            "gsroffset": str(offset),
            "prop": "imageinfo",
            "iiprop": "url|extmetadata",
            "iiurlwidth": "1200",
        })
        pages = (data.get("query") or {}).get("pages") or {}
        if not pages:
            break

        for page in sorted(pages.values(), key=lambda p: p.get("index", 0)):
            info = (page.get("imageinfo") or [{}])[0]
            meta = info.get("extmetadata", {})
            licence = meta.get("LicenseShortName", {}).get("value", "")
            # Only ship what is unambiguously public domain.
            if "public domain" not in licence.lower():
                continue

            species = species_from_title(page["title"])
            # One plate per species: the sidebar should not show the same plant
            # twice under different courses.
            if not species or species in seen_species:
                continue
            seen_species.add(species)

            out.append({
                "species": species,
                "title": page["title"],
                "url": info.get("thumburl") or info.get("url", ""),
                "descriptionUrl": info.get("descriptionurl", ""),
                "licence": licence,
                "credit": "Franz Eugen Köhler, Köhler's Medizinal-Pflanzen (1887)",
            })
            if len(out) >= limit:
                break

        offset += 50
        time.sleep(0.6)  # be a polite API citizen

    return out


def download(plates: list[dict]) -> list[dict]:
    OUT.mkdir(parents=True, exist_ok=True)
    kept: list[dict] = []

    for plate in plates:
        slug = re.sub(r"[^a-z0-9]+", "-", plate["species"].lower()).strip("-")
        dest = OUT / f"{slug}.jpg"
        if not dest.exists():
            data = b""
            for attempt in range(4):
                try:
                    req = urllib.request.Request(plate["url"], headers={"User-Agent": UA})
                    with urllib.request.urlopen(req, timeout=90) as fh:
                        data = fh.read()
                    break
                except Exception as exc:  # noqa: BLE001 - one bad plate must not stop the set
                    # Commons rate-limits bursts of full-size downloads; back off
                    # rather than dropping most of the set.
                    if attempt == 3:
                        print(f"  skip {slug}: {exc}", file=sys.stderr)
                    else:
                        time.sleep(2 * (attempt + 1))
            if not data:
                continue
            # A truncated or error response is not a usable plate.
            if len(data) < 20_000 or not data.startswith(b"\xff\xd8"):
                print(f"  skip {slug}: not a usable JPEG ({len(data)} bytes)", file=sys.stderr)
                continue
            dest.write_bytes(data)
        kept.append({**plate, "file": dest.name, "slug": slug})
        print(f"  {slug}")

    return kept


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--limit", type=int, default=24, help="how many distinct species")
    args = ap.parse_args()

    print(f"searching {SOURCE_CATEGORY}…")
    found = search_plates(args.limit)
    print(f"downloading {len(found)} plates to {OUT}")
    kept = download(found)

    manifest = OUT / "plates.json"
    manifest.write_text(
        json.dumps(
            {
                "source": SOURCE_CATEGORY,
                "licence": "Public domain",
                "note": "Assigned to courses deterministically by course code; see PlateAssignment.swift",
                "plates": kept,
            },
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    print(f"\n{len(kept)} plates + manifest written")
    return 0 if kept else 1


if __name__ == "__main__":
    raise SystemExit(main())
