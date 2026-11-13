import SwiftUI

// MARK: - Geometry

/// One run's trace, laid in its own lane: lane 0 is the top, and a level of 0.5 sits on the lane's middle line.
/// `span` picks the part of the width to draw, as fractions, so one trace can be drawn in pieces.
///
/// A level that is nil (or not a number) is a gap: nothing was measured there, so the line stops and starts again
/// after it. A trace is never drawn through a value nobody measured.
struct RunTraceShape: Shape {
    var levels: [Double?]
    var lane: Int
    var laneCount: Int
    var span: ClosedRange<Double>
    /// How much of the lane the trace may swing across.
    static let laneFill: CGFloat = 0.9

    /// The level at a fraction of the width, from the samples laid out evenly; nil in a gap or with no samples. Between
    /// two samples it is interpolated, so a gap on either side of the pair leaves the stretch between them empty.
    static func level(at fraction: Double, in levels: [Double?]) -> Double? {
        let clean: [Double?] = levels.map { level in
            guard let level, !level.isNaN else { return nil }
            return min(max(level, 0), 1)
        }
        guard !clean.isEmpty else { return nil }
        guard clean.count > 1 else { return clean[0] }
        let position = min(max(fraction.isNaN ? 0 : fraction, 0), 1) * Double(clean.count - 1)
        let index = min(Int(position), clean.count - 2)
        let t = position - Double(index)
        if t < 1e-9 { return clean[index] }
        if t > 1 - 1e-9 { return clean[index + 1] }
        guard let low = clean[index], let high = clean[index + 1] else { return nil }
        return low + (high - low) * t
    }

    func path(in rect: CGRect) -> Path {
        guard laneCount > 0, lane >= 0, lane < laneCount, rect.width > 0, rect.height > 0 else { return Path() }
        let start = min(max(span.lowerBound.isNaN ? 0 : span.lowerBound, 0), 1)
        let end = min(max(span.upperBound.isNaN ? 0 : span.upperBound, 0), 1)
        guard end > start else { return Path() }

        let laneHeight = rect.height / CGFloat(laneCount)
        let middle = rect.minY + laneHeight * (CGFloat(lane) + 0.5)
        func point(_ fraction: Double, _ level: Double) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * CGFloat(fraction),
                y: middle - CGFloat(level - 0.5) * laneHeight * Self.laneFill
            )
        }

        // The span's start, the samples inside it, the span's end.
        var fractions = [start]
        let count = levels.count
        if count > 1 {
            for index in 0..<count {
                let fraction = Double(index) / Double(count - 1)
                if fraction > start && fraction < end { fractions.append(fraction) }
            }
        }
        fractions.append(end)

        var path = Path()
        var isDrawing = false
        for fraction in fractions {
            guard let level = Self.level(at: fraction, in: levels) else {
                isDrawing = false
                continue
            }
            let next = point(fraction, level)
            if isDrawing {
                path.addLine(to: next)
            } else {
                // A zero-length line, so a lone measured sample still shows as a dot under a round cap.
                path.move(to: next)
                path.addLine(to: next)
                isDrawing = true
            }
        }
        return path
    }
}

// MARK: - View

/// Several runs of the same test laid one above the other over one frequency range, with the part that turns
/// rough in each run marked (V3Finding). Where the rough parts line up, the problem repeats.
///
/// The caller writes the axis under it ("40 Hz · 70–110 Hz · 200 Hz"), which is why this draws no text.
public struct RunOverlay: View {
    private let traces: [[Double?]]
    private let markedRange: ClosedRange<Double>
    private let accessibilityText: String?

    /// - Parameters:
    ///   - traces: One array of levels per run, each 0...1 with 0.5 as the middle of its lane, spread evenly
    ///     over the width. The first run is drawn at the top. A nil level is a gap: nothing was measured there.
    ///   - markedRange: The range that turns rough, as fractions of the width.
    ///   - accessibilityLabel: One sentence that states the finding, e.g. "Three runs, all rough between 70
    ///     and 110 hertz". A default says only how many runs there are.
    public init(traces: [[Double?]], markedRange: ClosedRange<Double>, accessibilityLabel: String? = nil) {
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

#Preview("A run with a gap") {
    let calm: [Double?] = (0..<60).map { index in (20..<30).contains(index) ? nil : 0.5 + 0.2 * sin(Double(index) / 6) }
    RunOverlay(traces: [calm, calm, calm], markedRange: 0.38...0.62)
        .padding(ResoniqSpace.panelPadding)
        .resoniqPanel()
        .padding(ResoniqSpace.screenInset)
        .background(ResoniqColor.ink)
}

#Preview("Three runs") {
    let rough: (Double) -> [Double?] = { seed in
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
