#!/usr/bin/env python3
"""Fetch freely-licensed photographic scenery for the "Deep Green" direction.

Why real photographs rather than generated images: the direction *is* cinematic
nature photography — dark forest interiors, atmospheric haze, one warm shaft of
light. A text-to-image model was the first choice and is not available here, but
the substitution is not a compromise. Real forest light is what the direction is
imitating, and the failure mode of a generated forest is exactly the thing that
would give it away: geometry that does not hold up at the edges, foliage that
repeats, light that comes from nowhere.

Licensing is verified per file rather than assumed, the same way `fetch-plates`
does it, because this repository is public and ships the images inside the app
bundle. Only public domain, CC0 and CC BY-SA are kept; anything NonCommercial or
NoDerivatives is dropped, and every file carries its author and licence into
`scenery.json` so the credit screen can name them.

Run: python3 Tools/fetch-scenery.py [--limit N]
Writes: Assets/Scenery/*.jpg and Assets/Scenery/scenery.json
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

OUT = Path(__file__).resolve().parent.parent / "Assets" / "Scenery"

# Each entry is one *scene*, named by the exact Commons file it uses.
#
# Named files rather than a search, because keyword search on Commons matches
# titles and descriptions, not picture content — "sunbeam forest" returned a
# photograph of a canal narrowboat called *Sunbeam*, in bright midday sun, with
# people in it. Every candidate here was looked at before it was chosen.
#
# What they were chosen for: a dark surround with a luminous centre. That is the
# structure the direction depends on, it is what lets the sheet sit over the
# image without either one fighting, and it is the one thing a photograph either
# has or does not.
SCENES: list[tuple[str, str]] = [
    ("clearing", "File:2017-09-24 Austria, Schöckl DSC 5004 DxO.jpg"),
    ("hollow", "File:2017-09-24 Austria, Schöckl DSC 5007 DxO.jpg"),
    ("pines", "File:Camino Primitivo, bosque de Castroverde 02.jpg"),
    ("rain", "File:03 Zur Harauer Spitze im Regen.jpg"),
]

# Everything permissive. Explicitly not a substring check against "CC": CC BY-NC
# and CC BY-ND both contain it and neither may ship in a public repository.
ALLOWED = ("public domain", "cc0", "cc by-sa", "cc by 4.0", "cc by 3.0", "cc by 2.0")
FORBIDDEN = ("nc", "nd", "noncommercial", "noderiv")


def _get(params: dict[str, str]) -> dict:
    url = API + "?" + urllib.parse.urlencode({**params, "format": "json"})
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as fh:
        return json.load(fh)


def _strip_html(raw: str) -> str:
    """Commons returns author and licence fields as HTML fragments."""
    return re.sub(r"<[^>]+>", "", raw or "").strip()


def licence_ok(licence: str) -> bool:
    low = licence.lower()
    if any(bad in re.split(r"[\s-]+", low) for bad in FORBIDDEN):
        return False
    return any(good in low for good in ALLOWED)


def search_scene(slug: str, title: str) -> dict | None:
    """The named file, with its licence and author, or None if it is unusable."""
    data = _get({
        "action": "query",
        "titles": title,
        "prop": "imageinfo",
        "iiprop": "url|extmetadata|size",
        # Wide enough to fill a hero band on a Retina display without upscaling.
        "iiurlwidth": "2400",
    })
    pages = (data.get("query") or {}).get("pages") or {}
    for page in pages.values():
        info = (page.get("imageinfo") or [{}])[0]
        if not info:
            continue
        meta = info.get("extmetadata", {})
        licence = _strip_html(meta.get("LicenseShortName", {}).get("value", ""))
        # Re-checked on every run rather than trusted from when it was picked:
        # a Commons file can be re-licensed or replaced under the same name.
        if not licence_ok(licence):
            print(f"  {slug}: licence is now {licence!r}, dropping", file=sys.stderr)
            continue
        return {
            "slug": slug,
            "title": page["title"],
            "url": info.get("thumburl") or info.get("url", ""),
            "descriptionUrl": info.get("descriptionurl", ""),
            "licence": licence,
            "credit": _strip_html(meta.get("Artist", {}).get("value", "")) or "Unknown",
        }
    return None


def download(scenes: list[dict]) -> list[dict]:
    OUT.mkdir(parents=True, exist_ok=True)
    kept: list[dict] = []

    for scene in scenes:
        dest = OUT / f"{scene['slug']}.jpg"
        if not dest.exists():
            data = b""
            for attempt in range(4):
                try:
                    req = urllib.request.Request(scene["url"], headers={"User-Agent": UA})
                    with urllib.request.urlopen(req, timeout=120) as fh:
                        data = fh.read()
                    break
                except Exception as exc:  # noqa: BLE001 - one bad scene must not stop the set
                    if attempt == 3:
                        print(f"  skip {scene['slug']}: {exc}", file=sys.stderr)
                    else:
                        time.sleep(2 * (attempt + 1))
            if not data:
                continue
            if len(data) < 50_000 or not data.startswith(b"\xff\xd8"):
                print(f"  skip {scene['slug']}: not a usable JPEG ({len(data)} bytes)",
                      file=sys.stderr)
                continue
            dest.write_bytes(data)
            print(f"  {scene['slug']}.jpg  ({len(data) // 1024} KB)  {scene['licence']}")

        kept.append({k: v for k, v in scene.items() if k != "url"} | {"file": dest.name})

    return kept


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=len(SCENES))
    args = parser.parse_args()

    found: list[dict] = []
    for slug, title in SCENES[: args.limit]:
        print(f"searching {slug} ...")
        scene = search_scene(slug, title)
        if scene is None:
            print(f"  no usable file for {slug}", file=sys.stderr)
        else:
            found.append(scene)
        time.sleep(0.6)  # be a polite API citizen

    kept = download(found)
    (OUT / "scenery.json").write_text(json.dumps({"scenery": kept}, indent=2) + "\n")
    print(f"\n{len(kept)} scenes in {OUT}")
    return 0 if kept else 1


if __name__ == "__main__":
    raise SystemExit(main())
