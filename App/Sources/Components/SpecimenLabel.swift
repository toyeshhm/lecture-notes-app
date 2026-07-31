import LectureKit
import SwiftUI

/// The engraved caption line of `DESIGN.md` §5.4 and §5.5.
///
/// It hangs *outside* the plate border at the bottom left, exactly where "Drawn
/// from nature by W.H. Fitch" sits on a Curtis plate, so it is placed after
/// ``PlateFrame`` rather than inside it:
///
/// ```swift
/// VStack(alignment: .leading, spacing: Spacing.sm) {
///     note.plateFrame()
///     SpecimenLabel(title: "Analysis II · 14 March", detail: "47:22 · LN-0114")
/// }
/// ```
///
/// Metadata here is never a card, a pill or a chip row.
struct SpecimenLabel: View {

    /// The engraved half: course, date, whatever names the specimen.
    let title: String

    /// The typed half: durations, accession numerals, timecodes.
    var detail: String?

    var body: some View {
        // One line is the specified form, but a caption plus an accession number can
        // outrun a narrow sidebar or a large accessibility text size; wrapping to two
        // lines keeps it legible where truncating would lose the numerals outright.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                engraved
                typed
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                engraved
                typed
            }
        }
        .foregroundStyle(Palette.inkSoft)
        .accessibilityElement(children: .combine)
    }

    /// Real small caps from the face, never a faux-caps `.uppercase` transform. A
    /// face without the feature renders unchanged, which is the correct fallback.
    private var engraved: Text {
        Text(title)
            .font(Typography.caption.smallCaps())
            .tracking(Typography.captionTracking)
    }

    @ViewBuilder
    private var typed: some View {
        if let detail {
            Text(detail).font(Typography.micro).tracking(Typography.microTracking)
        }
    }
}

// MARK: - Previews

private struct SpecimenLabelPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Compactness and the Heine–Borel theorem")
                    .font(Typography.bodyText)
                    .foregroundStyle(Palette.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .plateFrame()
                    .background(Palette.sheet)

                SpecimenLabel(
                    title: "Analysis II · 14 March 2026",
                    detail: "47:22 · LN-0114"
                )
            }

            SpecimenLabel(title: "Unsorted · no detail line")

            SpecimenLabel(title: "Discrete Structures · 2 October 2025", detail: "1:12:40 · LN-0088")
                .frame(width: 160, alignment: .leading)
        }
        .padding(Spacing.mount)
        .frame(width: 520)
        .background(Palette.board)
    }
}

#Preview("Specimen label — light") {
    SpecimenLabelPreview().preferredColorScheme(.light)
}

#Preview("Specimen label — dark") {
    SpecimenLabelPreview().preferredColorScheme(.dark)
}
