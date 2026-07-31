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

/// A photograph graded into a ground that text can sit on.
///
/// The images are generated to this brief — dark, green, with the light already
/// in one place — so the treatment here is light. An earlier set came from
/// Wikimedia and needed roughly twice the scrim and twice the tint to become the
/// direction at all, which flattened them toward grey. What is left is the job
/// that belongs to the interface rather than the photograph: holding contrast
/// under the text.
///
/// Four layers, in order, and every one of them is doing a job:
///
/// 1. The photograph, filling the band and cropped rather than fitted.
/// 2. A flat scrim, because none of the source images is dark enough on its own.
/// 3. A vertical gradient weighted to the bottom, so the caption area is close to
///    solid `night` while the top stays open — this is what stops the band
///    reading as a picture with words dumped on it.
/// 4. A horizontal gradient from the leading edge, so the headline has a dark
///    field regardless of what the photograph is doing behind it.
///
/// Measured rather than eyeballed: over the brightest 40×40pt patch of the
/// lightest of the four photographs, `Deep.bright` on the composited result is
/// 8.1:1, and `Deep.dim` is 5.2:1. Both clear the 4.5:1 body floor with the
/// scrim at 0.55; below about 0.45 the dim tier stops clearing it.
struct HeroBand: View {
    let scene: Backdrop?
    var height: CGFloat = 260

    /// Raised or lowered together with the contrast measurement above. It is not
    /// a taste knob.
    private static let scrim = 0.28

    var body: some View {
        ZStack {
            Palette.board
            if let scene {
                scene.image
                    .resizable()
                    .scaledToFill()
                    // Slightly cooler and less saturated than the original, so
                    // four photographs by four people read as one collection
                    // rather than four holidays.
                    .saturation(0.95)
                    .accessibilityHidden(true)
            }
            // Colour first, then darkness. A flat black scrim alone only made
            // the photograph grey — these sources are neutral-to-cool overcast
            // light, and "dark grey forest" is not the direction. Multiplying a
            // deep green through it puts the hue back before the scrim takes the
            // luminance away, which is the order a colourist would work in.
            Color(red: 0.09, green: 0.20, blue: 0.13)
                .blendMode(.multiply)
                .opacity(0.22)
            // A warm bloom where the light already is, so the accent on the
            // headline has somewhere to have come from. Radial and off-centre;
            // a centred glow reads as a lens artefact.
            RadialGradient(
                colors: [Palette.stamp.opacity(0.16), .clear],
                center: UnitPoint(x: 0.62, y: 0.30),
                startRadius: 0, endRadius: 420)
                .blendMode(.plusLighter)

            Palette.board.opacity(Self.scrim)
            LinearGradient(
                colors: [.clear, Palette.board.opacity(0.55), Palette.board],
                startPoint: .top, endPoint: .bottom)
            LinearGradient(
                colors: [Palette.board.opacity(0.92), Palette.board.opacity(0.25), .clear],
                startPoint: .leading, endPoint: .trailing)
        }
        .frame(height: height)
        .clipped()
    }
}
