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
    /// Hash of a course code, used as the *starting* point for assignment.
    ///
    /// FNV-1a written out rather than Swift's `Hasher`, which is seeded per
    /// process: `"CS 314H".hashValue` differs between two launches of the same
    /// binary, so building the assignment on it would deal every course a new
    /// scene on every restart. That is the one thing this has to prevent.
    private static func hash(_ course: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in course.lowercased().filter({ !$0.isWhitespace }).utf8 {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01b3
        }
        return value
    }

    /// One scene per course, with no two courses sharing until there are more
    /// courses than scenes.
    ///
    /// Hashing alone is not enough and the difference is not subtle. Twelve
    /// courses hashed into twelve scenes used **seven** of them, with one scene
    /// taken by three courses — that is the birthday problem, not bad luck, and
    /// it defeats the entire purpose of a course being identifiable by its
    /// picture. Measured against real course codes before this was written.
    ///
    /// So the hash picks a starting slot and collisions probe forward. Courses
    /// are visited in sorted order so the result depends on the *set* of courses
    /// and not on the order they were scanned off the disk, which changes.
    ///
    /// The cost is that adding a course can move a scene that collided with it.
    /// That is the right trade: a term's courses are entered once and then stay
    /// put, and two courses wearing the same picture all term is the thing a
    /// student would actually notice.
    static func assign(courses: [String]) -> [String: Backdrop] {
        guard !entries.isEmpty else { return [:] }
        var taken = Set<Int>()
        var result: [String: Backdrop] = [:]

        for course in courses.sorted() {
            let start = Int(hash(course) % UInt64(entries.count))
            var slot = start
            // Probe forward. After a full lap every slot is taken, and wrapping
            // onto the start again is correct: with more courses than scenes,
            // sharing is unavoidable and evenly spread is the best available.
            for step in 0..<entries.count where taken.contains(slot) {
                slot = (start + step + 1) % entries.count
            }
            taken.insert(slot)
            result[course] = scene(named: entries[slot].slug)
        }
        return result
    }

    /// The scene for a single course, when the full set is not to hand.
    ///
    /// - Note: this can collide with another course's scene. Use ``assign(courses:)``
    ///   wherever several courses are on screen together, which is where a
    ///   collision would be visible.
    static func scene(for course: String) -> Backdrop? {
        guard !entries.isEmpty else { return nil }
        return scene(named: entries[Int(hash(course) % UInt64(entries.count))].slug)
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
