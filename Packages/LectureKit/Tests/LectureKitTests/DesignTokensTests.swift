import AppKit
import SwiftUI
import Testing

@testable import LectureKit

/// The contrast guardrail `DESIGN.md` §7.5 requires.
///
/// The ratios are written in the comments beside every token in
/// `DesignTokens.swift`, and a comment is not a guardrail: the light `stamp` was
/// authored at `L 0.49`, documented as legal on the board, and measured 4.48:1 —
/// under the floor. It was found by measuring, and nothing in the build would
/// have caught it. This is that measurement, run on every `swift test`.
///
/// It reads the *shipped* tokens rather than a table of hex literals, resolving
/// each `Color` through the same `NSColor` dynamic provider AppKit uses at draw
/// time. So it covers the baked triples, the light/dark branch, and the alpha —
/// a table copied from the comments would only ever agree with itself.
@MainActor
@Suite struct DesignTokensTests {

    /// WCAG 2.x: body text, and any text below 18pt or non-bold below 24pt.
    private static let textFloor = 4.5

    /// WCAG 2.x §1.4.11: UI component and graphical-object boundaries.
    private static let boundaryFloor = 3.0

    private static let planes: [(name: String, colour: Color)] = [
        ("board", Palette.board), ("sheet", Palette.sheet), ("wash", Palette.wash),
    ]

    // MARK: The permissions

    /// Legal on every plane, in both appearances. These carry all the prose.
    @Test(arguments: [("ink", Palette.ink), ("inkSoft", Palette.inkSoft)])
    func inkIsLegalTextEverywhere(token: (name: String, colour: Color)) {
        for appearance in Appearance.allCases {
            for plane in Self.planes {
                let ratio = contrast(token.colour, on: plane.colour, in: appearance)
                #expect(
                    ratio >= Self.textFloor,
                    "\(token.name) on \(plane.name) in \(appearance) is \(rounded(ratio)):1")
            }
        }
    }

    /// The accent is legal as text on every plane in this palette — 7.42:1 at its
    /// worst, on `wash`. It was board-and-sheet only under Hortus Siccus, where
    /// the cinnabar measured 3.80 on the dark wash; the carve-out went with the
    /// pigment. Asserted rather than dropped, because the accent is the one token
    /// most likely to be re-tuned for looks.
    @Test func accentIsLegalTextEverywhere() {
        for appearance in Appearance.allCases {
            for plane in Self.planes {
                let ratio = contrast(Palette.stamp, on: plane.colour, in: appearance)
                #expect(
                    ratio >= Self.textFloor,
                    "stamp on \(plane.name) in \(appearance) is \(rounded(ratio)):1")
            }
        }
    }

    /// `plate` draws the outer border and the selected row's inset rule, so it has
    /// to clear the *boundary* floor on every plane. The dark value was raised
    /// from `L 0.52` to `L 0.575` for exactly the `wash` pairing; asserted so it
    /// cannot drift back.
    @Test func plateClearsTheBoundaryFloor() {
        for appearance in Appearance.allCases {
            for plane in Self.planes {
                let ratio = contrast(Palette.plate, on: plane.colour, in: appearance)
                #expect(
                    ratio >= Self.boundaryFloor,
                    "plate on \(plane.name) in \(appearance) is \(rounded(ratio)):1")
            }
        }
    }

    /// `rule` is documented as never text and never a sole boundary. Asserting the
    /// *upper* bound is the point: if someone raises it until it passes 3:1 it has
    /// stopped being a hairline, and the warning on the token is then a lie.
    @Test func ruleStaysAHairline() {
        for appearance in Appearance.allCases {
            for plane in Self.planes {
                let ratio = contrast(Palette.rule, on: plane.colour, in: appearance)
                #expect(
                    ratio < Self.boundaryFloor,
                    "rule on \(plane.name) in \(appearance) is \(rounded(ratio)):1, which is boundary strength — use plate or restate the token")
            }
        }
    }

    /// The planes are deliberately close — 1.10:1 — which is the reason the sheet
    /// carries a border and a hard-edged shadow rather than relying on its fill.
    /// Pinned so nobody "fixes" the flatness by pulling them apart and quietly
    /// removes the need for the compensation that is still drawn everywhere.
    @Test func planesDoNotSeparateOnTheirOwn() {
        for appearance in Appearance.allCases {
            #expect(contrast(Palette.sheet, on: Palette.board, in: appearance) < 1.2)
            #expect(contrast(Palette.wash, on: Palette.board, in: appearance) < 1.4)
        }
    }

    /// The design commits to dark, and that commitment is a fact about the tokens
    /// rather than a note in a comment: every one of them resolves identically in
    /// both appearances. A token that drifted apart would put light-mode text on
    /// a dark-graded photograph.
    @Test(arguments: [
        ("board", Palette.board), ("sheet", Palette.sheet), ("wash", Palette.wash),
        ("ink", Palette.ink), ("inkSoft", Palette.inkSoft), ("rule", Palette.rule),
        ("plate", Palette.plate), ("stamp", Palette.stamp),
    ])
    func tokenIsAppearanceIndependent(token: (name: String, colour: Color)) {
        let light = luminance(token.colour, in: .light)
        let dark = luminance(token.colour, in: .dark)
        #expect(
            abs(light - dark) < 0.0001,
            "\(token.name) differs between appearances: \(light) vs \(dark)")
    }

    // MARK: Measurement

    private enum Appearance: CaseIterable, CustomStringConvertible {
        case light, dark
        var name: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
        var description: String { self == .dark ? "dark" : "light" }
    }

    /// WCAG 2.x relative luminance, from the sRGB triple AppKit actually resolves.
    ///
    /// `performAsCurrentDrawingAppearance` is what makes this test the real thing:
    /// the tokens are `NSColor(name:dynamicProvider:)`, so their components are
    /// undefined until something asks for them inside an appearance.
    private func luminance(_ colour: Color, in appearance: Appearance) -> Double {
        var resolved = NSColor.black
        NSAppearance(named: appearance.name)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(colour).usingColorSpace(.sRGB) ?? .black
        }
        let channels = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
            .map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private func contrast(_ foreground: Color, on background: Color, in appearance: Appearance) -> Double {
        let a = luminance(foreground, in: appearance)
        let b = luminance(background, in: appearance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func rounded(_ ratio: Double) -> String {
        String(format: "%.2f", ratio)
    }
}
