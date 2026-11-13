import SwiftUI

// MARK: - Geometry

/// One run's trace, laid in its own lane: lane 0 is the top, and a level of 0.5 sits on the lane's middle line.
/// `span` picks the part of the width to draw, as fractions, so one trace can be drawn in pieces.
struct RunTraceShape: Shape {
    var levels: [Double]
    var lane: Int
    var laneCount: Int
    var span: ClosedRange<Double>
    /// How much of the lane the trace may swing across.
    static let laneFill: CGFloat = 0.9

    /// The level at a fraction of the width, from the samples laid out evenly. 0.5 when there are none.
    static func level(at fraction: Double, in levels: [Double]) -> Double {
        let clean = levels.map { $0.isNaN ? 0.5 : min(max($0, 0), 1) }
        guard !clean.isEmpty else { return 0.5 }
        guard clean.count > 1 else { return clean[0] }
        let position = min(max(fraction.isNaN ? 0 : fraction, 0), 1) * Double(clean.count - 1)
        let index = min(Int(position), clean.count - 2)
        let t = position - Double(index)
        return clean[index] + (clean[index + 1] - clean[index]) * t
    }

    func path(in rect: CGRect) -> Path {
        guard laneCount > 0, lane >= 0, lane < laneCount, rect.width > 0, rect.height > 0 else { return Path() }
        let start = min(max(span.lowerBound.isNaN ? 0 : span.lowerBound, 0), 1)
        let end = min(max(span.upperBound.isNaN ? 0 : span.upperBound, 0), 1)
        guard end > start else { return Path() }

        let laneHeight = rect.height / CGFloat(laneCount)
        let middle = rect.minY + laneHeight * (CGFloat(lane) + 0.5)
        func point(_ fraction: Double) -> CGPoint {
            let level = Self.level(at: fraction, in: levels)
            return CGPoint(
                x: rect.minX + rect.width * CGFloat(fraction),
                y: middle - CGFloat(level - 0.5) * laneHeight * Self.laneFill
            )
        }

        var path = Path()
        path.move(to: point(start))
        // The samples inside the span, then the end of it.
        let count = levels.count
        if count > 1 {
            for index in 0..<count {
                let fraction = Double(index) / Double(count - 1)
                if fraction > start && fraction < end { path.addLine(to: point(fraction)) }
            }
        }
        path.addLine(to: point(end))
        return path
    }
}

// MARK: - View

/// Several runs of the same test laid one above the other over one frequency range, with the part that turns
/// rough in each run marked (V3Finding). Where the rough parts line up, the problem repeats.
///
/// The caller writes the axis under it ("40 Hz · 70–110 Hz · 200 Hz"), which is why this draws no text.
public struct RunOverlay: View {
    private let traces: [[Double]]
    private let markedRange: ClosedRange<Double>
    private let accessibilityText: String?

    /// - Parameters:
    ///   - traces: One array of levels per run, each 0...1 with 0.5 as the middle of its lane, spread evenly
    ///     over the width. The first run is drawn at the top.
    ///   - markedRange: The range that turns rough, as fractions of the width.
    ///   - accessibilityLabel: One sentence that states the finding, e.g. "Three runs, all rough between 70
    ///     and 110 hertz". A default says only how many runs there are.
    public init(traces: [[Double]], markedRange: ClosedRange<Double>, accessibilityLabel: String? = nil) {
        self.traces = traces
        self.markedRange = markedRange
        self.accessibilityText = accessibilityLabel
    }

    public static let laneHeight: CGFloat = 104 / 3

    private var marked: ClosedRange<Double>? {
        let low = min(max(markedRange.lowerBound.isNaN ? 0 : markedRange.lowerBound, 0), 1)
        let high = min(max(markedRange.upperBound.isNaN ? 0 : markedRange.upperBound, 0), 1)
        return high > low ? low...high : nil
    }

    public var body: some View {
        ZStack {
            if let marked {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Metrics.band)
                        .frame(width: proxy.size.width * (marked.upperBound - marked.lowerBound))
                        .offset(x: proxy.size.width * marked.lowerBound)
                }
            }
            ForEach(traces.indices, id: \.self) { lane in
                trace(lane)
            }
        }
        .frame(height: Self.laneHeight * CGFloat(max(traces.count, 1)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? "\(traces.count) test runs one above the other, compared over the same range.")
        .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private func trace(_ lane: Int) -> some View {
        let levels = traces[lane]
        let count = traces.count
        let calm = StrokeStyle(lineWidth: Metrics.calmStroke, lineCap: .round, lineJoin: .round)
        let rough = StrokeStyle(lineWidth: Metrics.roughStroke, lineCap: .round, lineJoin: .round)
        if let marked {
            RunTraceShape(levels: levels, lane: lane, laneCount: count, span: 0...marked.lowerBound)
                .stroke(ResoniqColor.ivory, style: calm)
            RunTraceShape(levels: levels, lane: lane, laneCount: count, span: marked.upperBound...1)
                .stroke(ResoniqColor.ivory, style: calm)
            LoopingPhase(isRunning: true, animation: ResoniqMotion.buzz) { phase, isActive in
                RunTraceShape(levels: levels, lane: lane, laneCount: count, span: marked)
                    .stroke(ResoniqColor.signal, style: rough)
                    .offset(y: isActive ? (phase ? ResoniqMotion.buzzDistance : -ResoniqMotion.buzzDistance) : 0)
            }
        } else {
            RunTraceShape(levels: levels, lane: lane, laneCount: count, span: 0...1)
                .stroke(ResoniqColor.ivory, style: calm)
        }
    }

    private enum Metrics {
        static let calmStroke: CGFloat = 2
        static let roughStroke: CGFloat = 2.5
        /// The tint behind the rough range in V3Finding (#3D2218), a dark `signal` that is not a token.
        static let band = Color(hex: 0x3D2218)
    }
}

#Preview("Three runs") {
    let rough: (Double) -> [Double] = { seed in
        (0..<60).map { index in
            let fraction = Double(index) / 59
            guard (0.38...0.62).contains(fraction) else { return 0.5 }
            return index.isMultiple(of: 2) ? 0.5 + 0.35 * seed : 0.5 - 0.35 * seed
        }
    }
    RunOverlay(traces: [rough(1), rough(0.9), rough(1)], markedRange: 0.38...0.62)
        .padding(ResoniqSpace.panelPadding)
        .resoniqPanel()
        .padding(ResoniqSpace.screenInset)
        .background(ResoniqColor.ink)
}
