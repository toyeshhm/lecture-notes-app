# Lecture Notes — Design System

**Direction:** Hortus Siccus
**Reference:** Jan Wandelaar's uncoloured copperplate line engravings for
Linnaeus's *Hortus Cliffortianus* (Amsterdam, 1738), pure burin linework with no
hand colouring, mounted against the grey-green rag board and red determination
stamps of Linnean Society and Kew type-specimen sheets.
**Strategy:** restrained. Tinted near-neutrals carry everything; one pigment
appears in three named places.

Tokens are implemented in
`Packages/LectureKit/Sources/LectureKit/DesignTokens.swift`. Every hex in this
document is the sRGB conversion of the OKLCH beside it, and every ratio was
computed, not estimated.

---

## 1. Theme

### The scene

Light appearance is a specimen sheet on a mounting board on a desk in daylight.
Dark appearance is the same sheet under a lamp at 11pm, which is when a
first-year actually reads a lecture back. Neither is the default and neither is
an inversion of the other; they are the same object under two lights, and the
system follows the macOS appearance without an in-app switch.

### Two planes, always

Every window is a **board** (`board`) with a **sheet** (`sheet`) mounted on it.
Chrome, sidebar, toolbars, gutters and margins are board. Anything you read for
longer than a glance is sheet.

- Light: sheet sits **1.34:1** above board. That step is visible, and it is what
  makes the sheet read as a mounted object rather than a lighter patch.
- Dark: sheet sits only **1.13:1** above board, which is not enough on its own.
  In dark appearance the sheet is defined by its **plate border and a
  hard-edged shadow**, not by luminance. A mounted sheet is defined by its
  border, not by a glow. Never substitute a soft glow or a blur.

### The texture rule

Paper grain, the uneven bite of the burin, and plate-mark impression live **only
on the board**. Nothing is ever laid under body text. Where texture and
legibility would conflict, they cannot, because they are physically on different
objects.

Board texture: a 2% opacity monochrome grain at 1.5× device scale, plus a plate
mark (a 1pt inset impression line) around the sheet. That is the entire texture
budget.

### Colour discipline

There is one accent: **ember**, the warm light in the scenery. It appears in
exactly four places and nowhere else:

1. The live recording indicator.
2. The primary action — the record and stop button.
3. Destructive confirmations (the mark only; the copy sets in `ink`).
4. The examinable mark on a note's `> [!important]` callout — the disc and the
   inset rule of the slip, never its words.

It is never colour alone. Every one of the four is also carried by a shape and by
a word: a filled disc against a hollow ring, a button with a verb on it, a cross
glyph, a titled slip. All four survive greyscale and all four reach the
accessibility tree.

Course identity is **not** a hue. Each course carries its own scene from
`Assets/Scenery/`. Twelve courses are twelve places, not twelve colour-coded
folders — and a photograph still reads as a place at 26pt, which is what the
botanical engraving it replaced could not do.

---

## 2. Palette

All neutrals are tinted toward hue 128 to 150, a cool oxidised herbage
green-grey, deliberately outside the warm 40 to 100 band so this can never
resolve as parchment. Chroma stays between 0.004 and 0.022 so nothing casts
colour onto type. Every value below is inside sRGB; nothing clips.

### Light appearance

| Role | OKLCH | sRGB | Purpose |
|---|---|---|---|
| `board` | `oklch(0.86 0.006 128)` | `#D0D2CE` | Mounting board. Window bg, sidebar, toolbar, margins. |
| `sheet` | `oklch(0.955 0.004 128)` | `#EFF1EE` | Specimen sheet. Every reading surface. |
| `wash` | `oklch(0.895 0.012 128)` | `#DADED6` | Selection, hover, row fill, code-block ground. |
| `ink` | `oklch(0.185 0.014 150)` | `#0E140F` | Headings, plate captions, primary prose. |
| `inkSoft` | `oklch(0.375 0.014 150)` | `#3C433D` | Body prose, metadata, placeholders, hatching. |
| `rule` | `oklch(0.72 0.012 140)` | `#A1A69F` | Hairlines, inner plate rule, table dividers. |
| `plate` | `oklch(0.335 0.022 150)` | `#2F3A31` | Outer plate border, filled label headers. |
| `stamp` | `oklch(0.47 0.165 33)` | `#A3260B` | Cinnabar. The three uses above. |

### Dark appearance

| Role | OKLCH | sRGB | Purpose |
|---|---|---|---|
| `board` | `oklch(0.168 0.012 150)` | `#0B100C` | Mounting board. |
| `sheet` | `oklch(0.228 0.012 150)` | `#191E19` | Specimen sheet. |
| `wash` | `oklch(0.295 0.016 150)` | `#272F28` | Selection, hover, row fill, code-block ground. |
| `ink` | `oklch(0.935 0.008 92)` | `#EBE9E4` | Headings, plate captions, primary prose. |
| `inkSoft` | `oklch(0.79 0.011 95)` | `#BDBBB3` | Body prose, metadata, placeholders, hatching. |
| `rule` | `oklch(0.345 0.014 150)` | `#343B35` | Hairlines, inner plate rule, table dividers. |
| `plate` | `oklch(0.575 0.022 150)` | `#707D72` | Outer plate border, filled label headers. |
| `stamp` | `oklch(0.64 0.165 35)` | `#DD5F40` | Cinnabar. |

Dark `ink` and `inkSoft` shift to hue 92 to 95, a warm ivory, against a cool
board. Warm ink on cool stock is what a real determination label looks like up
close, and it is the one place the palette permits a hue clash.

### Measured contrast

WCAG 2.x, measured from the **baked 8-bit sRGB hex** in the tables above, not
from the continuous OKLCH floats. Quantisation moves a ratio by up to 0.09, and
the 8-bit value is the one that reaches a display.

**Light**

| Foreground | on `board` | on `sheet` | on `wash` |
|---|---|---|---|
| `ink` | **12.25** | **16.42** | **13.68** |
| `inkSoft` | **6.69** | **8.96** | **7.47** |
| `stamp` | **4.86** | **6.51** | **5.42** |
| `plate` | **7.79** | **10.44** | **8.70** |
| `rule` | 1.63 | 2.18 | 1.82 |

**Dark**

| Foreground | on `board` | on `sheet` | on `wash` |
|---|---|---|---|
| `ink` | **15.83** | **13.95** | **11.36** |
| `inkSoft` | **9.99** | **8.80** | **7.17** |
| `stamp` | **5.29** | **4.66** | 3.80 |
| `plate` | **4.45** | **3.92** | **3.19** |
| `rule` | 1.67 | 1.47 | 1.20 |

Plane separation: `sheet` vs `board` is **1.34** light, **1.13** dark.
`wash` vs `sheet` is **1.20** light, **1.23** dark.

### Token permissions

These are rules, not suggestions. The pairings below are the only legal ones.

- `ink` and `inkSoft` are text on `board`, `sheet` or `wash`, in either
  appearance. Every one of those twelve pairings clears 4.5:1; the worst is 6.69.
- `stamp` is text only on `board` and `sheet`. **`stamp` is never text on
  `wash`** (3.80 in dark). As a filled disc, ring, or stamp shape it may sit on
  any plane, because a 3px-wide mark is not text.
- `plate` is text only on `board` and `sheet` in **light** appearance
  (7.79 / 10.44). In dark appearance `plate` is a **rule and fill token only**
  (4.45 board, 3.92 sheet, 3.19 wash: enough for a non-text boundary on every
  plane, not enough for text).
- `rule` is never text and never the sole boundary of an interactive control.
  It is a hairline inside a composition that already has structure.
- Destructive confirmation copy sets in `ink`. Only the stamp glyph is `stamp`.

---

## 3. Typography

Three families, one job each: engraved, read, typed. Voice words: pressed,
engraved, patient.

| Role | Family | Source | Fallback chain |
|---|---|---|---|
| Display | **Bluu Next** | Velvetyne Type Foundry, SIL OFL, `velvetyne.fr/fonts/bluu-next`. To bundle with the app target in Phase 3. | Hoefler Text (ships with macOS) → system serif |
| Body | **Charter** | Matthew Carter, 1987. Ships with macOS at `/System/Library/Fonts/Supplemental/Charter.ttc`. Also free as Charis SIL under OFL. | Charis SIL → Georgia → system serif |
| Mono | **Commit Mono** | Eigil Nikolajsen, SIL OFL, `commitmono.com`. To bundle with the app target in Phase 3. | Menlo → SF Mono via `.system(design: .monospaced)` |

**Why these.** Bluu Next is a high-contrast Renaissance revival with cut, sharp
terminals that read as engraved rather than calligraphic, period-correct for a
1738 Amsterdam plate. Charter was drawn for low-resolution output: sturdy
serifs, large x-height, minimal stroke contrast. It is the reason forty thousand
words stay comfortable, and it pairs with Bluu Next on a real contrast axis
(fine engraved hairline against heavy inked impression) rather than as two
similar serifs. Commit Mono is the determination label: herbarium slips were
typed, so mono here is the artefact rather than developer costume. It is narrow
enough that a vault path, an accession number and a timecode all fit the label
field without wrapping.

None of the three is on the reflex-reject list.

### Scale

Ratio 1.25 and above from body upward. The two steps below body are label sizes,
not hierarchy steps, and sit closer together on purpose.

| Token | pt | Family | Weight | Tracking | Use |
|---|---|---|---|---|---|
| `micro` | 11 | Commit Mono | Regular | +0.02em | Accession numerals, timecodes, confidence figures |
| `caption` | 13 | Bluu Next small caps | Regular | +0.06em | Engraved caption line, determination slip header |
| `ui` | 15 | Charter | Regular / Bold | 0 | Sidebar rows, controls, library rows |
| `body` | 17 | Charter | Regular | 0 | **The reading surface.** |
| `runIn` | 17 | Charter | Bold | 0 | Run-in heads inside prose |
| `h3` | 22 | Charter | Bold | 0 | Section heads in a note |
| `h2` | 28 | Bluu Next | Regular | −0.01em | Lecture section titles |
| `h1` | 35 | Bluu Next | Regular | −0.015em | Lecture title |
| `plateTitle` | 44 | Bluu Next | Regular | −0.02em | Course plate title |

Steps: 17 → 22 (1.29) → 28 (1.27) → 35 (1.25) → 44 (1.26). Ceiling 44pt. This is
an app window, not a hero.

### Body setting

- **17pt Charter, measure fixed at 512pt.** Measured empirically: Charter at
  17pt averages 7.51pt per character over real prose, so 68 characters is
  510.7pt. The 65 to 75 band is 488pt to 563pt. 512pt sits at 68ch.
- **Light:** line height 1.62 (27.5pt). Charter's natural line height at 17pt is
  21.0pt, so `lineSpacing` is **6.5pt**.
- **Dark:** line height 1.70 (28.9pt), so `lineSpacing` is **8.0pt**. Light type
  on a dark ground optically gains size and loses weight, so both axes need
  adjusting: the correct compensation is a weight drop *and* a leading increase.
  Charter ships Roman, Bold, Italic and Bold Italic with no lighter cut and no
  variable weight axis, so the weight half cannot be honoured without synthetic
  thinning, which degrades the stems. **We take the leading increase only, and
  we do not fake the weight.** This is a known, accepted shortfall of the body
  face, recorded here so nobody re-derives it.
- Oldstyle figures in dates and durations. Real small caps in the caption line,
  never faux caps from a transform.
- No uppercase eyebrows anywhere. Sections are separated by plate rules.

### The measure rule

**The sheet does not widen with the window. The mount grows instead.** Resizing
a frame around a pressed specimen does not stretch the specimen. The text column
is 512pt at 900pt window width and 512pt at 2400pt window width; the board grows
around it and the sheet stays centred in the content pane.

**The one exception**, because this app's content demands it: code blocks,
tables and display LaTeX may break the measure and run to the full sheet width,
with `overflow-x` scrolling inside their own container. A 100-column code block
and a six-column complexity table are core material for a CS or maths student,
and a frame that forbids them is a plate that fails as a note. The sheet itself
widens to accommodate the widest such block up to 840pt; prose stays at 512pt
within it, left-aligned to the same margin.

---

## 4. Spacing

Base unit 4pt. Hairlines are the one sub-base value, because a 1px rule is a
rule and a 2px rule is a border.

| Token | pt |
|---|---|
| `hair` | 1 |
| `xs` | 4 |
| `sm` | 8 |
| `md` | 12 |
| `lg` | 16 |
| `xl` | 24 |
| `xxl` | 32 |
| `plate` | 48 |
| `mount` | 64 |

Named layout constants:

| Constant | pt | Note |
|---|---|---|
| `measure` | 512 | 68ch of Charter 17pt |
| `sheetMax` | 840 | Widest the sheet grows for wide blocks |
| `sheetPadding` | 48 | Sheet edge to text column |
| `sidebarWidth` | 232 | Fits a plate silhouette plus two lines of `ui` |
| `gutterWidth` | 24 | Hatching gutter |
| `plateBorderOuter` | 1.5 | Outer rule |
| `plateBorderInner` | 0.5 | Inner hairline |
| `plateBorderGap` | 6 | Between the two rules |

Rhythm is deliberately uneven. Prose paragraphs sit `md` apart; a plate rule
takes `xl` above and `lg` below, because a rule reads as heavier than the space
it occupies.

---

## 5. Components

### 5.1 Sidebar row (course)

Board ground. Height 56pt, `sm` vertical padding, `md` horizontal.

- **Left:** the course's Köhler plate at 32×32pt, rendered as a monochrome
  silhouette in `inkSoft` at 85% opacity. This is the course's identity and it
  is the only per-course discriminator. Five courses are five recognisably
  different plants at a glance in a 232pt sidebar. It is also the source for the
  16pt app icon and the menu bar template image, so it must survive silhouetting.
- **Middle:** course name in `ui` Charter Regular, `ink`. Below it, lecture count
  and last-recorded date in `micro` Commit Mono, `inkSoft` (6.69:1 on board).
- **Right:** nothing by default. A `stamp` disc, 6pt, appears only while that
  course is recording.
- **Selected:** the row fills with `wash` and gains a 1.5pt `plate` rule on the
  left *inside* edge as an inset, not as a side stripe: the fill is the selection
  signal and the rule closes the plate. Text goes to `ink`.
- **Hover:** `wash` at 50%. No movement, no scale.

Section headers in the sidebar (Term, Archive) are `caption` Bluu Next small caps
in `inkSoft`, preceded by a full-width `rule` hairline. There is no uppercase
tracked eyebrow.

### 5.2 Course plate

**Not a card.** No shadow, no rounded rectangle, no equal-height grid. A course
opens as a single full-plate composition on the board:

- The Köhler plate image, full-bleed to the sheet's inner edge, at `plateTitle`
  scale on the left third.
- Double plate border around the whole composition: 1.5pt `plate` outer rule,
  0.5pt `rule` inner hairline, 6pt gap. Corner ticks 8pt long at each corner.
- Course title in `plateTitle` Bluu Next, `ink`, with a single hairline `rule`
  underline at 1pt sitting 6pt below the baseline.
- Below the title, the binomial-style subtitle (course code, term, lecturer) in
  `caption` Bluu Next small caps, `inkSoft`.
- Lectures list beneath, as library sheet rows (5.4).

Multiple courses on one screen are never a grid of equal cards. They stack as a
folio: full-width plate compositions separated by `mount` space and a single
`rule` hairline.

### 5.3 Capture panel

Board ground, sheet mounted centre. This surface is watched, not read closely,
so it runs one size up.

- **Recording indicator.** A 10pt `stamp` disc inside a 1pt `rule` ring, with the
  word `RECORDING` beside it in `caption` small caps, `ink`. Colour is never the
  only signal: the disc is a filled circle while live and a hollow ring while
  paused, and the word changes. The disc pulses (see Motion).
- **Elapsed time.** `h2` in Commit Mono tabular figures, `ink`. Tabular so the
  digits do not jitter.
- **Live transcript.** Charter at 17pt on the sheet, `inkSoft`, measure 512pt,
  auto-scrolling. The most recent utterance sets in `ink` and steps back to
  `inkSoft` when the next one arrives. That is the entire "it is working" signal.
  No waveform, no bouncing bars.
- **Hatching gutter**, 24pt wide, down the sheet's left margin. See 5.5.
- **Detected course** in `caption` small caps with the plate silhouette at 16pt,
  hanging in the board margin to the left of the sheet.
- Stop is a plain push button in `ui`. Discard is destructive: `ink` copy, a
  `stamp` cross glyph, confirmation sheet.

### 5.4 Library sheet row

A dated specimen filed under a course. One row is one sheet.

- Height 72pt. Board ground; the row does **not** get its own card, border or
  shadow. Rows are separated by a `rule` hairline at 1pt, full width minus the
  `md` inset.
- **Left, 24pt:** a static hatch swatch, six hairlines in `inkSoft`, whose
  spacing encodes the lecture's mean speech density. This is the row-scale
  version of the gutter, and it makes a dense lecture and a slow one
  distinguishable before you read the title.
- **Title** in `ui` Charter Bold, `ink`. Topic summary beneath in `ui` Charter
  Regular, `inkSoft`.
- **The engraved caption line.** Course, date, duration and accession number set
  as **one line** in `caption` Bluu Next small caps with `micro` Commit Mono
  figures, `inkSoft`, hanging at the bottom left of the row, outside any framing
  rule, exactly where "Drawn from nature by W.H. Fitch" sits on a Curtis plate.
  Metadata is never a card, never a pill, never a chip row.
- **Type specimen:** if this lecture is the course's canonical one, a `stamp`
  glyph (a 14pt ring with a diagonal) sits at the right, tilted 6 degrees, with
  an accessible label. This is the second of the pigment's three jobs.

### 5.5 Note reader

The product. Everything here defers to Charter at 17pt.

- Sheet mounted on board. Light: the 1.34:1 step defines it. Dark: a 1.5pt
  `plate` outer rule plus a hard-edged shadow (0 offset 0 blur 1pt spread, at
  `board` darkened, no softness) defines it. No glow in either.
- `sheetPadding` 48pt. Prose column 512pt. Wide blocks per the measure exception.
- **Plate border** around the note body: 1.5pt `plate` outer, 0.5pt `rule`
  inner, 6pt gap, corner ticks.
- **Caption line** hangs outside the border at bottom left, as in 5.4.
- **Headings:** `h1` Bluu Next for the lecture title with a 1pt `rule` underline;
  `h2` Bluu Next for sections; `h3` Charter Bold; `runIn` Charter Bold inline.
  Sections are separated by a `rule` hairline with `xl` above and `lg` below, not
  by an eyebrow.
- **Code blocks:** Commit Mono 15pt on `wash`, 1pt `rule` border, `md` padding,
  horizontal scroll inside the block. Syntax highlighting is permitted to bring
  its own hues; the near-monochrome ground exists precisely so it does not fight.
- **Tables:** `rule` hairlines only, no zebra fill, no outer box. Header row in
  `caption` small caps on `wash`.
- **Blockquote:** indented `lg` with a 1pt `rule` on the left. Exactly 1pt. A
  thicker coloured left border is banned.
- **The hatching gutter**, 24pt, down the left margin, running the full note:
  hairlines whose spacing encodes speech density minute by minute, so a slow
  proof reads sparse and a rapid derivation reads dense. Dragging it scrubs the
  audio. The scrollbar, the timeline and the plate's engraved shading are one
  object.
  - Hairlines are drawn in **`inkSoft`, never `ink`**. At full density in `ink`
    it is a black bar in the parafovea for forty thousand words.
  - Spacing snaps to **whole device pixels**. Fractional hairline spacing moirés
    on scroll, and this thing scrolls past every word in the app.
  - Maximum density is capped so the gutter never exceeds 60% coverage.
  - It is duplicative. Position and density are also available as text, and a
    standard scrubber exists. It is an image with a label in the accessibility
    tree.

### 5.6 Menu bar popover

240pt wide. Board ground, no sheet: this is chrome and nothing here is read at
length.

- The extra's icon is a **monochrome template image** of the active course's
  plate silhouette, so macOS tints it correctly in both menu bar appearances and
  under Reduce Transparency. While recording, the silhouette is overlaid with a
  filled dot; while idle, it is not. Never a coloured icon.
- **Idle:** course picker (plate silhouette + name, `ui`), and a single
  "Start recording" button, `ui` Charter Bold.
- **Recording:** the `stamp` disc and ring, elapsed time in `h3` Commit Mono
  tabular, the last recognised phrase in `ui` `inkSoft` clamped to two lines,
  and "Stop recording".
- macOS draws a popover as a vibrant system material with a system arrow. Do not
  fight it: the popover keeps the system material and the board colour is
  applied as a low-opacity tint over it, not as an opaque fill. The system arrow
  stays.
- `rule` hairline separators. No cards inside a 240pt popover.

---

## 6. Motion

Motion is engraving, not animation. Things settle onto the board; they do not
bounce, spring, or slide in from off-screen.

| Token | Duration | Curve | Use |
|---|---|---|---|
| `tap` | 90ms | ease-out-quart | Button press, checkbox, immediate feedback |
| `settle` | 140ms | ease-out-quart | Hover, row fill, selection |
| `mount` | 220ms | ease-out-quint | Sheet appears, view transition, popover |
| `press` | 380ms | ease-out-expo | Course plate opening, library to reader |
| `pulse` | 2000ms | ease-in-out sine, autoreverse | Recording indicator only |

Curves as cubic Bézier control points:

- ease-out-quart `(0.25, 1, 0.5, 1)`
- ease-out-quint `(0.22, 1, 0.36, 1)`
- ease-out-expo `(0.16, 1, 0.3, 1)`

Rules:

- No bounce. No elastic. No spring with overshoot.
- Opacity, transform and mask only. Never animate layout width, and never
  animate the measure.
- The hatching gutter never animates. It redraws.
- One entrance per view, not one entrance per element. A library list staggers
  its rows at 18ms; nothing else staggers.
- The recording pulse is opacity 1.0 to 0.55 on the disc only. The ring stays
  fixed, so the shape is stable even mid-pulse.

**Reduce Motion.** Every duration collapses to a 100ms crossfade or to nothing.
This is a different animation, not a shortened one:

- `tap`, `settle` → instant.
- `mount`, `press` → 100ms opacity crossfade, no transform.
- `pulse` → no pulse. The disc alternates filled and hollow at 1Hz instead, so
  the recording state is still unmistakably live without movement.

---

## 7. The legibility guardrail

**Hard rule. Measured, not eyeballed. This overrides every aesthetic decision in
this document.**

1. Every foreground token used for text measures **at least 4.5:1** against
   every background it is permitted to sit on, and every token used as a
   boundary measures **at least 3:1** against every plane it is drawn on. The
   permitted pairings are listed in section 2. The worst legal text pairing is
   **4.66:1** (`stamp` on the dark `sheet`); the worst legal boundary pairing is
   **3.19:1** (`plate` on the dark `wash`, which is the selected sidebar row).
2. Body prose holds **65 to 75 characters** at every window size. The measure is
   fixed at 512pt and the mount grows instead. Code blocks, tables and display
   maths are the only permitted exception, and they scroll inside their own
   container.
3. **Nothing is ever drawn underneath body text.** No grain, no plate mark, no
   watermark, no tint, no gradient. Texture lives on the board.
4. Colour is never the only carrier of state. The recording indicator changes
   shape and text as well as colour.
5. Any new token, and any new pairing of an existing token, is computed before
   it ships, **from the baked 8-bit hex rather than from the OKLCH floats**.
   Quantisation moves a ratio by up to 0.09 and the 8-bit value is what renders;
   quoting the float-derived number is how a system claims a ratio it does not
   deliver. Assert every text pairing at 4.5:1 and every boundary pairing at
   3:1 in the token file and fail the build under either. This is a check, not a
   design review.

Where texture and legibility conflict, legibility wins. There is no case in this
system where that judgement has to be made at runtime, because the two live on
different planes by construction.
