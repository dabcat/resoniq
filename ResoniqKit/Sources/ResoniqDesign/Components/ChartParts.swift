import SwiftUI

// MARK: - Shapes

/// A trace of levels as a smooth curve.
struct TraceShape: Shape {
    var levels: [Double]
    var range: Double

    func path(in rect: CGRect) -> Path {
        ChartGeometry.smoothPath(through: ChartGeometry.points(levels: levels, range: range, in: rect))
    }
}

/// The even band: from `+evenBand` to `-evenBand`, across the whole width.
struct EvenBandShape: Shape {
    var evenBand: Double
    var range: Double

    func path(in rect: CGRect) -> Path {
        let band = evenBand.isFinite ? abs(evenBand) : 0
        let top = ChartGeometry.y(level: band, range: range, in: rect)
        let bottom = ChartGeometry.y(level: -band, range: range, in: rect)
        return Path(CGRect(x: rect.minX, y: top, width: rect.width, height: max(bottom - top, 0)))
    }
}

/// Hairlines of a plot: a vertical one at each frequency, a horizontal one at each level, and optionally the
/// top and bottom edges.
struct PlotGridShape: Shape {
    var frequencies: [Double]
    var levels: [Double]
    var range: Double
    var framed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for hertz in frequencies {
            let x = ChartGeometry.x(fraction: FrequencyRuler.fraction(forFrequency: hertz), in: rect)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for level in levels {
            let y = ChartGeometry.y(level: level, range: range, in: rect)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        if framed {
            for y in [rect.minY, rect.maxY] {
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        return path
    }
}

/// Full-height columns over fractions of the width: where a mask lets the out-of-band parts through.
struct ColumnsShape: Shape {
    var ranges: [ClosedRange<Double>]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for range in ranges {
            let left = ChartGeometry.x(fraction: range.lowerBound, in: rect)
            let right = ChartGeometry.x(fraction: range.upperBound, in: rect)
            path.addRect(CGRect(x: left, y: rect.minY, width: right - left, height: rect.height))
        }
        return path
    }
}

// MARK: - Drawing in

/// Shows its content from the left edge up to `fraction` of the width: the trace "draws" as the fraction grows.
/// The reach beyond the edges keeps round caps from being cut when the fraction is 1.
struct LeftToRightReveal: ViewModifier {
    var fraction: Double

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                let full = proxy.size.width + 2 * Metrics.reach
                let shown = min(max(fraction.isNaN ? 0 : fraction, 0), 1)
                Rectangle()
                    .frame(width: full * shown)
                    .frame(width: full, height: proxy.size.height + 2 * Metrics.reach, alignment: .leading)
                    .offset(x: -Metrics.reach, y: -Metrics.reach)
            }
        }
    }

    private enum Metrics {
        static let reach: CGFloat = 8
    }
}

// MARK: - The plot

/// A response plot as used by the response curve and the building average: grid, even band, a main trace in the
/// frequency gradient (optionally with its out-of-band parts in `signal`), faint traces behind it, a dashed
/// "before" trace, and the dots and mono labels at the extremes.
struct ResponsePlot: View {
    var levels: [Double]
    var faintTraces: [[Double]] = []
    var before: [Double]?
    var evenBand: Double
    var range: Double
    var extremes: [ResponseCurve.Extreme] = []
    var marksOutOfBand = true
    /// How much of the main trace is drawn, 0...1.
    var reveal: Double = 1
    var height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .topLeading) {
                EvenBandShape(evenBand: evenBand, range: range)
                    .fill(ResoniqColor.panelRaised)
                PlotGridShape(frequencies: Metrics.gridFrequencies, levels: [], range: range, framed: true)
                    .stroke(ResoniqColor.line, lineWidth: ResoniqSize.strokeHairline)

                ForEach(faintTraces.indices, id: \.self) { index in
                    TraceShape(levels: faintTraces[index], range: range)
                        .stroke(
                            ResoniqColor.muted.opacity(faintOpacity(at: index)),
                            style: traceStyle(Metrics.faintStroke)
                        )
                }

                if let before {
                    TraceShape(levels: before, range: range)
                        .stroke(
                            ResoniqColor.muted,
                            style: StrokeStyle(lineWidth: Metrics.beforeStroke, lineCap: .round, lineJoin: .round, dash: Metrics.beforeDash)
                        )
                }

                ZStack {
                    TraceShape(levels: levels, range: range)
                        .stroke(ResoniqGradient.frequencyHorizontal, style: traceStyle(Metrics.traceStroke))
                    if marksOutOfBand {
                        TraceShape(levels: levels, range: range)
                            .stroke(ResoniqColor.signal, style: traceStyle(Metrics.outOfBandStroke))
                            .mask { ColumnsShape(ranges: outsideRanges) }
                    }
                }
                .modifier(LeftToRightReveal(fraction: reveal))

                if !extremes.isEmpty {
                    markers(in: rect)
                        .opacity(reveal >= 1 ? 1 : 0)
                }
            }
        }
        .frame(height: height)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    private var outsideRanges: [ClosedRange<Double>] {
        ChartGeometry.segments(levels: levels, evenBand: evenBand)
            .filter(\.isOutside)
            .map { $0.start...$0.end }
    }

    private func faintOpacity(at index: Int) -> Double {
        // The newest is the strongest; one trace alone is at the mockup's 0.7.
        Metrics.faintOpacity * Double(index + 1) / Double(faintTraces.count)
    }

    private func traceStyle(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    private func anchor(_ extreme: ResponseCurve.Extreme, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: ChartGeometry.x(fraction: extreme.position, in: rect),
            y: ChartGeometry.y(level: extreme.level, range: range, in: rect)
        )
    }

    /// The dot, the pulse ring and the mono label of each extreme.
    private func markers(in rect: CGRect) -> some View {
        let anchors = extremes.map { anchor($0, in: rect) }
        return ZStack(alignment: .topLeading) {
            ForEach(extremes.indices, id: \.self) { index in
                PulseRing(delay: Double(index) * Metrics.ringStagger)
                    .position(anchors[index])
            }
            Canvas { context, size in
                let plot = CGRect(origin: .zero, size: size)
                let labels = extremes.map {
                    context.resolve(Text($0.label).font(ResoniqFont.axis).foregroundStyle(ResoniqColor.signalText))
                }
                let requests = extremes.indices.map { index in
                    ChartGeometry.LabelRequest(
                        anchor: anchors[index],
                        size: labels[index].measure(in: size),
                        prefersAbove: extremes[index].level >= 0
                    )
                }
                let trace = ChartGeometry.points(levels: levels, range: range, in: plot)
                let frames = ChartGeometry.placeLabels(requests, in: plot, avoiding: trace)
                let radius = Metrics.dotRadius
                for index in extremes.indices {
                    let centre = anchors[index]
                    context.fill(
                        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)),
                        with: .color(ResoniqColor.signal)
                    )
                    context.draw(labels[index], at: frames[index].origin, anchor: .topLeading)
                }
            }
        }
    }

    private enum Metrics {
        static let traceStroke: CGFloat = ResoniqSize.strokeTrace
        /// The mockups overdraw the out-of-band part at 3.4.
        static let outOfBandStroke: CGFloat = 3.4
        static let faintStroke: CGFloat = 1.6
        static let faintOpacity: Double = 0.7
        static let beforeStroke: CGFloat = 1.8
        static let beforeDash: [CGFloat] = [4, 5]
        static let dotRadius: CGFloat = 4.5
        static let ringStagger: Double = 0.9
        static let gridFrequencies: [Double] = [100, 1_000, 10_000]
    }
}

/// The ring that leaves a marker and fades: "pulse ring" of the motion table. Absent while Reduce Motion is on.
struct PulseRing: View {
    var delay: Double = 0
    var diameter: CGFloat = 9
    var color: Color = ResoniqColor.signal
    var lineWidth: CGFloat = 1.5

    /// loop.pulseRing: scale to 2.6.
    static let toScale: CGFloat = 2.6
    static let fromOpacity: Double = 0.8

    var body: some View {
        LoopingPhase(isRunning: true, animation: ResoniqMotion.pulseRing.delay(delay)) { phase, isActive in
            Circle()
                .stroke(color, lineWidth: lineWidth)
                .frame(width: diameter, height: diameter)
                .scaleEffect(phase ? Self.toScale : 1)
                .opacity(isActive ? (phase ? 0 : Self.fromOpacity) : 0)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Axis, header, legend

/// The frequency labels under a plot: "20 Hz", "100", "1k", "10k", "20k", each centred on its true place on the
/// log axis and held inside the width.
struct FrequencyAxisLabels: View {
    var body: some View {
        FrequencyAxisLayout(fractions: FrequencyRuler.majorTicks.map { FrequencyRuler.fraction(forFrequency: $0) }) {
            ForEach(FrequencyRuler.majorTicks, id: \.self) { hertz in
                Text(text(for: hertz))
                    .font(ResoniqFont.axis)
                    .foregroundStyle(ResoniqColor.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityHidden(true)
    }

    private func text(for hertz: Double) -> String {
        let label = FrequencyRuler.label(forFrequency: hertz)
        return hertz == FrequencyRuler.lowestFrequency ? "\(label) Hz" : label
    }
}

private struct FrequencyAxisLayout: Layout {
    var fractions: [Double]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: proposal.width ?? 0,
            height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, fraction) in zip(subviews, fractions) {
            let size = subview.sizeThatFits(.unspecified)
            let centre = bounds.minX + bounds.width * CGFloat(fraction)
            let left = min(max(centre - size.width / 2, bounds.minX), max(bounds.maxX - size.width, bounds.minX))
            subview.place(at: CGPoint(x: left, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
        }
    }
}

/// One entry of a chart legend: a short line in the trace's style and its name.
public struct ResoniqLegendEntry: Sendable, Identifiable {
    public let title: String
    public let color: Color
    public let isDashed: Bool
    public var id: String { title }

    public init(_ title: String, color: Color, isDashed: Bool = false) {
        self.title = title
        self.color = color
        self.isDashed = isDashed
    }
}

/// The legend row: a line sample in each trace's colour and style, then its name. The style is drawn, so the
/// traces are told apart by more than colour.
struct ChartLegend: View {
    var entries: [ResoniqLegendEntry]

    var body: some View {
        HStack(spacing: Metrics.entryGap) {
            ForEach(entries) { entry in
                HStack(spacing: Metrics.sampleGap) {
                    Canvas { context, size in
                        var path = Path()
                        path.move(to: CGPoint(x: Metrics.capInset, y: size.height / 2))
                        path.addLine(to: CGPoint(x: size.width - Metrics.capInset, y: size.height / 2))
                        context.stroke(
                            path,
                            with: .color(entry.color),
                            style: StrokeStyle(lineWidth: Metrics.sampleStroke, lineCap: .round, dash: entry.isDashed ? Metrics.sampleDash : [])
                        )
                    }
                    .frame(width: Metrics.sampleWidth, height: Metrics.sampleHeight)
                    Text(entry.title)
                        .font(ResoniqFont.caption)
                        .foregroundStyle(ResoniqColor.ivory)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private enum Metrics {
        static let entryGap: CGFloat = 14
        static let sampleGap: CGFloat = 6
        static let sampleWidth: CGFloat = 18
        static let sampleHeight: CGFloat = 4
        static let sampleStroke: CGFloat = 3
        static let capInset: CGFloat = 1
        static let sampleDash: [CGFloat] = [5, 4]
    }
}

/// The caps label on the left of a chart and the quieter caps text on the right ("Even band ±3 dB").
struct ChartHeader: View {
    var title: String?
    var detail: String?

    var body: some View {
        if title != nil || detail != nil {
            HStack(alignment: .firstTextBaseline) {
                if let title { Text(title).resoniqCapsLabel() }
                Spacer(minLength: ResoniqSpace.s2)
                if let detail { Text(detail).resoniqCapsLabel().multilineTextAlignment(.trailing) }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Drives the draw-once animation of a chart: by the caller's `progress`, or, with `drawsOnAppear`, by the chart
/// itself, once, over `ResoniqMotion.traceDraw`. With Reduce Motion the finished trace is simply there.
struct DrawnOnce<Content: View>: View {
    var drawsOnAppear: Bool
    var progress: Double
    @ViewBuilder var content: (_ reveal: Double) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasDrawn = false

    var body: some View {
        content(drawsOnAppear && !hasDrawn && !reduceMotion ? 0 : progress)
            .onAppear {
                guard drawsOnAppear, !reduceMotion else {
                    hasDrawn = true
                    return
                }
                withAnimation(ResoniqMotion.traceDraw) { hasDrawn = true }
            }
    }
}
