# Lecture Notes — Product

## Register

**Brand.** This is a tool a student opens every weekday for three years, and the
design is part of what makes them keep opening it. The visual system is not
chrome wrapped around a transcript; it is the reason a term of lectures reads as
a collection rather than a folder of dated markdown.

Design serves the reading surface first and the collection second. Where those
two goals disagree, reading wins, without discussion.

## Users

A first-year CS or maths undergraduate.

- Already keeps an Obsidian vault with a filing scheme they chose and defend.
- Lives in a terminal. Recognises a good mono. Will notice if the vault path in
  Settings wraps.
- Opens the app twice per lecture: once to press record as the lecturer starts
  talking, once at 11pm to read back what was said.
- Content is not prose only. A single lecture can contain a 100-column code
  block, a six-column complexity table, and three lines of display LaTeX.
- Will read forty thousand words in this app in a term.

## Purpose

Record a lecture, transcribe it on device, and write structured study notes into
the right course folder of an existing Obsidian vault.

The product is finished when the student closes the laptop and the notes are
already filed. Nothing in the interface should ask them to do filing work the app
could have done.

Four surfaces carry that:

1. **Menu bar extra.** Start and stop without switching apps. The only thing
   that matters here is that "recording" is unmistakable from across a lecture
   theatre.
2. **Live capture.** Transcript streaming as it is recognised, with enough
   structure that a glance tells you it is working.
3. **Library.** A term of lectures, filed under courses, browsable as a
   collection.
4. **Note reader.** Where the forty thousand words happen.

## Brand personality

**Pressed, engraved, patient.**

The reference is Jan Wandelaar's uncoloured copperplate engravings for
Linnaeus's *Hortus Cliffortianus* (Amsterdam, 1738): pure burin linework, no
hand colouring, a plant identified entirely by line weight and hatching density.
Those plates were mounted on the grey-green rag board of Linnean Society and Kew
type-specimen sheets and marked with a red determination stamp when a specimen
was the authoritative one.

That is the whole voice. Value and rule do the work. One pigment exists and it
is a stamp, not a decoration.

The dark appearance is not an inversion of the light one. It is the sheet under a
lamp at 11pm, which is when a first-year actually reads a lecture back.

## Anti-references

Things this deliberately is not:

- **Flowers on an app.** No botanical illustration used as wallpaper, no leaf
  icons, no green-because-plants. The herbarium is a filing system, not a garden.
- **Aged-paper cream.** The warm near-white band (L 0.84 to 0.97, chroma under
  0.06, hue 40 to 100) reads as parchment regardless of what it is called. This
  system's neutrals are tinted toward hue 128 to 150, cool oxidised herbage, at
  chroma 0.004 to 0.022. Never warm.
- **Cyanotype blue.** The obvious answer to "Victorian botanical that is not
  cream" is Anna Atkins. It was considered and rejected: white type on a
  saturated ground halates over hours, and syntax highlighting on Prussian is
  ugly at best.
- **Twelve colour-coded course folders.** A herbarium is one collection. Courses
  are told apart by their plate, not by a hue.
- **Sage-and-oat wellness.** The green here is chroma 0.006, which is a whisper
  of oxidation on a neutral, not a colour.
- **Skeuomorphic paper texture under body text.** See the texture rule in
  DESIGN.md.

## Design principles

1. **The reading surface is the product.** Anything that makes 17pt Charter
   harder to read at 11pm loses, whatever it does for the aesthetic.
2. **Value before hue.** Hierarchy is carried by rule weight, hatch density,
   luminance planes, and typographic weight. Colour is the last tool reached
   for, and there is only one.
3. **One pigment, three jobs.** The cinnabar stamp marks the live recording
   state, the type specimen of a course, and destructive confirmations. It
   appears nowhere else, ever.
4. **The specimen does not stretch.** Resizing a frame around a pressed
   specimen grows the mount, not the specimen. The text column holds 68
   characters at every window size.
5. **Texture lives on the board, never on the sheet.** Where texture and
   legibility would conflict, they cannot, because they are on different
   objects.
6. **Metadata is a caption, not a card.** Course, date, duration and accession
   number set as one engraved line hanging outside the plate border at bottom
   left, where the engraver's credit sits on a real plate.
7. **Art direction reaches the reading surface.** The theme is not allowed to
   stop at the chrome. It is also not allowed to put anything underneath the
   type.

## Accessibility

**Hard rule, measured not eyeballed:** every foreground token used for text
measures at least 4.5:1 against every background it is permitted to sit on. The
measured table is in DESIGN.md and the permissions are explicit. Body text holds
a 65 to 75 character measure at every window size.

- Body prose measures 8.91:1 in light and 8.76:1 in dark on the specimen sheet.
  The floor across all permitted text pairings is 4.68:1 (cinnabar on the dark
  sheet).
- The cinnabar stamp is never small text on a plane where it drops below 4.5:1.
  Destructive confirmation copy sets in ink; only the stamp itself is cinnabar.
- Recording state is never carried by colour alone. The stamp is accompanied by
  a shape change and by text.
- The menu bar extra icon is a monochrome template image, so it renders
  correctly in both menu bar appearances and under Reduce Transparency.
- Every motion has a Reduce Motion path: crossfade or instant, never a shortened
  version of the same movement.
- The hatching gutter is decorative and duplicative. Everything it encodes
  (speech density, position in the recording) is also available as text and as a
  standard scrubber, and it is excluded from the accessibility tree as an image
  with a label.
- Full keyboard traversal. Focus rings are drawn as a doubled plate rule, not as
  a colour change.
