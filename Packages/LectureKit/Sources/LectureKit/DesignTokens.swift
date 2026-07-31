import SwiftUI

/// Design tokens for the "Deep Green" direction.
///
/// Reference: a dark rainforest interior at dusk — near-black grounds with green
/// in them, scenery carrying the mood, and a single warm light. It replaces
/// "Hortus Siccus", which was Victorian botanical plates on aged rag board: the
/// right idea for *nature* and the wrong one for this. A herbarium sheet is a
/// specimen pinned in a museum drawer; this is standing in the forest.
///
/// **This design commits to dark.** Every token below resolves to the same value
/// in both appearances, and that is deliberate rather than unfinished. The whole
/// direction is a dark room with one warm light in it, and a light-mode
/// translation would not be the same product with a different skin — it would be
/// a different product. Building one would mean re-grading every photograph,
/// because a dark scene behind dark text is not a scene, it is a stain.
///
/// **Colour authoring.** Every colour is authored in OKLCH and baked here as the
/// sRGB triple it converts to, with the OKLCH original and the measured WCAG 2.x
/// contrast in the comment beside it. Ratios are measured from the baked 8-bit
/// triples, not the continuous floats, because the 8-bit value is the one that
/// reaches a display. `DesignTokensTests` re-measures all of it on every run.
///
/// **The guardrail.** Every token used for text clears 4.5:1 against every plane
/// it is permitted to sit on; every token used as a boundary clears 3:1. The
/// worst legal text pairing is 4.51:1 (`inkSoft` on `wash`); the worst legal
/// boundary is 3.04:1 (`plate` on `wash`).

// MARK: - Palette

public enum Palette {

    // MARK: Planes
    //
    // Three depths, and they are deliberately close together: 1.10 and 1.26.
    // A dark interface separated by luminance alone turns into a stack of grey
    // boxes, so depth here is carried by the scenery, the hairlines and the one
    // warm light — not by making each panel a step brighter than the last.

    /// The window and every ground behind everything.
    /// `oklch(0.16 0.018 155)`
    public static let board = fixed(0x0A_0F_0B)

    /// A surface lifted off the window: sidebar, sheet, reading pane.
    /// `oklch(0.215 0.020 155)` — 1.10:1 on `board`.
    public static let sheet = fixed(0x14_1B_16)

    /// Selection, hover, row fill, code ground.
    /// `oklch(0.27 0.022 155)` — 1.26:1 on `board`.
    public static let wash = fixed(0x1E_27_20)

    // MARK: Ink
    //
    // Warm off-white, never pure white: on a green-black ground a neutral white
    // reads faintly blue, and the point of the direction is that warmth arrives
    // from one place.

    /// Headings and primary prose. Legal on every plane.
    /// `oklch(0.925 0.008 85)` — board 15.82, sheet 14.34, wash 12.58.
    public static let ink = fixed(0xEC_E8_E0)

    /// Body prose, metadata, placeholders. Legal on every plane.
    /// `oklch(0.745 0.010 88)` — board 8.91, sheet 8.08, wash 7.08.
    public static let inkSoft = fixed(0x86_8D_84)

    // MARK: Line

    /// Hairlines, dividers, the inner rule of a frame.
    ///
    /// - Warning: never text, and never the sole boundary of an interactive
    ///   control. It measures 1.54:1 on `board` — it is a seam inside a
    ///   composition that already has structure, not an edge that holds one.
    public static let rule = fixed(0x2C_36_2E)

    /// Outer frame, focus ring, the lit edge of a selected row.
    ///
    /// `oklch(0.50 0.055 68)` — board 3.82, sheet 3.46, wash 3.04.
    ///
    /// - Important: a boundary token only, never text. It is the accent at rest:
    ///   warm enough to read as lit rather than drawn, and dark enough that it
    ///   cannot be mistaken for the live mark.
    ///
    /// Raised from `0x6B_54_2C`, which measured 2.14:1 on `wash` — under the 3:1
    /// boundary floor, and `wash` is exactly where it lands on a selected row.
    public static let plate = fixed(0x87_6A_37)

    // MARK: Light

    /// The warm shaft. The system's only accent, and it means one of two things:
    /// this is live, or this is the action. Four permitted uses, per `DESIGN.md`
    /// §2.
    ///
    /// `oklch(0.78 0.145 72)` — board 9.33, sheet 8.46, wash 7.42.
    public static let stamp = fixed(0xE8_A8_4A)

    /// Hard-edged shadow under a lifted surface, because the 1.10:1 plane step
    /// cannot carry the boundary alone. Zero blur: this is a mounted thing with
    /// an edge, not a floating card with a glow.
    public static let sheetShadow = fixed(0x00_00_00, alpha: 0.80)

    // MARK: Resolution

    /// One value, both appearances.
    ///
    /// Still built through `NSColor(name:dynamicProvider:)` rather than a plain
    /// `Color`, because AppKit re-resolves that on an appearance change and on a
    /// switch to Increase Contrast or to printing. Returning the same triple from
    /// both branches keeps the design committed to dark while leaving the seam
    /// where a light theme would go, if the direction ever changes.
    private static func fixed(_ hex: UInt32, alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { _ in srgb(hex, alpha: alpha) })
    }

    private static func srgb(_ hex: UInt32, alpha: Double) -> NSColor {
        NSColor(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Typography

/// Three families, one job each: engraved, read, typed.
///
/// - **Bluu Next** (display) — Velvetyne Type Foundry, SIL OFL,
///   <https://velvetyne.fr/fonts/bluu-next>. NOT yet bundled — there is no app
///   target until Phase 3, so today this always falls back to
///   Hoefler Text, which ships with macOS and holds the same high-contrast
///   old-style character.
/// - **Charter** (body) — Matthew Carter, 1987. Ships with macOS at
///   `/System/Library/Fonts/Supplemental/Charter.ttc`, so the reading surface has
///   no font-loading risk. Drawn for low-resolution output: sturdy serifs, large
///   x-height, minimal stroke contrast.
/// - **Commit Mono** (mono) — Eigil Nikolajsen, SIL OFL,
///   <https://commitmono.com>. NOT yet bundled (see above); today this resolves to
///   Menlo. Herbarium determination slips were typed,
///   so the mono is the label rather than developer costume. Falls back to Menlo,
///   then to SF Mono via the system monospaced design.
public enum Typography {

    // MARK: Families

    private static let display = ["Bluu Next", "BluuNext-Bold", "Hoefler Text"]
    private static let body = ["Charter", "Charter-Roman", "Charis SIL", "Georgia"]
    private static let mono = ["CommitMono", "Commit Mono", "Menlo"]

    // MARK: Scale
    //
    // Ratio ≥1.25 from body upward: 17 → 22 (1.29) → 28 (1.27) → 35 (1.25) →
    // 44 (1.26). Ceiling 44pt; this is an app window, not a hero. The two steps
    // below body are label sizes, not hierarchy steps, and sit closer on purpose.

    /// 11pt Commit Mono. Accession numerals, timecodes, confidence figures.
    public static let micro = resolve(mono, size: 11)

    /// 13pt Bluu Next. The engraved caption line and determination slip header.
    /// Set with ``captionTracking`` and real small caps, never a faux-caps
    /// transform.
    public static let caption = resolve(display, size: 13)

    /// 15pt Charter. Sidebar rows, controls, library rows.
    public static let ui = resolve(body, size: 15)

    /// 15pt Charter Bold. Emphasised chrome: primary buttons, selected rows.
    public static let uiBold = resolve(body, size: 15).weight(.bold)

    /// 17pt Charter. **The reading surface.** Everything else defers to this.
    public static let bodyText = resolve(body, size: 17)

    /// 17pt Charter Bold. Run-in heads inside prose.
    public static let runIn = resolve(body, size: 17).weight(.bold)

    /// 15pt Commit Mono. Code blocks inside a note.
    public static let code = resolve(mono, size: 15)

    /// 22pt Charter Bold. Section heads within a note.
    public static let h3 = resolve(body, size: 22).weight(.bold)

    /// 22pt Commit Mono, tabular. Elapsed time in the menu bar popover
    /// (`DESIGN.md` §5.6: "elapsed time in `h3` Commit Mono tabular"). `h3` names
    /// the *step*; the family there is the mono, not Charter.
    public static let h3Mono = resolve(mono, size: 22).monospacedDigit()

    /// 28pt Bluu Next. Lecture section titles.
    public static let h2 = resolve(display, size: 28)

    /// 28pt Commit Mono, tabular. Elapsed time on the capture sheet
    /// (`DESIGN.md` §5.3: "`h2` in Commit Mono tabular figures"). Tabular so the
    /// digits do not jitter; `.monospacedDigit()` on `h2` itself would only give
    /// Bluu Next's own figures, which is the display face, not the typed one.
    public static let h2Mono = resolve(mono, size: 28).monospacedDigit()

    /// 35pt Bluu Next. Lecture title.
    public static let h1 = resolve(display, size: 35)

    /// 44pt Bluu Next. Course plate title.
    public static let plateTitle = resolve(display, size: 44)

    // MARK: Setting

    // Tracking, in points at each token's own size, from the `DESIGN.md` §3 scale
    // table. SwiftUI carries tracking on the view rather than on the `Font`, so
    // these cannot be folded into the tokens above and every call site that sets
    // one of these faces sets its tracking beside it.
    //
    // The display face tightens as it grows and the mono opens up at 11pt, which
    // is the ordinary correction: Bluu Next's fitting is drawn for text sizes and
    // gaps at 35pt, and Commit Mono's advance width is generous for its cap height
    // once the glyphs are small enough to be scanned rather than read.

    /// +0.02em at 11pt.
    public static let microTracking: CGFloat = 0.22

    /// +0.06em at 13pt.
    public static let captionTracking: CGFloat = 0.78

    /// −0.01em at 28pt.
    public static let h2Tracking: CGFloat = -0.28

    /// −0.015em at 35pt.
    public static let h1Tracking: CGFloat = -0.53

    /// −0.02em at 44pt.
    public static let plateTitleTracking: CGFloat = -0.88

    /// Extra leading for 17pt body prose, in points.
    ///
    /// Charter's natural line height at 17pt is 21.0pt (measured via
    /// `NSLayoutManager.defaultLineHeight`). Light appearance targets a 1.62 line
    /// height (27.5pt) so the extra is 6.5pt; dark targets 1.70 (28.9pt) so the
    /// extra is 8.0pt.
    ///
    /// Light type on a dark ground optically gains size and loses weight, so the
    /// correct compensation is a weight drop *and* a leading increase. Charter
    /// ships Roman, Bold, Italic and Bold Italic with no lighter cut and no
    /// variable weight axis, so the weight half cannot be honoured without
    /// synthetic thinning, which degrades the stems. We take the leading increase
    /// and do not fake the weight. Known shortfall, recorded so nobody re-derives
    /// it.
    public static func bodyLineSpacing(isDark: Bool) -> CGFloat {
        isDark ? 8.0 : 6.5
    }

    /// Returns the first candidate family that is actually installed.
    ///
    /// `Font.custom` silently falls back to the *system* face when a family is
    /// missing, which would drop Bluu Next straight to SF rather than to Hoefler
    /// Text. Probing with `NSFont(name:)` walks the real chain instead.
    /// `relativeTo: .body` keeps every size responsive to the accessibility text
    /// size.
    private static func resolve(_ candidates: [String], size: CGFloat) -> Font {
        for name in candidates where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size, relativeTo: .body)
        }
        // ponytail: `.serif` also covers the mono chain's last rung, because Menlo
        // is bundled with every macOS install and is never actually missing.
        return .system(size: size, design: .serif)
    }
}

// MARK: - Spacing

/// Base unit 4pt. ``hair`` is the one sub-base value, because a 1px rule is a
/// rule and a 2px rule is a border.
public enum Spacing {
    public static let hair: CGFloat = 1
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let plate: CGFloat = 48
    public static let mount: CGFloat = 64

    // MARK: Layout constants

    /// Prose column width: 68 characters of Charter at 17pt.
    ///
    /// Measured, not estimated: Charter at 17pt averages 7.51pt per character over
    /// real prose, so 68 characters is 510.7pt. The 65–75 character band is
    /// 488–563pt.
    ///
    /// **The sheet does not widen with the window; the mount grows instead.**
    /// Resizing a frame around a pressed specimen does not stretch the specimen.
    /// This value is constant at every window size.
    public static let measure: CGFloat = 512

    /// Widest the sheet grows to accommodate a wide block.
    ///
    /// The one exception to the measure rule. Code blocks, tables and display
    /// maths are core material for a CS or maths student, and a frame that forbids
    /// them is a plate that fails as a note. Prose stays at ``measure`` inside a
    /// widened sheet; wide blocks scroll horizontally within their own container.
    public static let sheetMax: CGFloat = 840

    /// Sheet edge to text column.
    public static let sheetPadding: CGFloat = 48

    /// The hero band on the record and reader surfaces.
    ///
    /// Tall enough that a 16:9 photograph is a place rather than a letterbox
    /// strip, and short enough that the transcript below it is on screen without
    /// scrolling on a laptop display.
    public static let heroHeight: CGFloat = 300

    /// Fits a 26pt scene thumbnail plus two lines of `ui`.
    public static let sidebarWidth: CGFloat = 232

    /// The hatching gutter down the left margin of a note.
    ///
    /// Hairlines are drawn in ``Palette/inkSoft``, never ``Palette/ink``: at full
    /// density in ink it is a black bar in the parafovea for forty thousand words.
    /// Spacing snaps to whole device pixels, because fractional hairline spacing
    /// moirés on scroll and this gutter scrolls past every word in the app.
    public static let gutterWidth: CGFloat = 24

    /// Maximum hatch coverage of ``gutterWidth``, as a fraction.
    public static let gutterMaxDensity: CGFloat = 0.6

    // MARK: Plate frame

    public static let plateBorderOuter: CGFloat = 1.5
    public static let plateBorderInner: CGFloat = 0.5
    public static let plateBorderGap: CGFloat = 6
    public static let plateCornerTick: CGFloat = 8
}

// MARK: - Motion

/// Motion is engraving, not animation. Things settle onto the board; they do not
/// bounce, spring, or slide in from off-screen.
///
/// Opacity, transform and mask only. Never animate layout width, and never
/// animate the measure.
public enum Motion {

    /// A duration paired with an ease-out curve and its Reduce Motion alternative.
    public struct Step: Sendable {
        public let duration: Double
        /// Cubic Bézier control points, `(x1, y1, x2, y2)`.
        public let curve: (x1: Double, y1: Double, x2: Double, y2: Double)
        /// What runs instead under Reduce Motion. `nil` means no animation at all.
        public let reduced: Animation?

        /// The animation to use, honouring Reduce Motion.
        ///
        /// Drive this from `@Environment(\.accessibilityReduceMotion)`. The reduced
        /// path is a *different* animation, not a shortened one.
        public func animation(reduceMotion: Bool) -> Animation? {
            guard !reduceMotion else { return reduced }
            return .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: duration)
        }
    }

    // Curves. Ease out with exponential curves; no bounce, no elastic.
    private static let easeOutQuart = (x1: 0.25, y1: 1.0, x2: 0.5, y2: 1.0)
    private static let easeOutQuint = (x1: 0.22, y1: 1.0, x2: 0.36, y2: 1.0)
    private static let easeOutExpo = (x1: 0.16, y1: 1.0, x2: 0.3, y2: 1.0)

    /// The Reduce Motion substitute for anything that would otherwise move.
    private static let crossfade = Animation.linear(duration: 0.1)

    /// Button press, checkbox, immediate feedback. Reduced: instant.
    public static let tap = Step(duration: 0.09, curve: easeOutQuart, reduced: nil)

    /// Hover, row fill, selection. Reduced: instant.
    public static let settle = Step(duration: 0.14, curve: easeOutQuart, reduced: nil)

    /// Sheet appears, view transition, popover. Reduced: 100ms opacity crossfade.
    public static let mount = Step(duration: 0.22, curve: easeOutQuint, reduced: crossfade)

    /// Course plate opening, library to reader. Reduced: 100ms opacity crossfade.
    public static let press = Step(duration: 0.38, curve: easeOutExpo, reduced: crossfade)

    /// Recording indicator only: opacity 1.0 → 0.55 on the disc, autoreversing.
    /// The ring stays fixed, so the shape is stable mid-pulse.
    ///
    /// Under Reduce Motion there is no pulse. The disc alternates filled and
    /// hollow at 1Hz instead, so the recording state stays unmistakably live
    /// without movement. `reduced` is `nil` because that alternation is a shape
    /// change driven by the view, not an animation.
    public static let pulse = Step(
        duration: 2.0,
        curve: (x1: 0.45, y1: 0.05, x2: 0.55, y2: 0.95),
        reduced: nil
    )

    /// Per-row delay when a library list staggers its entrance.
    ///
    /// One entrance per view, not one entrance per element: the library list is
    /// the only thing in the app that staggers. Zero under Reduce Motion.
    public static func listStagger(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : 0.018
    }
}
