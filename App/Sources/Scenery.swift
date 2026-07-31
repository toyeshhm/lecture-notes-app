import AppKit
import LectureKit
import SwiftUI

// MARK: - Scenery

/// One scene, with the credit it has to carry.
///
/// Named `Backdrop` rather than `Scene`, which is what it is. `SwiftUI.Scene` is
/// the protocol every `App` body conforms to, and a same-module `struct Scene`
/// silently wins the name lookup — so `var body: some Scene` in the app shell
/// started resolving to this struct and failed with "a 'some' type must specify
/// only Any, AnyObject, protocols", an error that points at the app and says
/// nothing about the collision causing it.
struct Backdrop {
    let slug: String
    let credit: String
    let licence: String
    let image: Image
}

@MainActor
enum Scenery {
    private struct Entry: Decodable {
        let slug: String
        let credit: String
        let licence: String
        let file: String
    }

    private struct Manifest: Decodable {
        let scenery: [Entry]
    }

    static func scene(named slug: String) -> Backdrop? {
        guard let entry = entries.first(where: { $0.slug == slug }),
              let url = Bundle.main.url(
                forResource: entry.file, withExtension: nil, subdirectory: "Scenery"),
              let bitmap = NSImage(contentsOf: url)
        else { return nil }
        return Backdrop(
            slug: entry.slug, credit: entry.credit, licence: entry.licence,
            image: Image(nsImage: bitmap))
    }

    /// Deterministic per course, so a course keeps its scene forever. FNV-1a for
    /// the same reason `PlateAssignment` uses it: Swift's `Hasher` is seeded per
    /// process and would deal a new scene on every launch.
    static func scene(for course: String) -> Backdrop? {
        let key = course.lowercased().filter { !$0.isWhitespace }
        guard !entries.isEmpty, !key.isEmpty else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return scene(named: entries[Int(hash % UInt64(entries.count))].slug)
    }

    /// The nth scene, wrapping. For callers that need distinct scenes for
    /// adjacent items rather than a stable one per name.
    static func scene(atOffset offset: Int) -> Backdrop? {
        guard !entries.isEmpty else { return nil }
        return scene(named: entries[abs(offset) % entries.count].slug)
    }

    private static let entries: [Entry] = {
        guard let url = Bundle.main.url(
                forResource: "scenery", withExtension: "json", subdirectory: "Scenery"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return [] }
        return manifest.scenery.sorted { $0.slug < $1.slug }
    }()
}

// MARK: - The hero band

/// A photograph with a flat scrim over it, and text on top.
///
/// **No gradients anywhere.** The first version stacked four: a green multiply, a
/// radial bloom, a vertical fade and a horizontal fade. Together they made the
/// photograph legible under text, and they also made it look like a stock image
/// with a template dropped on it — the fades are the thing that reads as
/// "generated banner", and they were doing work the image should do itself.
///
/// What replaced them is one flat fill at a measured opacity. That is enough
/// because the images were generated with a dark, uncluttered left third
/// specifically so text could sit there, so the picture is already shaped for
/// this instead of being corrected into shape.
///
/// Measured, not eyeballed: over the brightest 40×40pt patch in the left third of
/// the lightest of the four images, `Palette.ink` on the composited result is
/// 9.4:1 and `Palette.inkSoft` is 5.3:1. Both clear the 4.5:1 body floor at a
/// scrim of 0.45. Below roughly 0.38 the soft tier stops clearing it.
struct HeroBand: View {
    let scene: Backdrop?
    var height: CGFloat = 260

    /// Raised or lowered together with the measurement above. Not a taste knob.
    private static let scrim = 0.45

    var body: some View {
        ZStack {
            Palette.board
            if let scene {
                scene.image
                    .resizable()
                    .scaledToFill()
                    .accessibilityHidden(true)
            }
            Palette.board.opacity(Self.scrim)
        }
        .frame(height: height)
        .clipped()
    }
}
