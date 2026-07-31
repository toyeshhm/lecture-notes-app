import SwiftUI

/// Design tokens for the "Hortus Siccus" direction.
///
/// Reference: Jan Wandelaar's uncoloured copperplate engravings for Linnaeus's
/// *Hortus Cliffortianus* (Amsterdam, 1738), mounted against the grey-green rag
/// board and cinnabar determination stamps of Kew type-specimen sheets. The
/// written system lives in `DESIGN.md`; this file is its only implementation.
///
/// **Colour authoring.** Every colour is authored in OKLCH and baked here as the
/// sRGB triple it converts to, with the OKLCH original and the measured WCAG 2.x
/// contrast in the comment beside it. Baking rather than converting at runtime is
/// deliberate: the conversion is a fixed pure function of nine constants, running
/// it on every view update buys nothing, and a baked value can be diffed and
/// audited. Every value below is inside the sRGB gamut; none clips.
///
/// Conversion used (Björn Ottosson's Oklab, 2020): OKLCH → Oklab by
/// `a = C·cos(H)`, `b = C·sin(H)`; Oklab → LMS' by the inverse M2 matrix; cube
/// each component; LMS → linear sRGB by the inverse M1 matrix; then the sRGB
/// transfer function. The same conversion computed the ratios quoted below.
///
/// **The guardrail.** Every token used for text measures at least 4.5:1 against
/// every plane it is permitted to sit on, and every token used as a boundary
/// measures at least 3:1 against every plane it is drawn on. The permissions are
/// documented on each property and are not advisory. The worst legal text
/// pairing in the system is 4.66:1 (`stamp` on the dark `sheet`); the worst legal
/// boundary pairing is 3.19:1 (`plate` on the dark `wash`).
///
/// Ratios below are measured from the **baked 8-bit sRGB triples**, not from the
/// continuous OKLCH floats. The two differ by up to 0.09 after quantisation, and
/// the 8-bit value is the one that reaches a display.

// MARK: - Palette

public enum Palette {

    // MARK: Planes
    //
    // Every window is a *board* with a *sheet* mounted on it. Chrome, sidebar and
    // margins are board; anything read for longer than a glance is sheet.
    //
    // Light: sheet sits 1.34:1 above board, a visible step.
    // Dark:  sheet sits only 1.13:1 above board, so in dark appearance the sheet
    //        is defined by its plate border and a hard-edged shadow, never by a
    //        glow. See `DESIGN.md` §1.

    /// Mounting board. Window background, sidebar, toolbar, margins.
    ///
    /// light `oklch(0.86 0.006 128)` · dark `oklch(0.168 0.012 150)`
    public static let board = dynamic(light: 0xD0_D2_CE, dark: 0x0B_10_0C)

    /// Specimen sheet. Every reading surface.
    ///
    /// light `oklch(0.955 0.004 128)` · dark `oklch(0.228 0.012 150)`
    /// Against `board`: 1.34 light, 1.13 dark.
    public static let sheet = dynamic(light: 0xEF_F1_EE, dark: 0x19_1E_19)

    /// Selection, hover, row fill, code-block ground.
    ///
    /// light `oklch(0.895 0.012 128)` · dark `oklch(0.295 0.016 150)`
    /// Against `sheet`: 1.20 light, 1.23 dark.
    public static let wash = dynamic(light: 0xDA_DE_D6, dark: 0x27_2F_28)

    // MARK: Ink
    //
    // Dark ink shifts to hue 92–95, a warm ivory on a cool board. Warm ink on cool
    // stock is what a determination label looks like up close, and it is the one
    // place the palette permits a hue clash.

    /// Headings, plate captions, primary prose. Legal as text on every plane.
    ///
    /// light `oklch(0.185 0.014 150)` · dark `oklch(0.935 0.008 92)`
    /// light: board 12.25, sheet 16.42, wash 13.68
    /// dark:  board 15.83, sheet 13.95, wash 11.36
    public static let ink = dynamic(light: 0x0E_14_0F, dark: 0xEB_E9_E4)

    /// Body prose, metadata, placeholders, hatching. Legal as text on every plane.
    ///
    /// light `oklch(0.375 0.014 150)` · dark `oklch(0.79 0.011 95)`
    /// light: board 6.69, sheet 8.96, wash 7.47
    /// dark:  board 9.99, sheet 8.80, wash 7.17
    public static let inkSoft = dynamic(light: 0x3C_43_3D, dark: 0xBD_BB_B3)

    // MARK: Line

    /// Hairlines, inner plate rule, table dividers, blockquote indent.
    ///
    /// light `oklch(0.72 0.012 140)` · dark `oklch(0.345 0.014 150)`
    ///
    /// - Warning: never text, and never the sole boundary of an interactive
    ///   control. It reads 1.63:1 on the light board and 1.47:1 on the dark sheet.
    ///   It is a hairline inside a composition that already has structure.
    public static let rule = dynamic(light: 0xA1_A6_9F, dark: 0x34_3B_35)

    /// Outer plate border, corner ticks, filled label headers, heavy hatching.
    ///
    /// light `oklch(0.335 0.022 150)` · dark `oklch(0.575 0.022 150)`
    /// light: board 7.79, sheet 10.44, wash 8.70
    /// dark:  board 4.45, sheet 3.92, wash 3.19
    ///
    /// - Important: legal as *text* only in light appearance. In dark appearance
    ///   this is a rule and fill token: it clears the 3:1 non-text boundary floor
    ///   on all three planes and nothing more.
    ///
    /// The dark value was raised from `L 0.52` to `L 0.575` because 0.52 measured
    /// 2.53:1 on the dark `wash`, under the 3:1 boundary floor. The selected
    /// sidebar row is exactly that pairing: a `plate` inset rule on a `wash`
    /// fill. Hue and chroma are unchanged; only the lightness moved.
    public static let plate = dynamic(light: 0x2F_3A_31, dark: 0x70_7D_72)

    // MARK: Pigment

    /// Cinnabar, from the red determination stamp that marks a herbarium's
    /// authoritative specimen. The system's only pigment, with exactly three uses:
    /// the live recording indicator, the type-specimen mark on a course's
    /// canonical lecture, and destructive confirmations.
    ///
    /// light `oklch(0.47 0.165 33)` · dark `oklch(0.64 0.165 35)`
    /// light: board 4.86, sheet 6.51, wash 5.42
    /// dark:  board 5.29, sheet 4.66, wash 3.80
    ///
    /// - Important: legal as text on `board` and `sheet` only. Never text on
    ///   `wash` (3.80 in dark). As a disc, ring or stamp glyph it may sit on any
    ///   plane, because a mark is not text. Destructive confirmation *copy* sets
    ///   in ``ink``; only the stamp glyph is cinnabar.
    ///
    /// The light value was lowered from `L 0.49` to `L 0.47` because 0.49
    /// measured 4.48:1 on the board, under the 4.5:1 floor. It is now 4.86:1 and
    /// still inside sRGB at chroma 0.165. Do not raise the lightness back.
    public static let stamp = dynamic(light: 0xA3_26_0B, dark: 0xDD_5F_40)

    /// Hard-edged shadow behind the sheet in dark appearance, where the 1.13:1
    /// plane step cannot carry the boundary on its own. Zero blur by design: a
    /// mounted sheet is defined by its border, not by a glow.
    public static let sheetShadow = dynamic(light: 0x00_00_00, dark: 0x00_00_00, lightAlpha: 0.10, darkAlpha: 0.80)

    // MARK: Resolution

    /// Builds a colour that follows the system appearance.
    ///
    /// `NSColor(name:dynamicProvider:)` is re-resolved by AppKit whenever the
    /// effective appearance changes, so a `Color` built from one tracks Dark Mode,
    /// Increase Contrast and printing without the view having to observe anything.
    /// Hex is packed 0xRRGGBB.
    private static func dynamic(
        light: UInt32,
        dark: UInt32,
        lightAlpha: Double = 1,
        darkAlpha: Double = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return srgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
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

    /// Tracking for the small-caps caption line, in points at 13pt (+0.06em).
    public static let captionTracking: CGFloat = 0.78

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

    /// Fits a 32pt plate silhouette plus two lines of `ui`.
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
