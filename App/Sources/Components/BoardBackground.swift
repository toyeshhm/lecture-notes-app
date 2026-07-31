import LectureKit
import SwiftUI

/// The board plane: the mounting board every window is built on.
///
/// This view carries the system's **entire** texture budget (DESIGN.md §1): a 2%
/// monochrome grain and the plate mark around the mounted sheet. Nothing textured
/// exists anywhere else, and nothing is ever laid under body text — the sheet is a
/// separate, flat object mounted on top of this one.
struct BoardBackground: View {

    /// The grain is generated per device scale, so a window dragged to a second
    /// display with a different scale gets its own cached tile rather than a
    /// resampled one.
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Palette.board)
            .overlay {
                if let grain = Grain.tile(displayScale: displayScale) {
                    grain
                        .resizable(resizingMode: .tile)
                        .opacity(Grain.opacity)
                }
            }
            // The board is a plane, not a control: clicks belong to what sits on it.
            .allowsHitTesting(false)
    }
}

extension View {

    /// The plate mark: the impression an inked copperplate leaves in damp paper,
    /// drawn as a 1pt line just **outside** the sheet.
    ///
    /// The negative padding is the whole point — the line sits on the board, in the
    /// 1pt band beyond the sheet's edge, so the reading surface stays untouched.
    /// Apply this to the sheet itself, not to the board.
    func plateMark() -> some View {
        overlay {
            Rectangle()
                .strokeBorder(Palette.rule, lineWidth: Spacing.hair)
                .padding(-Spacing.hair)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Grain

/// The board grain, generated once per device scale and cached.
///
/// Procedural rather than an asset: the tile is 36KB of random bytes that would
/// otherwise be a shipped PNG differing per display scale. It is generated once and
/// then tiled by Core Animation, so a scrolling window costs no per-frame work.
@MainActor
private enum Grain {

    /// The texture budget from DESIGN.md §1, in full. Do not raise it.
    static let opacity: Double = 0.02

    /// Grain is generated at 1.5× the device scale, so a grain texel is smaller
    /// than a device pixel and reads as bite in the paper rather than as noise.
    private static let scaleFactor: CGFloat = 1.5

    /// Tile edge in texels. Large enough that the repeat is not findable at 2%,
    /// small enough to stay a trivial allocation.
    private static let texels = 192

    private static var cache: [CGFloat: Image] = [:]

    static func tile(displayScale: CGFloat) -> Image? {
        if let cached = cache[displayScale] { return cached }
        guard let bitmap = render() else { return nil }
        let image = Image(decorative: bitmap, scale: displayScale * scaleFactor)
        cache[displayScale] = image
        return image
    }

    private static func render() -> CGImage? {
        // Centred on mid-grey with a narrow spread: at 2% over either board this
        // perturbs the plane without shifting its measured luminance enough to
        // disturb the contrast ratios the palette was computed against.
        var bytes = [UInt8](repeating: 0, count: texels * texels)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: 96...160, using: &rng)
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: texels,
            height: texels,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: texels,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            // Interpolation would blur the grain back into a flat wash.
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

// MARK: - Previews

#Preview("Board with a mounted sheet") {
    BoardBackground()
        .overlay {
            Rectangle()
                .fill(Palette.sheet)
                .frame(width: 280, height: 180)
                .plateMark()
        }
        .frame(width: 460, height: 320)
}

#Preview("Board alone") {
    BoardBackground()
        .frame(width: 460, height: 320)
}
