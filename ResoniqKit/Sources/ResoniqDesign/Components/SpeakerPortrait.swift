import SwiftUI

// MARK: - Geometry

/// The portrait's numbers, kept apart from drawing so they can be tested on the Mac.
enum PortraitGeometry {
    /// Widths made safe to draw: each held to 0...1, NaN taken as 0, and a single value stretched to a column.
    static func samples(_ widths: [Double]) -> [Double] {
        let clean = widths.map { $0.isNaN ? 0 : min(max($0, 0), 1) }
        return clean.count == 1 ? [clean[0], clean[0]] : clean
    }

    /// Half-width, as a fraction of the half-width available, at a fraction of the height. This follows the
    /// same curve the shape is drawn with: between two samples it eases like a smoothstep.
    static func halfWidth(at fraction: Double, widths: [Double]) -> Double {
        let values = samples(widths)
        guard values.count >= 2 else { return 0 }
        let position = min(max(fraction.isNaN ? 0 : fraction, 0), 1) * Double(values.count - 1)
        let index = min(Int(position), values.count - 2)
        let t = position - Double(index)
        let eased = t * t * (3 - 2 * t)
        return values[index] + (values[index + 1] - values[index]) * eased
    }

    /// The part of `range` inside `limits`, or nil when nothing of it is left.
    static func clipped(_ range: ClosedRange<Double>, to limits: ClosedRange<Double>) -> ClosedRange<Double>? {
        let low = max(range.lowerBound, limits.lowerBound)
        let high = min(range.upperBound, limits.upperBound)
        return low < high ? low...high : nil
    }

    /// The parts of 0...`visible` left once `deviations` are taken out, as fractions of the height.
    static func intervals(upTo visible: Double, excluding deviations: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        let limit = min(max(visible.isNaN ? 0 : visible, 0), 1)
        let cuts = deviations
            .compactMap { clipped($0, to: 0...limit) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<Double>] = []
        var cursor = 0.0
        for cut in cuts {
            if cut.lowerBound > cursor { result.append(cursor...cut.lowerBound) }
            cursor = max(cursor, cut.upperBound)
        }
        if cursor < limit { result.append(cursor...limit) }
        return result
    }
}

/// A symmetric, smooth shape whose half-width follows `widths`: index 0 at the bottom, the last at the top,
/// 1 being the full half-width of the rectangle it is drawn in. It never leaves that rectangle.
struct SpeakerPortraitShape: Shape {
    var widths: [Double]

    func path(in rect: CGRect) -> Path {
        let values = PortraitGeometry.samples(widths)
        guard values.count >= 2, rect.width > 0, rect.height > 0 else { return Path() }
        let half = rect.width / 2
        let last = values.count - 1
        func y(_ index: Int) -> CGFloat { rect.maxY - rect.height * CGFloat(index) / CGFloat(last) }
        func x(_ index: Int, side: CGFloat) -> CGFloat { rect.midX + side * half * CGFloat(values[index]) }

        var path = Path()
        // Up the left edge, then down the right. Each piece leaves and arrives vertically, so the edge is
        // smooth and cannot overshoot the samples.
        path.move(to: CGPoint(x: x(0, side: -1), y: y(0)))
        for index in 0..<last {
            let from = CGPoint(x: x(index, side: -1), y: y(index))
            let to = CGPoint(x: x(index + 1, side: -1), y: y(index + 1))
            let rise = to.y - from.y
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x, y: from.y + rise / 3),
                control2: CGPoint(x: to.x, y: from.y + rise * 2 / 3)
            )
        }
        path.addLine(to: CGPoint(x: x(last, side: 1), y: y(last)))
        for index in stride(from: last, to: 0, by: -1) {
            let from = CGPoint(x: x(index, side: 1), y: y(index))
            let to = CGPoint(x: x(index - 1, side: 1), y: y(index - 1))
            let rise = to.y - from.y
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x, y: from.y + rise / 3),
                control2: CGPoint(x: to.x, y: from.y + rise * 2 / 3)
            )
        }
        path.closeSubpath()
        return path
    }
}

/// The patch of a portrait that deviates: as wide as the portrait there, with a ragged edge on both sides.
struct DeviationBandShape: Shape {
    var widths: [Double]
    var range: ClosedRange<Double>
    /// How far a tooth of the ragged edge cuts into the band, in points.
    var tooth: CGFloat = 4
    /// Height of one tooth, in points.
    var toothHeight: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let low = min(max(range.lowerBound.isNaN ? 0 : range.lowerBound, 0), 1)
        let high = min(max(range.upperBound.isNaN ? 0 : range.upperBound, 0), 1)
        guard high > low, rect.width > 0, rect.height > 0, PortraitGeometry.samples(widths).count >= 2 else {
            return Path()
        }
        let span = rect.height * CGFloat(high - low)
        // An even number of steps, so both ends of the band are flush.
        let steps = max(2, 2 * Int((span / toothHeight / 2).rounded()))
        let half = rect.width / 2

        func point(_ step: Int, side: CGFloat) -> CGPoint {
            let fraction = low + (high - low) * Double(step) / Double(steps)
            let reach = half * CGFloat(PortraitGeometry.halfWidth(at: fraction, widths: widths))
            let bite = step.isMultiple(of: 2) ? 0 : min(tooth, reach)
            return CGPoint(x: rect.midX + side * (reach - bite), y: rect.maxY - rect.height * CGFloat(fraction))
        }

        var path = Path()
        path.move(to: point(0, side: -1))
        for step in 1...steps { path.addLine(to: point(step, side: -1)) }
        for step in stride(from: steps, through: 0, by: -1) { path.addLine(to: point(step, side: 1)) }
        path.closeSubpath()
        return path
    }
}

/// Full-width horizontal bands, as fractions of the height from the bottom. Used to mask what is shown.
struct FractionBandsShape: Shape {
    var bands: [ClosedRange<Double>]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for band in bands {
            let top = rect.maxY - rect.height * CGFloat(band.upperBound)
            let bottom = rect.maxY - rect.height * CGFloat(band.lowerBound)
            path.addRect(CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top))
        }
        return path
    }
}

// MARK: - View

/// The signature graphic: a speaker's shape, as wide as it measured at each pitch, filled with the frequency
/// scale from deep bass (bottom) to treble (top). Put a `FrequencyRuler` of the same height beside it.
///
/// It fills the space it is given; the mockups use about 120 by 430 points.
public struct SpeakerPortrait: View {
    public enum Status: Equatable, Sendable {
        /// Dashed outline with a slow pulse.
        case notHeard
        /// Filled up to `progress` (0...1 of the height) with the sweep line there.
        case drawing(progress: Double)
        /// The same, dimmed, while the test waits.
        case paused(progress: Double)
        case finished
    }

    /// A speaker nobody has heard yet, from the outline in V3Start: 25 widths from 20 Hz to 20 kHz.
    public nonisolated static let unknownSpeakerWidths: [Double] = [
        0.0, 0.326, 0.532, 0.652, 0.649, 0.625, 0.586, 0.547, 0.51, 0.488, 0.503, 0.515, 0.485,
        0.455, 0.469, 0.491, 0.482, 0.452, 0.439, 0.454, 0.461, 0.416, 0.371, 0.193, 0.0,
    ]

    private let widths: [Double]
    private let status: Status
    private let deviations: [ClosedRange<Double>]
    private let accessibilityText: String?

    /// - Parameters:
    ///   - widths: 0...1, index 0 at 20 Hz (bottom), the last at 20 kHz (top), spaced evenly on the log axis.
    ///     In the not-heard state an empty array draws `unknownSpeakerWidths`.
    ///   - deviations: Parts of the height, as fractions, to redraw in `signal` with a trembling ragged edge.
    ///   - accessibilityLabel: One sentence that states the finding. A default describes the state.
    public init(
        widths: [Double] = SpeakerPortrait.unknownSpeakerWidths,
        state: Status,
        deviations: [ClosedRange<Double>] = [],
        accessibilityLabel: String? = nil
    ) {
        self.widths = widths
        self.status = state
        self.deviations = deviations
        self.accessibilityText = accessibilityLabel
    }

    private var drawnWidths: [Double] {
        widths.isEmpty && status == .notHeard ? Self.unknownSpeakerWidths : widths
    }

    /// Fraction of the height that has been drawn.
    private var revealed: Double {
        switch status {
        case .notHeard: 0
        case .drawing(let progress), .paused(let progress): min(max(progress.isNaN ? 0 : progress, 0), 1)
        case .finished: 1
        }
    }

    public var body: some View {
        let shape = SpeakerPortraitShape(widths: drawnWidths)
        GeometryReader { proxy in
            ZStack {
                outline(shape, height: proxy.size.height)
                fill(shape)
                deviationPatches
                sweepLine(height: proxy.size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? defaultLabel)
        .accessibilityAddTraits(.isImage)
    }

    // MARK: Layers

    @ViewBuilder
    private func outline(_ shape: SpeakerPortraitShape, height: CGFloat) -> some View {
        switch status {
        case .notHeard:
            LoopingPhase(isRunning: true, animation: Metrics.notHeardPulse) { phase, isActive in
                shape
                    .stroke(
                        ResoniqColor.ivory,
                        style: StrokeStyle(lineWidth: Metrics.notHeardStroke, lineCap: .round, dash: Metrics.notHeardDash)
                    )
                    .opacity(isActive && !phase ? Metrics.pulseLow : 1)
            }
        case .drawing, .paused:
            // Only the part not yet drawn is an outline.
            shape
                .stroke(
                    ResoniqColor.muted,
                    style: StrokeStyle(lineWidth: Metrics.progressStroke, lineCap: .round, dash: Metrics.progressDash)
                )
                .mask(alignment: .top) {
                    Rectangle().frame(height: height * (1 - revealed))
                }
        case .finished:
            EmptyView()
        }
    }

    @ViewBuilder
    private func fill(_ shape: SpeakerPortraitShape) -> some View {
        if revealed > 0 {
            let bands = PortraitGeometry.intervals(upTo: revealed, excluding: deviations)
            Group {
                if case .paused = status {
                    shape.fill(ResoniqColor.disabled)
                } else {
                    shape.fill(ResoniqGradient.frequencyVertical)
                }
            }
            .mask { FractionBandsShape(bands: bands) }
        }
    }

    @ViewBuilder
    private var deviationPatches: some View {
        let patches = deviations.compactMap { PortraitGeometry.clipped($0, to: 0...revealed) }
        if !patches.isEmpty {
            LoopingPhase(isRunning: true, animation: ResoniqMotion.buzz) { phase, isActive in
                ZStack {
                    ForEach(patches.indices, id: \.self) { index in
                        DeviationBandShape(widths: drawnWidths, range: patches[index])
                            .fill(ResoniqColor.signal)
                    }
                }
                .offset(x: isActive ? (phase ? ResoniqMotion.buzzDistance : -ResoniqMotion.buzzDistance) : 0)
            }
        }
    }

    @ViewBuilder
    private func sweepLine(height: CGFloat) -> some View {
        switch status {
        case .drawing, .paused:
            let isDrawing = if case .drawing = status { true } else { false }
            LoopingPhase(isRunning: isDrawing, animation: ResoniqMotion.scan) { phase, isActive in
                Rectangle()
                    .fill(ResoniqColor.signal)
                    .frame(height: Metrics.sweepThickness)
                    .frame(maxWidth: .infinity)
                    .offset(y: height * (0.5 - revealed) + (isActive ? (phase ? ResoniqMotion.scanDistance : -ResoniqMotion.scanDistance) : 0))
            }
        case .notHeard, .finished:
            EmptyView()
        }
    }

    // MARK: Accessibility

    private var defaultLabel: String {
        func spoken(_ fraction: Double) -> String {
            FrequencyRuler.spokenFrequency(FrequencyRuler.frequency(forFraction: fraction))
        }
        switch status {
        case .notHeard:
            return "Speaker portrait, not heard yet."
        case .drawing:
            return "Speaker portrait being drawn from the lowest notes upward, at \(spoken(revealed))."
        case .paused:
            return "Speaker portrait, paused at \(spoken(revealed))."
        case .finished:
            guard !deviations.isEmpty else { return "Speaker portrait, even from the lowest notes to the highest." }
            let parts = deviations.map { "between \(spoken($0.lowerBound)) and \(spoken($0.upperBound))" }
            return "Speaker portrait with a rough patch \(parts.joined(separator: ", and "))."
        }
    }

    private enum Metrics {
        static let notHeardStroke: CGFloat = 2.5
        static let notHeardDash: [CGFloat] = [4, 9]
        static let progressStroke: CGFloat = 2
        static let progressDash: [CGFloat] = [3, 7]
        static let sweepThickness: CGFloat = 2.5
        static let pulseLow: Double = 0.55
        /// V3Diagnose breathes in 2.6 s, so 1.3 s each way.
        static let notHeardPulse = Animation.easeInOut(duration: 1.3).repeatForever(autoreverses: true)
    }
}

#Preview("States") {
    HStack(alignment: .top, spacing: ResoniqSpace.s3) {
        ForEach(0..<5) { index in
            HStack(spacing: ResoniqSpace.s1) {
                if index == 0 { FrequencyRuler(.beside) }
                SpeakerPortrait(
                    state: [
                        .notHeard, .drawing(progress: 0.57), .paused(progress: 0.57), .finished, .finished,
                    ][index],
                    deviations: index == 4 ? [0.19...0.26] : []
                )
                .frame(width: 60, height: 300)
            }
        }
    }
    .padding(ResoniqSpace.s4)
    .background(ResoniqColor.panel)
}
