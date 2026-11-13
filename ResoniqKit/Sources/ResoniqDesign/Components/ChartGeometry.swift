import SwiftUI

/// The numbers behind the measure charts, kept apart from drawing so they can be tested on the Mac.
///
/// A trace is an array of levels in decibels relative to the curve's middle, spread evenly over the width. Because
/// the samples are log-spaced in frequency, an even spread over the width is the log-frequency axis; positions in
/// hertz go through `FrequencyRuler.fraction(forFrequency:)`, the one definition of that mapping.
enum ChartGeometry {
    /// Vertical room kept free at the top and bottom of a plot so a stroke at the limit is not cut.
    static let plotInset: CGFloat = 4

    /// A level made safe: NaN is the middle, and infinities are held at the limits by `clampedLevel`.
    static func clampedLevel(_ level: Double, range: Double) -> Double {
        let limit = safeRange(range)
        guard !level.isNaN else { return 0 }
        return min(max(level, -limit), limit)
    }

    static func safeRange(_ range: Double) -> Double {
        range.isFinite && range > 0 ? range : 1
    }

    /// Where a level sits from the top of the plot: 0 at `+range`, 0.5 at the middle, 1 at `-range`.
    static func yFraction(level: Double, range: Double) -> Double {
        let limit = safeRange(range)
        return (limit - clampedLevel(level, range: limit)) / (2 * limit)
    }

    /// The y coordinate of a level in a plot of `height`, inside the vertical inset.
    static func y(level: Double, range: Double, in rect: CGRect, inset: CGFloat = plotInset) -> CGFloat {
        let usable = max(rect.height - 2 * inset, 0)
        return rect.minY + inset + CGFloat(yFraction(level: level, range: range)) * usable
    }

    /// The x coordinate of a fraction of the width (0 is 20 Hz, 1 is 20 kHz). Held to the plot.
    static func x(fraction: Double, in rect: CGRect) -> CGFloat {
        rect.minX + rect.width * CGFloat(fraction.isNaN ? 0 : min(max(fraction, 0), 1))
    }

    /// The points of a trace. No levels give no points; one level gives a line across the plot.
    static func points(levels: [Double], range: Double, in rect: CGRect, inset: CGFloat = plotInset) -> [CGPoint] {
        guard !levels.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        if levels.count == 1 {
            let y = y(level: levels[0], range: range, in: rect, inset: inset)
            return [CGPoint(x: rect.minX, y: y), CGPoint(x: rect.maxX, y: y)]
        }
        let last = Double(levels.count - 1)
        return levels.enumerated().map { index, level in
            CGPoint(
                x: x(fraction: Double(index) / last, in: rect),
                y: y(level: level, range: range, in: rect, inset: inset)
            )
        }
    }

    /// A smooth curve through the points: monotone between samples (it never overshoots a peak or dips below a
    /// trough), with the slopes `PortraitGeometry` uses for the speaker portrait.
    static func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        let slopes = PortraitGeometry.slopes(points.map { Double($0.y) })
        for index in 0..<points.count - 1 {
            let from = points[index]
            let to = points[index + 1]
            let third = (to.x - from.x) / 3
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + third, y: from.y + CGFloat(slopes[index]) / 3),
                control2: CGPoint(x: to.x - third, y: to.y - CGFloat(slopes[index + 1]) / 3)
            )
        }
        return path
    }

    // MARK: In band and out of band

    /// A stretch of a trace, as fractions of the width, that is wholly inside or wholly outside the even band.
    struct Segment: Equatable {
        var start: Double
        var end: Double
        var isOutside: Bool
    }

    /// The trace cut where it crosses `+evenBand` and `-evenBand` (found on the straight line between two
    /// samples). The segments run from 0 to 1 without a gap, and neighbours differ in `isOutside`.
    static func segments(levels: [Double], evenBand: Double) -> [Segment] {
        let band = evenBand.isFinite ? abs(evenBand) : 0
        let limit = 1e6
        let clean = levels.map { $0.isNaN ? 0 : min(max($0, -limit), limit) }
        guard !clean.isEmpty else { return [] }
        guard clean.count > 1 else { return [Segment(start: 0, end: 1, isOutside: abs(clean[0]) > band)] }

        let last = Double(clean.count - 1)
        var result: [Segment] = []
        func append(_ start: Double, _ end: Double, outside: Bool) {
            guard end > start else { return }
            if let tail = result.last, tail.isOutside == outside {
                result[result.count - 1].end = end
            } else {
                result.append(Segment(start: start, end: end, isOutside: outside))
            }
        }

        for index in 0..<clean.count - 1 {
            let a = clean[index]
            let b = clean[index + 1]
            var cuts: [Double] = [0, 1]
            for edge in [band, -band] where (a - edge) * (b - edge) < 0 {
                cuts.append((edge - a) / (b - a))
            }
            cuts.sort()
            for pair in zip(cuts, cuts.dropFirst()) {
                let middle = a + (b - a) * (pair.0 + pair.1) / 2
                append((Double(index) + pair.0) / last, (Double(index) + pair.1) / last, outside: abs(middle) > band)
            }
        }
        return result
    }

    // MARK: Labels

    struct LabelRequest {
        var anchor: CGPoint
        var size: CGSize
        /// A peak puts its label above the dot first, a dip below it.
        var prefersAbove: Bool
    }

    /// Distance between a dot and the label beside it.
    static let labelGap: CGFloat = 8

    /// Where each label goes: beside its dot, inside the plot, clear of the trace and of the other labels. Each
    /// label tries a short list of positions in order and takes the first that is clear; if none is, the first,
    /// held inside the plot.
    static func placeLabels(_ requests: [LabelRequest], in plot: CGRect, avoiding trace: [CGPoint]) -> [CGRect] {
        var placed: [CGRect] = []
        for request in requests {
            let candidates = candidates(for: request, in: plot)
            let clear = candidates.first { candidate in
                !placed.contains { $0.insetBy(dx: -2, dy: -1).intersects(candidate) }
                    && !touches(trace, candidate.insetBy(dx: -2, dy: -2))
            }
            placed.append(clear ?? candidates[0])
        }
        return placed
    }

    private static func candidates(for request: LabelRequest, in plot: CGRect) -> [CGRect] {
        let size = request.size
        let anchor = request.anchor
        let gap = labelGap
        enum Horizontal { case right, left, centred }
        enum Vertical { case level, outer, inner }
        let order: [(Horizontal, Vertical)] = [
            (.right, .outer), (.left, .outer), (.right, .level), (.left, .level),
            (.centred, .outer), (.right, .inner), (.left, .inner), (.centred, .inner),
        ]
        return order.map { horizontal, vertical in
            let x: CGFloat = switch horizontal {
            case .right: anchor.x + gap
            case .left: anchor.x - gap - size.width
            case .centred: anchor.x - size.width / 2
            }
            let above = request.prefersAbove
            let y: CGFloat = switch vertical {
            case .level: anchor.y - size.height / 2
            case .outer: above ? anchor.y - gap - size.height : anchor.y + gap
            case .inner: above ? anchor.y + gap : anchor.y - gap - size.height
            }
            return clamped(CGRect(origin: CGPoint(x: x, y: y), size: size), in: plot)
        }
    }

    /// The rectangle moved, never resized, to lie inside `plot` (against its leading and top edge when too big).
    static func clamped(_ rect: CGRect, in plot: CGRect) -> CGRect {
        let x = min(max(rect.minX, plot.minX), max(plot.maxX - rect.width, plot.minX))
        let y = min(max(rect.minY, plot.minY), max(plot.maxY - rect.height, plot.minY))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// Whether the line through `points` passes through `rect`, checked along each step.
    private static func touches(_ points: [CGPoint], _ rect: CGRect) -> Bool {
        guard var previous = points.first else { return false }
        if rect.contains(previous) { return true }
        for point in points.dropFirst() {
            if rect.minX > max(previous.x, point.x) || rect.maxX < min(previous.x, point.x) {
                previous = point
                continue
            }
            let steps = max(1, Int((hypot(point.x - previous.x, point.y - previous.y) / 3).rounded(.up)))
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let sample = CGPoint(x: previous.x + (point.x - previous.x) * t, y: previous.y + (point.y - previous.y) * t)
                if rect.contains(sample) { return true }
            }
            previous = point
        }
        return false
    }

    // MARK: Text

    /// A level on a decibel grid: "+12", "0", "−6" (a true minus sign).
    static func gridLabel(_ level: Double) -> String {
        let value = Int(level.isFinite ? level.rounded() : 0)
        if value > 0 { return "+\(value)" }
        if value < 0 { return "\u{2212}\(-value)" }
        return "0"
    }
}
