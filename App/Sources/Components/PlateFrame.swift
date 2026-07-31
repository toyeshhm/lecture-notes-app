import LectureKit
import SwiftUI

/// The engraved plate border of `DESIGN.md` §5.2 and §5.5: a `plate` outer rule, a
/// `rule` inner hairline set `plateBorderGap` inside it, and corner ticks marking
/// the inner rule's corners.
///
/// This is chrome, not a card. It draws no fill and no corner radius, and it never
/// lays anything underneath the content it frames — the reading surface stays the
/// caller's `sheet` and the texture stays on the board.
struct PlateFrame: ViewModifier {

    /// Inner hairline to content. `DESIGN.md` names no token for this distance
    /// (`sheetPadding` is sheet edge to text column, a different measurement), so
    /// the default is the closest spacing step and the note reader passes
    /// `Spacing.sheetPadding` explicitly.
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(Spacing.plateBorderOuter + Spacing.plateBorderGap + padding)
            .background {
                // §1: in dark appearance the sheet is defined by its border plus a
                // hard-edged shadow, never a glow. SwiftUI's `.shadow` always blurs
                // and has no spread, so the specified "0 offset 0 blur 1pt spread"
                // is a 1pt ring standing proud of the frame instead.
                // `sheetShadow` already carries the appearance (0.10 light, 0.80
                // dark), so this needs no colour-scheme branch.
                //
                // A *ring*, not a filled rectangle: a fill here sits behind the
                // caller's content, and the caller's sheet is either mounted inside
                // this frame (leaving the border band solid black in dark) or behind
                // it (blacking out the whole sheet). `strokeBorder` insets inward
                // from the padded bounds, so the 1pt stroke lands exactly in the
                // band beyond the frame edge and covers nothing.
                Rectangle()
                    .strokeBorder(Palette.sheetShadow, lineWidth: Spacing.hair)
                    .padding(-Spacing.hair)
            }
            .overlay { rules }
    }

    private var rules: some View {
        ZStack {
            Rectangle()
                .strokeBorder(Palette.plate, lineWidth: Spacing.plateBorderOuter)

            Rectangle()
                .strokeBorder(Palette.rule, lineWidth: Spacing.plateBorderInner)
                .padding(Spacing.plateBorderOuter + Spacing.plateBorderGap)

            // The ticks are `plate` drawn at the hairline's own weight rather than a
            // thicker stroke: the corner must read as pressed without the inner rule
            // thickening into a border. Half the hairline is added to the inset so
            // the tick and the rule it marks share a centre line — `strokeBorder`
            // insets by lineWidth/2, a centred `stroke` does not.
            CornerTicks(length: Spacing.plateCornerTick)
                .stroke(Palette.plate, lineWidth: Spacing.plateBorderInner)
                .padding(
                    Spacing.plateBorderOuter
                        + Spacing.plateBorderGap
                        + Spacing.plateBorderInner / 2
                )
        }
        .accessibilityHidden(true)  // Decoration; the framed content carries the meaning.
    }
}

/// Two segments per corner, running along the rectangle's edges from each corner.
private struct CornerTicks: Shape {
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        // At small sizes the four corners would otherwise meet and the ticks would
        // silently become a full rectangle, which is a different mark entirely.
        let run = min(length, rect.width / 2, rect.height / 2)
        guard run > 0 else { return Path() }

        var path = Path()
        for (x, dx) in [(rect.minX, 1.0), (rect.maxX, -1.0)] {
            for (y, dy) in [(rect.minY, 1.0), (rect.maxY, -1.0)] {
                path.move(to: CGPoint(x: x + run * dx, y: y))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + run * dy))
            }
        }
        return path
    }
}

extension View {
    /// Mounts this view inside the engraved plate border.
    func plateFrame(padding: CGFloat = Spacing.lg) -> some View {
        modifier(PlateFrame(padding: padding))
    }
}

// MARK: - Previews

private struct PlateFramePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("Kolmogorov Complexity")
                .font(Typography.h2)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .plateFrame()
                .background(Palette.sheet)

            Text("A frame narrow enough to clamp its corner ticks.")
                .font(Typography.ui)
                .foregroundStyle(Palette.inkSoft)
                .frame(width: 120)
                .plateFrame(padding: Spacing.sm)
                .background(Palette.sheet)
        }
        .padding(Spacing.mount)
        .background(Palette.board)
    }
}

#Preview("Plate frame — light") {
    PlateFramePreview().preferredColorScheme(.light)
}

#Preview("Plate frame — dark") {
    PlateFramePreview().preferredColorScheme(.dark)
}
