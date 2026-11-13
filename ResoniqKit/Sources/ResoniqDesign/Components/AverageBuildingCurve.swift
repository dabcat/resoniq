import SwiftUI

/// The average as it builds while the spots are measured (V3MRunning): each earlier spot's trace faint, the
/// newest a little stronger, and the running average on top in the frequency scale.
///
/// While `isBuilding` is true the average redraws itself left to right on a loop (4 s) to say that it is still
/// being worked out; Reduce Motion, or `isBuilding == false`, shows it whole. Put it in a panel.
public struct AverageBuildingCurve: View {
    private let traces: [[Double]]
    private let average: [Double]
    private let evenBand: Double
    private let range: Double
    private let isBuilding: Bool
    private let progress: Double
    private let title: String?
    private let detail: String?
    private let accessibilityText: String

    /// - Parameters:
    ///   - traces: One array of levels per spot already measured, oldest first, each log-spaced from 20 Hz to
    ///     20 kHz in decibels relative to the middle.
    ///   - average: The average of the spots so far, on the same scale.
    ///   - evenBand: The even band, plus and minus this many decibels (3).
    ///   - range: The decibels shown above and below the middle.
    ///   - isBuilding: The average is still being worked out, so it redraws on a loop.
    ///   - progress: How much of the average is drawn when it is not looping, 0...1.
    ///   - title: The caps label on the left ("Building the average").
    ///   - detail: The caps text on the right ("1 of 3 in").
    ///   - accessibilityLabel: One sentence that says how far the average has come.
    public init(
        traces: [[Double]],
        average: [Double],
        evenBand: Double,
        range: Double,
        isBuilding: Bool = true,
        progress: Double = 1,
        title: String? = nil,
        detail: String? = nil,
        accessibilityLabel: String
    ) {
        self.traces = traces
        self.average = average
        self.evenBand = evenBand
        self.range = range
        self.isBuilding = isBuilding
        self.progress = progress
        self.title = title
        self.detail = detail
        self.accessibilityText = accessibilityLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            ChartHeader(title: title, detail: detail)
            LoopingPhase(isRunning: isBuilding, animation: Metrics.build) { phase, isActive in
                ResponsePlot(
                    levels: average, faintTraces: traces, evenBand: evenBand, range: range,
                    marksOutOfBand: false, reveal: isActive ? (phase ? 1 : 0) : progress,
                    height: Metrics.plotHeight
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
        /// The plot of V3MRunning is 140 pt tall.
        static let plotHeight: CGFloat = 140
        /// V3MRunning: the average draws over 4 s and starts again.
        static let build = Animation.easeInOut(duration: 4).repeatForever(autoreverses: false)
    }
}

#Preview("Building") {
    VStack(spacing: ResoniqSpace.s4) {
        AverageBuildingCurve(
            traces: [PreviewCurves.seat],
            average: PreviewCurves.improved,
            evenBand: 3, range: 12,
            title: "Building the average", detail: "1 of 3 in",
            accessibilityLabel: "The first spot's line is drawn faintly; the second spot's line will be laid over it."
        )
        .resoniqPanel()
        AverageBuildingCurve(
            traces: [PreviewCurves.seat, PreviewCurves.improved],
            average: PreviewCurves.seat.indices.map { (PreviewCurves.seat[$0] + PreviewCurves.improved[$0]) / 2 },
            evenBand: 3, range: 12, isBuilding: false,
            title: "Building the average", detail: "2 of 3 in",
            accessibilityLabel: "Two spots are in; the average of them is drawn over their faint lines."
        )
        .resoniqPanel()
    }
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
