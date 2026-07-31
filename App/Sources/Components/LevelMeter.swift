import LectureKit
import SwiftUI

/// The microphone level, drawn as an engraved instrument scale with a needle.
///
/// Not a stock audio meter: DESIGN.md §5.3 bans waveforms and bouncing bars, so this
/// is a graduated rule with a single index riding it — the same object as a barometer
/// scale on a specimen sheet. It is entirely monochrome, which means hue carries
/// nothing here by construction; the level reads from needle position, the index
/// reads filled or hollow, and the figure beside it states the value in words.
///
/// Takes the level rather than reading `SessionModel` from the environment: the model's
/// `level` is `private(set)`, so an environment-bound meter could not be previewed at
/// anything but silence. Call site passes `model.level`.
struct LevelMeter: View {

    let level: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the needle is drawn, 0…1. Distinct from `level` because it is damped.
    @State private var needle: Double = 0

    /// 5% graduations. The figure quantises to these too, so the digits are steady
    /// against a jittery RMS stream instead of flickering on every sample.
    private static let divisions = 20

    /// The level as an integer percentage, snapped to a graduation.
    private var reading: Int {
        Int((Self.clamped(Double(level)) * Double(Self.divisions)).rounded())
            * (100 / Self.divisions)
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            scale
            Text("\(reading)%")
                .font(Typography.micro)
                // Tabular figures: the width of the reading must not twitch either.
                .monospacedDigit()
                .foregroundStyle(Palette.inkSoft)
        }
        .frame(height: Spacing.xl)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(reading) percent")
        // The whole point of the control is a value that moves. Without this,
        // VoiceOver reads the reading once on focus and never re-polls, so
        // "is the mic picking anything up?" is unanswerable without sight.
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear { track(level) }
        .onChange(of: level) { _, new in track(new) }
    }

    // MARK: Scale

    private var scale: some View {
        GeometryReader { geo in
            // The last graduation's own hairline has to stay inside the bounds, so
            // the travel is one hairline short of the width.
            let span = geo.size.width - Spacing.hair
            ZStack(alignment: .bottomLeading) {
                ForEach(0...Self.divisions, id: \.self) { division in
                    let major = division % 5 == 0
                    Rectangle()
                        .fill(major ? Palette.plate : Palette.rule)
                        .frame(width: Spacing.hair, height: major ? Spacing.md : Spacing.sm)
                        .offset(x: span * Double(division) / Double(Self.divisions))
                }
                // Spacing.xs is half the index head's width, so the needle's point
                // lands on the value rather than beside it.
                index.offset(x: span * needle - Spacing.xs)
            }
        }
    }

    private var index: some View {
        VStack(spacing: 0) {
            Group {
                if reading == 0 {
                    // Silence is a hollow index and a zero figure. Shape and text,
                    // never hue, distinguish silence from signal.
                    IndexMark().stroke(Palette.ink, lineWidth: Spacing.hair)
                } else {
                    IndexMark().fill(Palette.ink)
                }
            }
            .frame(width: Spacing.sm, height: Spacing.sm)

            Rectangle()
                .fill(Palette.ink)
                .frame(width: Spacing.plateBorderOuter, height: Spacing.lg)
        }
    }

    // MARK: Tracking

    private func track(_ raw: Float) {
        let target = Self.clamped(Double(raw))
        // Under Reduce Motion the needle steps between graduations and `settle`
        // resolves to no animation at all, so the meter reads discretely and never
        // glides. Otherwise the 140ms settle *is* the smoothing: it damps a raw RMS
        // stream into a needle that swings instead of twitching.
        let value = reduceMotion
            ? (target * Double(Self.divisions)).rounded() / Double(Self.divisions)
            : target
        withAnimation(Motion.settle.animation(reduceMotion: reduceMotion)) {
            needle = value
        }
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// The needle's index: a downward caret, cut rather than rounded.
private struct IndexMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

// MARK: - Previews

private struct LevelMeterGallery: View {
    let levels: [Float] = [0, 0.02, 0.18, 0.41, 0.67, 1]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            ForEach(levels, id: \.self) { level in
                LevelMeter(level: level)
            }
        }
        .padding(Spacing.plate)
        .frame(width: 360)
        .background(Palette.sheet)
    }
}

#Preview("Levels, silence first") {
    LevelMeterGallery()
}

// ponytail: no Reduce Motion preview. `accessibilityReduceMotion` is a read-only
// environment key, so it cannot be injected; check that path in the simulator's
// accessibility settings instead.
