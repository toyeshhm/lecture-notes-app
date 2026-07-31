import LectureKit
import SwiftUI

/// The row-scale hatching of `DESIGN.md` §5.4: six hairlines, 24pt wide, whose
/// spacing encodes a lecture's mean speech density.
///
/// This is the same object as the note reader's gutter (§5.5) at one row's
/// scale, so it obeys the same three constraints: `inkSoft` and never `ink`,
/// spacing snapped to whole device pixels, coverage capped at
/// ``Spacing/gutterMaxDensity``. A dense lecture and a slow one are then
/// distinguishable before the title is read.
///
/// It is duplicative decoration — everything it says is also said in the row's
/// accessibility label via ``densityDescription(wordsPerMinute:)`` — so it is
/// hidden from the accessibility tree rather than given a label of its own.
struct HatchSwatch: View {

    /// Mean words per minute over the transcript, or `nil` when the note
    /// carries none — which is every note in a mirror vault.
    let wordsPerMinute: Double?

    @Environment(\.displayScale) private var displayScale

    /// Six, per §5.4. The count is fixed and the spacing is the variable, which
    /// is why coverage has to be capped: more lines would read as a different
    /// mark, tighter lines read as more speech.
    private static let lines = 6

    /// The band the spacing maps across. Ordinary lecturing sits around 130–150
    /// words a minute; 110 and 190 put the two ends just outside that so a
    /// normal lecture lands mid-scale instead of pinned at one extreme.
    private static let slowest: Double = 110
    private static let fastest: Double = 190

    /// Widest spacing, and the value drawn when there is no transcript. Six
    /// hairlines at `xs` apart occupy 5×4 + 1 = 21pt, the most that fits the
    /// 24pt gutter with clearance at both ends.
    private static let widestSpacing = Spacing.xs

    var body: some View {
        // Canvas rather than stacked `Rectangle`s: the spacing has to land on
        // whole device pixels, and a laid-out stack rounds its own frames after
        // the fact. Here the rects are placed at already-snapped coordinates.
        Canvas { context, size in
            let step = spacing
            let block = CGFloat(Self.lines - 1) * step + Spacing.hair
            var y = snapped((size.height - block) / 2)
            for _ in 0..<Self.lines {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: Spacing.hair)),
                    with: .color(Palette.inkSoft))
                y += step
            }
        }
        .frame(width: Spacing.gutterWidth)
        .accessibilityHidden(true)
    }

    /// Distance between hairline top edges, in points, snapped to the display.
    ///
    /// Absence of a transcript is not absence of a lecture, so a nil, infinite
    /// or nonsensical reading draws evenly at the sparse end rather than
    /// vanishing. `wordsPerMinute` is read from a file on the user's disk and
    /// arrives as a `Double`, so `.isFinite` is a real guard and not a
    /// formality: a NaN would otherwise propagate into the drawn geometry.
    ///
    /// Snapping costs resolution and that is accepted: between 4pt and the cap
    /// there are only three whole-pixel steps at 1× and 2×, so the swatch reads
    /// as slow, ordinary or dense rather than as a continuous scale. A swatch
    /// that moirés while the list scrolls is worse than one with three steps,
    /// and the exact figure is in the row's label for anyone who needs it.
    private var spacing: CGFloat {
        // Coverage is one hairline per step, so the cap is a floor on the step.
        // Rounded *up* to the next whole pixel — rounding to nearest could land
        // below the floor and put the swatch over the 60% cap.
        let tightest = pixel(Spacing.hair / Spacing.gutterMaxDensity, rule: .up)
        guard let wordsPerMinute, wordsPerMinute.isFinite, wordsPerMinute > 0 else {
            return Self.widestSpacing
        }

        let position = (wordsPerMinute - Self.slowest) / (Self.fastest - Self.slowest)
        let density = min(max(position, 0), 1)
        let step = Self.widestSpacing - (Self.widestSpacing - tightest) * density
        return max(snapped(step), tightest)
    }

    private func snapped(_ value: CGFloat) -> CGFloat {
        pixel(value, rule: .toNearestOrAwayFromZero)
    }

    /// `displayScale` is 0 in a few off-screen rendering contexts, which would
    /// divide by zero here; 1 is the correct fallback because an unscaled
    /// context has point-sized pixels.
    private func pixel(_ value: CGFloat, rule: FloatingPointRoundingRule) -> CGFloat {
        let scale = max(displayScale, 1)
        return (value * scale).rounded(rule) / scale
    }

    /// What the swatch says, in words, for the row that owns it to speak.
    ///
    /// Lives here so the drawn mark and the spoken one cannot drift apart.
    static func densityDescription(wordsPerMinute: Double?) -> String {
        guard let wordsPerMinute, wordsPerMinute.isFinite, wordsPerMinute > 0 else {
            return "no transcript"
        }
        return "\(Int(min(wordsPerMinute, 1000).rounded())) words a minute"
    }
}

// MARK: - Previews

private struct HatchSwatchGallery: View {
    let readings: [Double?] = [nil, 90, 120, 145, 170, 240]

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xl) {
            ForEach(readings.indices, id: \.self) { index in
                VStack(spacing: Spacing.sm) {
                    HatchSwatch(wordsPerMinute: readings[index])
                        .frame(height: Spacing.xxl)
                    Text(HatchSwatch.densityDescription(wordsPerMinute: readings[index]))
                        .font(Typography.micro)
                        .tracking(Typography.microTracking)
                        .foregroundStyle(Palette.inkSoft)
                        .frame(width: Spacing.mount)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(Spacing.plate)
        .background(Palette.board)
    }
}

#Preview("Hatch swatch — light") {
    HatchSwatchGallery().preferredColorScheme(.light)
}

#Preview("Hatch swatch — dark") {
    HatchSwatchGallery().preferredColorScheme(.dark)
}
