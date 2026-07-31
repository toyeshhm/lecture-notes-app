import AppKit
import SwiftUI

/// One Köhler plate, as the manifest describes it plus the loaded image.
///
/// `credit` and `licence` travel with the image because the plates are other
/// people's work: anywhere a plate is shown large enough to be a picture rather
/// than an identifying mark, the credit line has to be available without a
/// second lookup.
struct Plate {
    let species: String
    let credit: String
    let licence: String
    let image: Image
}

/// Gives every course a botanical plate, and gives it the same one forever.
///
/// Course identity in this system is a plant, not a hue (DESIGN.md §1), so the
/// assignment has to be stable in the strongest sense: the same course code maps
/// to the same species across launches, across machines, and across rebuilds.
@MainActor
enum PlateAssignment {

    /// The plate for a course code, or `nil` if the manifest or the image file
    /// is missing.
    ///
    /// Missing is a real state, not a programmer error: `Assets/Plates` is a
    /// folder reference in the build, so a half-synced checkout produces a
    /// manifest entry with no file behind it. Callers draw the row without a
    /// silhouette rather than crashing on a resource they cannot fix.
    static func plate(for courseCode: String) -> Plate? {
        let key = normalised(courseCode)
        guard !key.isEmpty, !entries.isEmpty else { return nil }

        let entry = entries[Int(fnv1a(key) % UInt64(entries.count))]
        if let cached = cache[entry.slug] { return cached }

        guard let url = Bundle.main.url(
                forResource: entry.file, withExtension: nil, subdirectory: platesDirectory),
              let bitmap = NSImage(contentsOf: url)
        else {
            // Note the failure, don't just return it. `cache[slug] = nil` would
            // *remove* the key rather than record a miss, so this has to go
            // through `updateValue`.
            //
            // ponytail: a plate that fails to decode stays blank until relaunch.
            // Right for a shipped bundle, where a bad file is a build defect and
            // never repairs itself; the cost is a half-synced checkout needing a
            // restart once the file lands. Drop the negative entry on a
            // directory-change notification if that ever becomes annoying.
            cache.updateValue(nil, forKey: entry.slug)
            return nil
        }

        let plate = Plate(
            species: entry.species,
            credit: entry.credit,
            licence: entry.licence,
            image: Image(nsImage: bitmap))
        cache.updateValue(plate, forKey: entry.slug)
        return plate
    }

    // MARK: The hash

    /// FNV-1a, 64-bit, over UTF-8.
    ///
    /// Written out by hand because Swift's `Hasher` is seeded per process:
    /// `"CS 314H".hashValue` differs between two launches of the same binary, so
    /// building the assignment on it would deal every course a new plant on
    /// every restart. That is the one thing this type exists to prevent.
    ///
    /// Reference vector, for anyone adding a test: `fnv1a("cs314h")` is
    /// 8666833478710697735.
    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Case and spacing are how a course code gets typed, not what it is:
    /// `CS 314H`, `cs314h` and `CS  314H` are one course and get one plant.
    private static func normalised(_ courseCode: String) -> String {
        courseCode.lowercased().filter { !$0.isWhitespace }
    }

    // MARK: The manifest

    private struct Entry: Decodable {
        let slug: String
        let species: String
        let credit: String
        let licence: String
        let file: String
    }

    private struct Manifest: Decodable {
        let plates: [Entry]
    }

    /// `Assets/Plates` is added to the target as a folder reference, so it keeps
    /// its directory inside the bundle rather than flattening into `Resources`.
    private static let platesDirectory = "Plates"

    /// Sorted by slug, so the assignment depends on the *set* of plates rather
    /// than on their order in the JSON. Reordering or reformatting the manifest
    /// then leaves every course where it was; only adding or removing a plate
    /// reshuffles, and that is a deliberate act.
    private static let entries: [Entry] = {
        guard let url = Bundle.main.url(
                forResource: "plates", withExtension: "json", subdirectory: platesDirectory),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return [] }
        return manifest.plates.sorted { $0.slug < $1.slug }
    }()

    /// Decoded images, keyed by slug. A sidebar row asks for its plate on every
    /// redraw and there are at most two dozen of them, so the whole cache is
    /// smaller than one lecture's audio buffer.
    ///
    /// A stored `nil` is a remembered failure, and it is the reason the values
    /// are optional. `CourseRow` reads `plate(for:)` three times per body pass —
    /// silhouette, species line, accessibility label — so an undecodable file
    /// was being re-read and re-decoded three times per redraw on the main
    /// actor. Measured at 0.183ms a call against 0.001ms for a cache hit, which
    /// is 33ms a second of blocking disk I/O for one row during the hover
    /// animation. A missing file is cheap by comparison, but both take the same
    /// path so both are remembered.
    private static var cache: [String: Plate?] = [:]
}
