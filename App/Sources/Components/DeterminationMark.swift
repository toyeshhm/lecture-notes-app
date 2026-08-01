import LectureKit
import SwiftUI

/// The state as a shape: a filled disc, a hollow ring, a cross, or an empty
/// square while the determination is still out.
///
/// Four marks that stay distinct with the colour thrown away, because the pigment
/// has three documented jobs and none of them is this one (`DESIGN.md` §2). Ring
/// and disc are the capture panel's own idiom for a state that is and is not.
///
/// Shared by the first-run slip and Settings' Claude row. It lives here rather
/// than beside either of them because the two must agree: a check that reads
/// "ready" on one screen and something else on the other is worse than no mark.
struct DeterminationMark: View {
    let state: Preflight.State?

    /// The mark sits in an `lg` box so every row's title starts on one line,
    /// whichever shape is drawn — the same box the capture panel's indicator uses.
    private static let box = Spacing.lg

    /// 2pt, spelled as two hairlines rather than as a literal — the idiom the
    /// sidebar's 6pt disc and the capture panel's 10pt one already use.
    private static let inset = Spacing.hair * 2

    var body: some View {
        shape
            .frame(width: Self.box, height: Self.box)
            // The word beside it carries the state to VoiceOver; the mark would
            // only repeat it.
            .accessibilityHidden(true)
    }

    @ViewBuilder private var shape: some View {
        switch state {
        case .ok:
            Circle()
                .fill(Palette.inkSoft)
                .padding(Self.inset)

        case .warn:
            Circle()
                .strokeBorder(Palette.inkSoft, lineWidth: Spacing.plateBorderOuter)
                .padding(Self.inset)

        case .fail:
            // `ink` rather than `inkSoft`: this is the one mark on the slip that
            // has to be findable in a glance down the column, and weight is the
            // only axis left once the pigment is ruled out.
            Cross()
                .stroke(Palette.ink, lineWidth: Spacing.plateBorderOuter)
                .padding(Self.inset)

        case nil:
            // A square, so a pending row is not mistaken for a determined one at
            // a glance: nothing else on the slip is drawn with corners.
            Rectangle()
                .strokeBorder(Palette.rule, lineWidth: Spacing.plateBorderInner)
                .padding(Self.inset)
        }
    }

    /// The state in words. Both the mark's caption and the half that reaches
    /// VoiceOver, since the mark itself is hidden from it.
    static func word(for state: Preflight.State?) -> String {
        switch state {
        case .ok: "Ready"
        case .warn: "Warning"
        case .fail: "Blocking"
        case nil: "Checking"
        }
    }
}

private struct Cross: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}
