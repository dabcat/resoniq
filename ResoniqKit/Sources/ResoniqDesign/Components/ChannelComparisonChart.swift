import SwiftUI

/// Left and right on one decibel grid (V3MDetail): the left trace solid `guide`, the right dashed `lime`, so the
/// two are told apart by line style and by the legend's words, not by colour alone. The grid's lines are
/// labelled in decibels on the left, the frequency axis is under the plot, and the even band sits behind both.
///
/// Put it in a panel (`resoniqPanel()`). One element for VoiceOver: the sentence passed as `accessibilityLabel`.
public struct ChannelComparisonChart: View {
    private let left: [Double]
    private let right: [Double]
    private let range: Double
    private let gridStep: Double
    private let evenBand: Double
    private let caption: String?
    private let progress: Double
    private let drawsOnAppear: Bool
    private let accessibilityText: String

    @ScaledMetric(relativeTo: .caption2) private var labelWidth: CGFloat = Metrics.labelWidth

    /// - Parameters:
    ///   - left: Decibels relative to the middle, log-spaced from 20 Hz to 20 kHz.
    ///   - right: The same for the right speaker.
    ///   - range: The decibels shown above and below the middle (12).
    ///   - gridStep: Decibels between labelled grid lines (6).
    ///   - evenBand: The even band, plus and minus this many decibels (3).
    ///   - caption: The mono note in the legend row ("1/3-octave smoothing"), written by the caller.
    ///   - progress: How much of the traces is drawn, 0...1.
    ///   - drawsOnAppear: The traces draw themselves once when the chart appears.
    ///   - accessibilityLabel: One sentence that states what the chart shows.
    public init(
        left: [Double],
        right: [Double],
        range: Double = 12,
        gridStep: Double = 6,
        evenBand: Double = 3,
        caption: String? = nil,
        progress: Double = 1,
        drawsOnAppear: Bool = false,
        accessibilityLabel: String
    ) {
        self.left = left
        self.right = right
        self.range = range
        self.gridStep = gridStep
        self.evenBand = evenBand
        self.caption = caption
        self.progress = progress
        self.drawsOnAppear = drawsOnAppear
        self.accessibilityText = accessibilityLabel
    }

    /// The levels of the labelled lines, top to bottom: +12, +6, 0, -6, -12.
    nonisolated static func gridLevels(range: Double, step: Double) -> [Double] {
        let limit = ChartGeometry.safeRange(range)
        guard step.isFinite, step > 0, limit / step < 100 else { return [limit, 0, -limit] }
        let count = Int((limit / step).rounded(.down))
        let positive = (1...max(count, 1)).map { Double($0) * step }.filter { $0 <= limit }
        return positive.reversed() + [0] + positive.map { -$0 }
    }

    public var body: some View {
        let levels = Self.gridLevels(range: range, step: gridStep)
        VStack(alignment: .leading, spacing: Metrics.gap) {
            HStack(alignment: .firstTextBaseline) {
                ChartLegend(entries: [
                    ResoniqLegendEntry("Left", color: ResoniqColor.guide),
                    ResoniqLegendEntry("Right", color: ResoniqColor.lime, isDashed: true),
                ])
                Spacer(minLength: ResoniqSpace.s2)
                if let caption {
                    Text(caption)
                        .font(ResoniqFont.axis)
                        .foregroundStyle(ResoniqColor.muted)
                        .multilineTextAlignment(.trailing)
                        .accessibilityHidden(true)
                }
            }
            HStack(alignment: .top, spacing: Metrics.labelGap) {
                gridLabels(levels)
                DrawnOnce(drawsOnAppear: drawsOnAppear, progress: progress) { reveal in
                    plot(levels: levels, reveal: reveal)
                }
            }
            FrequencyAxisLabels()
                .padding(.leading, labelWidth + Metrics.labelGap)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
    }

    private func plot(levels gridLevels: [Double], reveal: Double) -> some View {
        ZStack {
            EvenBandShape(evenBand: evenBand, range: range)
                .fill(ResoniqColor.panelRaised)
            PlotGridShape(frequencies: Metrics.gridFrequencies, levels: gridLevels, range: range, framed: false)
                .stroke(ResoniqColor.line, lineWidth: ResoniqSize.strokeHairline)
            Group {
                TraceShape(levels: left, range: range)
                    .stroke(ResoniqColor.guide, style: StrokeStyle(lineWidth: Metrics.traceStroke, lineCap: .round, lineJoin: .round))
                TraceShape(levels: right, range: range)
                    .stroke(
                        ResoniqColor.lime,
                        style: StrokeStyle(lineWidth: Metrics.traceStroke, lineCap: .round, lineJoin: .round, dash: Metrics.rightDash)
                    )
            }
            .modifier(LeftToRightReveal(fraction: reveal))
        }
        .frame(height: Metrics.plotHeight)
    }

    /// The decibel labels, each on its grid line.
    private func gridLabels(_ levels: [Double]) -> some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            ForEach(levels, id: \.self) { level in
                Text(ChartGeometry.gridLabel(level))
                    .font(Metrics.labelFont)
                    .foregroundStyle(ResoniqColor.muted)
                    .lineLimit(1)
                    .frame(width: proxy.size.width, alignment: .trailing)
                    .position(x: proxy.size.width / 2, y: ChartGeometry.y(level: level, range: range, in: rect))
            }
        }
        .frame(width: labelWidth, height: Metrics.plotHeight)
        .accessibilityHidden(true)
    }

    private enum Metrics {
        /// V3MDetail: the plot is 180 pt tall, the label column 24 pt wide, 6 pt apart.
        static let plotHeight: CGFloat = 180
        static let labelWidth: CGFloat = 24
        static let labelGap: CGFloat = 6
        static let gap: CGFloat = 8
        static let traceStroke: CGFloat = 2.4
        static let rightDash: [CGFloat] = [6, 5]
        static let gridFrequencies: [Double] = [100, 1_000, 10_000]
        static let labelFont = ResoniqFont.font(.monoRegular, size: 10, relativeTo: .caption2)
    }
}

#Preview("Left and right") {
    ChannelComparisonChart(
        left: PreviewCurves.seat,
        right: PreviewCurves.seat.enumerated().map { index, level in level + 1.2 * sin(Double(index) / 6) },
        caption: "1/3-octave smoothing",
        drawsOnAppear: true,
        accessibilityLabel: "Left and right speaker response at the seat on a decibel grid. Both swing up at 41 hertz and down at 61 hertz, then run close together within 3 decibels."
    )
    .resoniqPanel()
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
