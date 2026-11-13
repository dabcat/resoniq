import SwiftUI

// MARK: - Geometry

/// The bars' numbers, kept apart from drawing so they can be tested on the Mac.
enum SpectrumGeometry {
    /// Height of a bar as a fraction of the plot, 0...1. NaN and levels below the range are 0, above it are 1.
    static func barFraction(level: Double, range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span.isFinite, span > 0, !level.isNaN else { return 0 }
        return min(max((level - range.lowerBound) / span, 0), 1)
    }

    /// One rectangle per level, side by side across the plot, standing on its bottom edge. A bar at the bottom of
    /// the range is still `minimumHeight` tall so that a quiet band is shown as quiet, not as missing.
    static func bars(levels: [Double], range: ClosedRange<Double>, in rect: CGRect, gap: CGFloat, minimumHeight: CGFloat) -> [CGRect] {
        guard !levels.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let slot = rect.width / CGFloat(levels.count)
        let width = max(slot - gap, min(slot, 1))
        return levels.enumerated().map { index, level in
            let height = max(CGFloat(barFraction(level: level, range: range)) * rect.height, min(minimumHeight, rect.height))
            return CGRect(x: rect.minX + slot * CGFloat(index) + (slot - width) / 2, y: rect.maxY - height, width: width, height: height)
        }
    }
}

// MARK: - View

/// "Watch the sound live": one bar per third-octave band across 20 Hz to 20 kHz, coloured left to right with the
/// frequency scale, with the frequency labels under it. It is drawn in one `Canvas`, so it is cheap to redraw
/// many times a second. Put it in a panel.
///
/// One element for VoiceOver (it is marked as updating frequently): the sentence passed as `accessibilityLabel`,
/// which the caller keeps current without chattering ("Loudest around 90 hertz").
public struct SpectrumBars: View {
    private let levels: [Double]
    private let range: ClosedRange<Double>
    private let title: String?
    private let detail: String?
    private let accessibilityText: String

    /// - Parameters:
    ///   - levels: Band levels in decibels, log-spaced from 20 Hz (first) to 20 kHz (last).
    ///   - range: The decibels from the bottom to the top of the plot.
    ///   - title: The caps label above the bars on the left ("Live").
    ///   - detail: The caps text on the right ("dB per third octave").
    ///   - accessibilityLabel: One sentence that states what is heard.
    public init(
        levels: [Double],
        range: ClosedRange<Double> = -90...(-10),
        title: String? = nil,
        detail: String? = nil,
        accessibilityLabel: String
    ) {
        self.levels = levels
        self.range = range
        self.title = title
        self.detail = detail
        self.accessibilityText = accessibilityLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            ChartHeader(title: title, detail: detail)
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                var grid = Path()
                for fraction in Metrics.gridFractions {
                    let y = rect.maxY - rect.height * fraction
                    grid.move(to: CGPoint(x: rect.minX, y: y))
                    grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                context.stroke(grid, with: .color(ResoniqColor.line), lineWidth: ResoniqSize.strokeHairline)

                var bars = Path()
                for bar in SpectrumGeometry.bars(levels: levels, range: range, in: rect, gap: Metrics.barGap, minimumHeight: Metrics.minimumBar) {
                    bars.addRoundedRect(in: bar, cornerSize: CGSize(width: Metrics.barRadius, height: Metrics.barRadius))
                }
                context.fill(
                    bars,
                    with: .linearGradient(
                        Gradient(stops: ResoniqGradient.stops),
                        startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)
                    )
                )
            }
            .frame(height: Metrics.plotHeight)
            FrequencyAxisLabels()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits([.isImage, .updatesFrequently])
    }

    private enum Metrics {
        static let gap: CGFloat = 8
        static let plotHeight: CGFloat = 132
        static let barGap: CGFloat = 2
        static let barRadius: CGFloat = 1.5
        static let minimumBar: CGFloat = 1
        static let gridFractions: [CGFloat] = [0, 0.5, 1]
    }
}

#Preview("Live") {
    let bands = (0..<30).map { index -> Double in
        let t = Double(index) / 29
        return -30 - 40 * t + 18 * exp(-pow((t - 0.25) / 0.08, 2)) + 5 * sin(t * 40)
    }
    VStack(spacing: ResoniqSpace.s4) {
        SpectrumBars(
            levels: bands, title: "Live", detail: "dB per third octave",
            accessibilityLabel: "Loudest around 90 hertz; treble is quiet."
        )
        .resoniqPanel()
        SpectrumBars(
            levels: [], title: "Waiting for sound",
            accessibilityLabel: "No sound yet."
        )
        .resoniqPanel()
    }
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
