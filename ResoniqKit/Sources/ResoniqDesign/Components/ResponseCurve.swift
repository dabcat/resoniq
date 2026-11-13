import SwiftUI

/// The seat's response across pitch (V3Measure, V3OVerify): a horizontal log-frequency axis from 20 Hz to 20 kHz,
/// the even band behind the trace, the trace in the frequency scale, the parts outside the band overdrawn in
/// `signal` with a dot and a mono label at each extreme, and the frequency labels under it.
///
/// Put it in a panel (`resoniqPanel()`). It draws its own header, if given, and axis, and is one element for
/// VoiceOver: the sentence passed as `accessibilityLabel`, which should state the finding.
public struct ResponseCurve: View {
    /// A labelled extreme: where the trace leaves the even band furthest.
    public struct Extreme: Sendable, Equatable {
        /// Where it sits on the frequency axis, 0 (20 Hz) to 1 (20 kHz). `FrequencyRuler.fraction(forFrequency:)`
        /// turns hertz into this.
        public var position: Double
        /// Its level in decibels relative to the curve's middle.
        public var level: Double
        /// The mono label, e.g. "41 Hz +9 dB".
        public var label: String

        public init(position: Double, level: Double, label: String) {
            self.position = position
            self.level = level
            self.label = label
        }

        public init(frequency: Double, level: Double, label: String) {
            self.init(position: FrequencyRuler.fraction(forFrequency: frequency), level: level, label: label)
        }
    }

    private let levels: [Double]
    private let evenBand: Double
    private let range: Double
    private let extremes: [Extreme]
    private let before: [Double]?
    private let progress: Double
    private let drawsOnAppear: Bool
    private let title: String?
    private let detail: String?
    private let legend: [ResoniqLegendEntry]
    private let accessibilityText: String

    /// - Parameters:
    ///   - levels: Decibels relative to the curve's middle, log-spaced from 20 Hz (first) to 20 kHz (last).
    ///   - evenBand: The even band, plus and minus this many decibels (3).
    ///   - range: The decibels shown above and below the middle; levels beyond it are held at the edge.
    ///   - extremes: Labelled dots, each beside its trace and kept clear of it and of one another.
    ///   - before: An earlier trace, drawn dashed in `muted` (V3OVerify).
    ///   - progress: How much of the trace is drawn, 0...1. Animate it with `ResoniqMotion.traceDraw`; Reduce
    ///     Motion drops that animation.
    ///   - drawsOnAppear: The trace draws itself once when the chart appears ("Trace draw", 1.6 s), over
    ///     `progress`. Without motion it is simply there.
    ///   - title: The caps label above the plot on the left ("Loudness at your seat").
    ///   - detail: The caps text above the plot on the right ("Even band ±3 dB").
    ///   - legend: Entries shown under the header, for a chart with a "before" trace.
    ///   - accessibilityLabel: One sentence that states what the curve shows.
    public init(
        levels: [Double],
        evenBand: Double,
        range: Double,
        extremes: [Extreme] = [],
        before: [Double]? = nil,
        progress: Double = 1,
        drawsOnAppear: Bool = false,
        title: String? = nil,
        detail: String? = nil,
        legend: [ResoniqLegendEntry] = [],
        accessibilityLabel: String
    ) {
        self.levels = levels
        self.evenBand = evenBand
        self.range = range
        self.extremes = extremes
        self.before = before
        self.progress = progress
        self.drawsOnAppear = drawsOnAppear
        self.title = title
        self.detail = detail
        self.legend = legend
        self.accessibilityText = accessibilityLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            ChartHeader(title: title, detail: detail)
            if !legend.isEmpty { ChartLegend(entries: legend) }
            DrawnOnce(drawsOnAppear: drawsOnAppear, progress: progress) { reveal in
                ResponsePlot(
                    levels: levels, before: before, evenBand: evenBand, range: range,
                    extremes: extremes, reveal: reveal, height: Metrics.plotHeight
                )
            }
            FrequencyAxisLabels()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
    }

    private enum Metrics {
        static let gap: CGFloat = 8
        /// The plot of V3Measure is 146 pt tall.
        static let plotHeight: CGFloat = 146
    }
}

#Preview("Mockup curve, before and after") {
    /// +9 dB at 41 Hz, -11 dB at 61 Hz, even above 100 Hz.
    let curve = PreviewCurves.seat
    ScrollView {
        VStack(spacing: ResoniqSpace.s4) {
            ResponseCurve(
                levels: curve, evenBand: 3, range: 12,
                extremes: [
                    .init(frequency: 41, level: 9, label: "41 Hz +9 dB"),
                    .init(frequency: 61, level: -11, label: "61 Hz \u{2212}11 dB"),
                ],
                drawsOnAppear: true,
                title: "Loudness at your seat", detail: "Even band \u{00B1}3 dB",
                accessibilityLabel: "Loudness across pitch at the seat. Below 100 hertz the line swings far outside the even band; above that it stays inside."
            )
            .resoniqPanel()

            ResponseCurve(
                levels: PreviewCurves.improved, evenBand: 3, range: 12,
                before: curve,
                legend: [
                    ResoniqLegendEntry("Before", color: ResoniqColor.muted, isDashed: true),
                    ResoniqLegendEntry("After", color: ResoniqColor.teal),
                ],
                accessibilityLabel: "Before and after. The peak at 41 hertz is lower and the dip at 61 hertz is much shallower."
            )
            .resoniqPanel()

            ResponseCurve(levels: [], evenBand: 3, range: 12, title: "No data yet", accessibilityLabel: "No measurement yet.")
                .resoniqPanel()
        }
        .padding(ResoniqSpace.screenInset)
    }
    .background(ResoniqColor.ink)
}

/// Representative data for previews and the gallery: the mockups' curve, +9 dB at 41 Hz, -11 dB at 61 Hz, even
/// above 100 Hz.
public enum PreviewCurves {
    /// 96 log-spaced samples from 20 Hz to 20 kHz.
    public static let seat: [Double] = shaped(peak: 9, dip: -11)
    /// The same room after the speakers moved: a smaller peak and a shallower dip.
    public static let improved: [Double] = shaped(peak: 3.5, dip: -4)

    private static func shaped(peak: Double, dip: Double) -> [Double] {
        (0..<96).map { index in
            let fraction = Double(index) / 95
            let hertz = FrequencyRuler.frequency(forFraction: fraction)
            let bump = { (centre: Double, width: Double) -> Double in
                let distance = log(hertz / centre) / width
                return exp(-distance * distance)
            }
            let ripple = 1.2 * sin(fraction * 23)
            let treble = hertz > 100 ? ripple * 0.7 : 0
            let rolloff = fraction > 0.93 ? -(fraction - 0.93) * 140 : 0
            return peak * bump(41, 0.13) + dip * bump(61, 0.09) + treble + rolloff
        }
    }
}
