import LectureKit
import SwiftUI

/// The row-scale mark for a reading, standing where ``HatchSwatch`` stands for
/// a lecture.
///
/// A reading has no speech, so it has no density to hatch, and drawing an empty
/// swatch would state that the lecture was silent. This draws a mounted sheet
/// instead: a ruled rectangle with two lines of text on it, at the same 24pt
/// width and in the same `inkSoft` as the hatching, so the two marks read as
/// members of one system rather than as an icon set.
///
/// Per DESIGN.md §2, course identity is never a hue and this adds no token.
/// Like the hatching it is duplicative — the caption line beside it says "PDF"
/// in words — so it is hidden from the accessibility tree.
struct SheetMark: View {

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 2
            let width = size.width - inset * 2
            // Taller than it is wide, and centred in the row rather than drawn
            // down the whole of it. The gutter is as tall as the row, so a sheet
            // inset from its edges is a 24×56 bar that reads as a door and grows
            // if the row ever does; the hatching centres a fixed block in the
            // same space for the same reason.
            let height = (width * 1.35).rounded()
            let sheet = CGRect(
                x: inset, y: ((size.height - height) / 2).rounded(),
                width: width, height: height)

            context.stroke(
                Path(sheet), with: .color(Palette.inkSoft), lineWidth: Spacing.hair)

            // Three short rules for the text on the sheet, inset from its edge
            // by the same amount the sheet is inset from the gutter.
            let margin: CGFloat = 4
            let top = sheet.minY + margin
            let spacing = (sheet.height - margin * 2) / 3
            for line in 0..<3 {
                let y = (top + spacing * CGFloat(line)).rounded()
                // The last rule is short, the way a final line of a paragraph is.
                let width =
                    line == 2
                    ? (sheet.width - margin * 2) * 0.55
                    : sheet.width - margin * 2
                var path = Path()
                path.move(to: CGPoint(x: sheet.minX + margin, y: y))
                path.addLine(to: CGPoint(x: sheet.minX + margin + width, y: y))
                context.stroke(path, with: .color(Palette.inkSoft), lineWidth: Spacing.hair)
            }
        }
        .frame(width: Spacing.gutterWidth)
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Sheet mark — light") {
    SheetMark()
        .frame(height: Spacing.xxl)
        .padding(Spacing.plate)
        .background(Palette.board)
        .preferredColorScheme(.light)
}

#Preview("Sheet mark — dark") {
    SheetMark()
        .frame(height: Spacing.xxl)
        .padding(Spacing.plate)
        .background(Palette.board)
        .preferredColorScheme(.dark)
}
