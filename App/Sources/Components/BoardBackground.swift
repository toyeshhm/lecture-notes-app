import LectureKit
import SwiftUI

/// The ground behind everything.
///
/// It used to generate a paper grain texture per device scale and draw a plate
/// mark around the mounted sheet — a `Canvas`, a cache and a hundred lines, which
/// is the right amount of work for aged rag board and the wrong amount for this.
/// On a near-black ground a 2% grain is either invisible or it is noise, and the
/// only thing carrying texture in this direction is the photograph.
///
/// Kept as a named view rather than inlined at its eight call sites, because "the
/// ground" is a real concept in the system: whatever belongs to it next lands
/// here rather than in whichever view happened to need it first.
struct BoardBackground: View {
    var body: some View {
        Palette.board
            .accessibilityHidden(true)
    }
}
