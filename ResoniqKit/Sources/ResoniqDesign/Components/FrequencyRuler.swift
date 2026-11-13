import SwiftUI

/// The vertical log-frequency axis of a speaker portrait: 20 Hz at the bottom, 20 kHz at the top.
/// It sits beside one portrait (V3Result, V3Listening) or between two (V3Diagnose). Give it the same height
/// as the portrait and the two line up.
public struct FrequencyRuler: View {
    public enum Style: Sendable {
        /// Left of one portrait: labels, then the ticks, then the axis line on the trailing edge.
        case beside
        /// Between two portraits: the labels sit on the axis, the ticks point away from it on both sides.
        case between
    }

    private let style: Style
    @ScaledMetric(relativeTo: .caption2) private var besideWidth: CGFloat = Metrics.besideWidth
    @ScaledMetric(relativeTo: .caption2) private var betweenWidth: CGFloat = Metrics.betweenWidth

    public init(_ style: Style = .beside) {
        self.style = style
    }

    // MARK: Mapping

    public nonisolated static let lowestFrequency: Double = 20
    public nonisolated static let highestFrequency: Double = 20_000

    /// Labelled ticks, in hertz.
    public nonisolated static let majorTicks: [Double] = [20, 100, 1_000, 10_000, 20_000]
    /// Unlabelled ticks, in hertz.
    public nonisolated static let minorTicks: [Double] = [50, 200, 500, 2_000, 5_000]

    /// Where a frequency sits on the axis, from 0 (20 Hz, the bottom) to 1 (20 kHz, the top). Frequencies
    /// outside the axis are held at its ends. Every view that annotates a portrait at a frequency uses this.
    public nonisolated static func fraction(forFrequency hertz: Double) -> Double {
        guard !hertz.isNaN else { return 0 }
        let clamped = min(max(hertz, lowestFrequency), highestFrequency)
        return log(clamped / lowestFrequency) / log(highestFrequency / lowestFrequency)
    }

    /// The inverse of `fraction(forFrequency:)`.
    public nonisolated static func frequency(forFraction fraction: Double) -> Double {
        guard !fraction.isNaN else { return lowestFrequency }
        let clamped = min(max(fraction, 0), 1)
        return lowestFrequency * pow(highestFrequency / lowestFrequency, clamped)
    }

    /// The label on an axis: "20", "100", "1k", "10k", "20k".
    public nonisolated static func label(forFrequency hertz: Double) -> String {
        hertz >= 1_000 ? "\(Int((hertz / 1_000).rounded()))k" : "\(Int(hertz.rounded()))"
    }

    /// A frequency as VoiceOver should say it: "90 hertz", "1 kilohertz", "14.5 kilohertz".
    public nonisolated static func spokenFrequency(_ hertz: Double) -> String {
        guard hertz >= 1_000 else { return "\(Int(hertz.rounded())) hertz" }
        let kilohertz = (hertz / 100).rounded() / 10
        let text = kilohertz == kilohertz.rounded() ? "\(Int(kilohertz))" : "\(kilohertz)"
        return "\(text) kilohertz"
    }

    // MARK: Drawing

    public var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(width: style == .beside ? besideWidth : betweenWidth)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let hairline = ResoniqSize.strokeHairline
        func y(_ hertz: Double) -> CGFloat {
            let raw = size.height * (1 - Self.fraction(forFrequency: hertz))
            return min(max(raw, hairline), size.height - hairline)
        }

        switch style {
        case .beside:
            let axisX = size.width - hairline
            var axis = Path()
            axis.move(to: CGPoint(x: axisX, y: 0))
            axis.addLine(to: CGPoint(x: axisX, y: size.height))
            var ticks = Path()
            for hertz in Self.majorTicks {
                ticks.move(to: CGPoint(x: axisX, y: y(hertz)))
                ticks.addLine(to: CGPoint(x: axisX - Metrics.majorTick, y: y(hertz)))
            }
            for hertz in Self.minorTicks {
                ticks.move(to: CGPoint(x: axisX, y: y(hertz)))
                ticks.addLine(to: CGPoint(x: axisX - Metrics.minorTick, y: y(hertz)))
            }
            context.stroke(axis, with: .color(ResoniqColor.muted), lineWidth: hairline)
            context.stroke(ticks, with: .color(ResoniqColor.muted), lineWidth: hairline)
            for hertz in Self.majorTicks {
                drawLabel(
                    Self.label(forFrequency: hertz), y: y(hertz),
                    x: axisX - Metrics.majorTick - Metrics.labelGap, anchor: .trailing,
                    size: size, in: &context
                )
            }

        case .between:
            let mid = size.width / 2
            let inner = Metrics.betweenLabelHalfWidth
            let outer = inner + Metrics.betweenTick
            var major = Path()
            var minor = Path()
            for hertz in Self.majorTicks {
                for side: CGFloat in [-1, 1] {
                    major.move(to: CGPoint(x: mid + side * inner, y: y(hertz)))
                    major.addLine(to: CGPoint(x: mid + side * outer, y: y(hertz)))
                }
            }
            for hertz in Self.minorTicks {
                for side: CGFloat in [-1, 1] {
                    minor.move(to: CGPoint(x: mid + side * inner, y: y(hertz)))
                    minor.addLine(to: CGPoint(x: mid + side * outer, y: y(hertz)))
                }
            }
            context.stroke(major, with: .color(ResoniqColor.muted), lineWidth: hairline)
            context.stroke(minor, with: .color(ResoniqColor.line), lineWidth: hairline)
            for hertz in Self.majorTicks {
                drawLabel(
                    Self.label(forFrequency: hertz), y: y(hertz), x: mid, anchor: .center,
                    size: size, in: &context
                )
            }
        }
    }

    private func drawLabel(
        _ text: String, y: CGFloat, x: CGFloat, anchor: UnitPoint, size: CGSize,
        in context: inout GraphicsContext
    ) {
        let resolved = context.resolve(Text(text).font(ResoniqFont.axis).foregroundStyle(ResoniqColor.muted))
        let height = resolved.measure(in: size).height
        // Keep the end labels inside the ruler instead of cutting them at its edges.
        let centre = min(max(y, height / 2), size.height - height / 2)
        context.draw(resolved, at: CGPoint(x: x, y: centre), anchor: anchor)
    }

    private enum Metrics {
        static let besideWidth: CGFloat = 40
        static let betweenWidth: CGFloat = 48
        static let majorTick: CGFloat = 8
        static let minorTick: CGFloat = 4
        static let labelGap: CGFloat = 4
        static let betweenTick: CGFloat = 8
        static let betweenLabelHalfWidth: CGFloat = 14
    }
}

#Preview("Beside and between") {
    HStack(spacing: ResoniqSpace.s4) {
        FrequencyRuler(.beside)
        FrequencyRuler(.between)
    }
    .frame(height: 360)
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.panel)
}
