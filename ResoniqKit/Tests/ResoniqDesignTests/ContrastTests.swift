import SwiftUI
import Testing
@testable import ResoniqDesign

/// WCAG 2.x contrast of every text and background token pair the app uses. A token change that breaks the
/// documented use fails here. Text needs 4.5:1, or 3:1 from 24 pt (18.66 pt bold); an indicator needs 3:1.
@Suite struct ContrastTests {
    typealias Token = (name: String, color: Color)

    static let ink: Token = ("ink", ResoniqColor.ink)
    static let panel: Token = ("panel", ResoniqColor.panel)
    static let panelRaised: Token = ("panelRaised", ResoniqColor.panelRaised)
    static let ivory: Token = ("ivory", ResoniqColor.ivory)
    static let muted: Token = ("muted", ResoniqColor.muted)
    static let signalText: Token = ("signalText", ResoniqColor.signalText)
    static let signal: Token = ("signal", ResoniqColor.signal)
    static let guide: Token = ("guide", ResoniqColor.guide)
    static let lime: Token = ("lime", ResoniqColor.lime)
    static let teal: Token = ("teal", ResoniqColor.teal)
    static let indigo: Token = ("indigo", ResoniqColor.indigo)
    static let disabled: Token = ("disabled", ResoniqColor.disabled)
    static let line: Token = ("line", ResoniqColor.line)

    /// Relative luminance of a colour (WCAG 2.x), from its linear sRGB components.
    static func luminance(_ color: Color) -> Double {
        let resolved = color.resolve(in: EnvironmentValues())
        return 0.2126 * Double(resolved.linearRed) + 0.7152 * Double(resolved.linearGreen) + 0.0722 * Double(resolved.linearBlue)
    }

    static func ratio(_ a: Color, _ b: Color) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    /// The pairs the app draws text with, on the surfaces that text sits on.
    static let textPairs: [(foreground: Token, background: Token)] = [
        (ivory, ink), (ivory, panel), (ivory, panelRaised),
        (muted, ink), (muted, panel), (muted, panelRaised),
        (signalText, ink), (signalText, panel), (signalText, panelRaised),
        (guide, ink), (guide, panel), (guide, panelRaised),
        (lime, ink), (lime, panel), (lime, panelRaised),
        // Labels on the filled controls: the primary pill, a done pill, the paused pill.
        (ink, lime), (ink, signal),
    ]

    @Test(arguments: textPairs.map { "\($0.foreground.name) on \($0.background.name)" })
    func `text pairs reach 4.5 to 1`(name: String) throws {
        let pair = try #require(Self.textPairs.first { "\($0.foreground.name) on \($0.background.name)" == name })
        let value = Self.ratio(pair.foreground.color, pair.background.color)
        #expect(value >= 4.5, "\(name) is \(value)")
    }

    /// Why `signalText` exists: the plain `signal` is for fills and strokes, and not for small text on dark.
    @Test func `signalText is the signal colour that reads as text`() {
        #expect(Self.ratio(ResoniqColor.signalText, ResoniqColor.panel) > Self.ratio(ResoniqColor.signal, ResoniqColor.panel))
    }

    /// Strokes and glyphs that carry meaning (a deviation mark, a selected outline, a trace) need 3:1.
    @Test(arguments: [
        ("signal", ResoniqColor.signal), ("lime", ResoniqColor.lime), ("teal", ResoniqColor.teal),
        ("guide", ResoniqColor.guide), ("muted", ResoniqColor.muted), ("ivory", ResoniqColor.ivory),
    ] as [(String, Color)])
    func `meaningful marks reach 3 to 1 on the panel`(name: String, color: Color) {
        let value = Self.ratio(color, ResoniqColor.panel)
        #expect(value >= 3, "\(name) is \(value)")
    }

    /// `indigo` is a gradient stop for portraits and curves and `disabled` is the paused portrait's fill. Neither
    /// reaches 4.5:1, which is why neither may be a text colour (no view uses them as a foreground style).
    @Test func `the colours that are not for text are named`() {
        #expect(Self.ratio(ResoniqColor.indigo, ResoniqColor.ink) < 4.5)
        #expect(Self.ratio(ResoniqColor.disabled, ResoniqColor.ink) < 4.5)
    }

    @Test func `the ratio is symmetric and one for the same colour`() {
        #expect(abs(Self.ratio(ResoniqColor.ivory, ResoniqColor.ink) - Self.ratio(ResoniqColor.ink, ResoniqColor.ivory)) < 1e-9)
        #expect(abs(Self.ratio(ResoniqColor.ink, ResoniqColor.ink) - 1) < 1e-9)
    }
}
