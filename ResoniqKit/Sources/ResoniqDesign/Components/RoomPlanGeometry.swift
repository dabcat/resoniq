import CoreGraphics
import Foundation

// The numbers behind the room plan, kept apart from drawing so they can be tested on the Mac. Everything here
// is safe for empty, degenerate and non-finite input: it returns less, never a NaN.

// MARK: - Fit

/// The map between metres and points: one scale for both axes, so the room keeps its shape.
struct PlanFit: Equatable {
    /// Points per metre.
    var scale: CGFloat
    /// The metre coordinates that sit at `origin`.
    var minimum: CGPoint
    /// Where `minimum` is in the view.
    var origin: CGPoint

    static let identity = PlanFit(scale: 1, minimum: .zero, origin: .zero)

    func point(_ metres: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (metres.x - minimum.x) * scale, y: origin.y + (metres.y - minimum.y) * scale)
    }

    func metres(_ point: CGPoint) -> CGPoint {
        guard scale > 0 else { return minimum }
        return CGPoint(x: minimum.x + (point.x - origin.x) / scale, y: minimum.y + (point.y - origin.y) / scale)
    }

    func length(_ metres: CGFloat) -> CGFloat { metres * scale }

    /// Fits `bounds` (metres) into `size`, centred, leaving `padding` free on every side. No bounds, or a size
    /// that cannot hold the padding, still gives a usable fit.
    static func fit(bounds: CGRect?, in size: CGSize, padding: CGFloat) -> PlanFit {
        guard var box = bounds, box.origin.x.isFinite, box.origin.y.isFinite, box.width.isFinite, box.height.isFinite else {
            let width = size.width.isFinite ? max(size.width, 0) : 0
            let height = size.height.isFinite ? max(size.height, 0) : 0
            return PlanFit(scale: 1, minimum: .zero, origin: CGPoint(x: width / 2, y: height / 2))
        }
        // A room of one wall, or of one point, is still a room of at least a metre.
        if box.width < RoomPlanGeometry.minimumExtent {
            box = box.insetBy(dx: (box.width - RoomPlanGeometry.minimumExtent) / 2, dy: 0)
        }
        if box.height < RoomPlanGeometry.minimumExtent {
            box = box.insetBy(dx: 0, dy: (box.height - RoomPlanGeometry.minimumExtent) / 2)
        }
        let pad = padding.isFinite ? max(padding, 0) : 0
        let width = size.width.isFinite ? max(size.width, 0) : 0
        let height = size.height.isFinite ? max(size.height, 0) : 0
        let availableWidth = max(width - 2 * pad, 1)
        let availableHeight = max(height - 2 * pad, 1)
        let scale = min(availableWidth / box.width, availableHeight / box.height)
        let drawnWidth = box.width * scale
        let drawnHeight = box.height * scale
        return PlanFit(
            scale: scale,
            minimum: box.origin,
            origin: CGPoint(x: (width - drawnWidth) / 2, y: (height - drawnHeight) / 2)
        )
    }
}

// MARK: - Geometry

enum RoomPlanGeometry {
    /// The smallest extent a plan is fitted to, in metres.
    static let minimumExtent: CGFloat = 1

    static func isFinite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }

    static func isFinite(_ segment: RoomPlanContent.Segment) -> Bool { isFinite(segment.a) && isFinite(segment.b) }

    /// The box around everything the plan shows, in metres; nil when there is nothing finite.
    static func bounds(of content: RoomPlanContent) -> CGRect? {
        var points: [CGPoint] = []
        for wall in content.walls where isFinite(wall) { points += [wall.a, wall.b] }
        for window in content.windows where isFinite(window) { points += [window.a, window.b] }
        for door in content.doors where isFinite(door.leaf) { points += [door.leaf.a, door.leaf.b, doorOpenTip(door)] }
        for item in content.furniture { points += orientedCorners(centre: item.centre, size: item.size, angle: item.angle) }
        for speaker in content.speakers { points += orientedCorners(centre: speaker.position, size: speaker.size, angle: speaker.facing) }
        for seat in content.seats { points.append(seat.position) }
        points += content.measuredSpots
        for area in content.problemAreas { points += polygon(of: area.shape) }
        for suggestion in content.suggestions { points.append(suggestion.target) }
        let finite = points.filter(isFinite)
        guard let first = finite.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in finite {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Angles and shapes

    /// An angle in degrees brought to -180...180; anything not finite is 0.
    static func normalised(degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }

    /// The unit vector of a facing: 0 is up the screen, 90 is to the right.
    static func forward(facing degrees: Double) -> CGVector {
        let radians = (degrees.isFinite ? degrees : 0) * .pi / 180
        return CGVector(dx: CGFloat(sin(radians)), dy: CGFloat(-cos(radians)))
    }

    /// The facing that points from `centre` to `point`; nil when they are the same point.
    static func facing(from centre: CGPoint, to point: CGPoint) -> Double? {
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        guard dx.isFinite, dy.isFinite, hypot(dx, dy) > 1e-9 else { return nil }
        return Double(atan2(dx, -dy)) * 180 / .pi
    }

    /// The four corners of a rectangle turned by `angle` about its centre.
    static func orientedCorners(centre: CGPoint, size: CGSize, angle: Double) -> [CGPoint] {
        let halfWidth = size.width.isFinite ? abs(size.width) / 2 : 0
        let halfHeight = size.height.isFinite ? abs(size.height) / 2 : 0
        let across = forward(facing: angle + 90)
        let along = forward(facing: angle)
        return [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { sx, sy in
            CGPoint(
                x: centre.x + across.dx * halfWidth * CGFloat(sx) + along.dx * halfHeight * CGFloat(sy),
                y: centre.y + across.dy * halfWidth * CGFloat(sx) + along.dy * halfHeight * CGFloat(sy)
            )
        }
    }

    /// The outline of an ellipse as a polygon.
    static func ellipsePolygon(centre: CGPoint, radii: CGSize, steps: Int = 48) -> [CGPoint] {
        guard steps >= 3, radii.width.isFinite, radii.height.isFinite else { return [] }
        return (0..<steps).map { step in
            let angle = 2 * Double.pi * Double(step) / Double(steps)
            return CGPoint(x: centre.x + abs(radii.width) * CGFloat(cos(angle)), y: centre.y + abs(radii.height) * CGFloat(sin(angle)))
        }
    }

    static func polygon(of shape: RoomPlanContent.ProblemArea.Shape) -> [CGPoint] {
        switch shape {
        case .polygon(let points): points
        case .ellipse(let centre, let radii): ellipsePolygon(centre: centre, radii: radii)
        }
    }

    /// Where the free end of an open door is: the closed tip turned a quarter about the hinge.
    static func doorOpenTip(_ door: RoomPlanContent.Door) -> CGPoint {
        let hinge = door.leaf.a
        let dx = door.leaf.b.x - hinge.x
        let dy = door.leaf.b.y - hinge.y
        switch door.swing {
        case .clockwise: return CGPoint(x: hinge.x - dy, y: hinge.y + dx)
        case .counterclockwise: return CGPoint(x: hinge.x + dy, y: hinge.y - dx)
        }
    }

    /// Points along a circular arc about `centre`, from one facing to another by the short way round.
    static func arc(centre: CGPoint, radius: CGFloat, from start: Double, to end: Double, steps: Int = 24) -> [CGPoint] {
        guard radius.isFinite, radius > 0, steps >= 1, isFinite(centre) else { return [] }
        let sweep = normalised(degrees: end - start)
        return (0...steps).map { step in
            let direction = forward(facing: start + sweep * Double(step) / Double(steps))
            return CGPoint(x: centre.x + direction.dx * radius, y: centre.y + direction.dy * radius)
        }
    }

    // MARK: Dimension lines

    /// The two short ticks across the ends of a dimension line; none for a line of no length.
    static func dimensionTicks(from a: CGPoint, to b: CGPoint, length: CGFloat) -> [(CGPoint, CGPoint)] {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let distance = hypot(dx, dy)
        guard dx.isFinite, dy.isFinite, distance > 1e-9, length.isFinite else { return [] }
        let nx = -dy / distance * length / 2
        let ny = dx / distance * length / 2
        return [a, b].map { end in (CGPoint(x: end.x - nx, y: end.y - ny), CGPoint(x: end.x + nx, y: end.y + ny)) }
    }

    /// A line moved sideways by `offset` (to the right of a to b as seen on screen).
    static func offsetLine(from a: CGPoint, to b: CGPoint, by offset: CGFloat) -> (CGPoint, CGPoint) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let distance = hypot(dx, dy)
        guard distance > 1e-9, distance.isFinite, offset.isFinite else { return (a, b) }
        let nx = -dy / distance * offset
        let ny = dx / distance * offset
        return (CGPoint(x: a.x + nx, y: a.y + ny), CGPoint(x: b.x + nx, y: b.y + ny))
    }

    // MARK: Moving

    enum Move: Sendable, CaseIterable {
        case left, right, forward, back
    }

    /// The offset of one step in a direction, as the item sees it: forward is where it faces.
    static func moveVector(_ move: Move, facing: Double, step: Double) -> CGVector {
        let ahead = forward(facing: facing)
        let right = forward(facing: facing + 90)
        let distance = step.isFinite ? CGFloat(step) : 0
        switch move {
        case .forward: return CGVector(dx: ahead.dx * distance, dy: ahead.dy * distance)
        case .back: return CGVector(dx: -ahead.dx * distance, dy: -ahead.dy * distance)
        case .right: return CGVector(dx: right.dx * distance, dy: right.dy * distance)
        case .left: return CGVector(dx: -right.dx * distance, dy: -right.dy * distance)
        }
    }

    // MARK: Hit testing

    struct Target: Equatable {
        enum Kind: Equatable {
            case item
            case rotateHandle
        }

        var id: String
        var kind: Kind
        /// In points.
        var centre: CGPoint
        /// Half the drawn side, in points.
        var halfSide: CGFloat
    }

    /// The target under a touch. Every target answers within at least `minimumSide` points square whatever its
    /// drawn size; a handle wins over an item, and otherwise the nearest centre does.
    static func hit(at point: CGPoint, targets: [Target], minimumSide: CGFloat = ResoniqSize.touchMin) -> Target? {
        guard isFinite(point) else { return nil }
        var best: (target: Target, rank: Int, distance: CGFloat)?
        for target in targets where isFinite(target.centre) {
            let reach = max(target.halfSide.isFinite ? target.halfSide : 0, minimumSide / 2)
            let dx = abs(point.x - target.centre.x)
            let dy = abs(point.y - target.centre.y)
            guard dx <= reach, dy <= reach else { continue }
            let rank = target.kind == .rotateHandle ? 1 : 0
            let distance = hypot(dx, dy)
            if let current = best, (current.rank, -current.distance) >= (rank, -distance) { continue }
            best = (target, rank, distance)
        }
        return best?.target
    }

    // MARK: Hatching

    /// Parallel lines at `angle` degrees from horizontal, `spacing` apart, clipped to a polygon (any polygon,
    /// concave included; the even-odd rule decides what is inside).
    static func hatchLines(in polygon: [CGPoint], spacing: CGFloat, angle: Double) -> [(CGPoint, CGPoint)] {
        guard polygon.count >= 3, spacing.isFinite, spacing > 0, polygon.allSatisfy(isFinite) else { return [] }
        let radians = (angle.isFinite ? angle : 0) * .pi / 180
        let cosA = CGFloat(cos(radians)), sinA = CGFloat(sin(radians))
        // Into a frame where the hatch lines are horizontal.
        let local = polygon.map { CGPoint(x: $0.x * cosA + $0.y * sinA, y: -$0.x * sinA + $0.y * cosA) }
        guard let minY = local.map(\.y).min(), let maxY = local.map(\.y).max() else { return [] }
        let first = Int((minY / spacing).rounded(.up))
        let last = Int((maxY / spacing).rounded(.down))
        guard last >= first, last - first <= Limits.hatchLines else { return [] }
        var lines: [(CGPoint, CGPoint)] = []
        for index in first...last {
            let y = CGFloat(index) * spacing
            var crossings: [CGFloat] = []
            for edge in 0..<local.count {
                let p = local[edge], q = local[(edge + 1) % local.count]
                // Half-open on the upper end, so a vertex on the line is counted once.
                if (p.y <= y && q.y > y) || (q.y <= y && p.y > y) {
                    crossings.append(p.x + (y - p.y) / (q.y - p.y) * (q.x - p.x))
                }
            }
            crossings.sort()
            var pair = 0
            while pair + 1 < crossings.count {
                let from = CGPoint(x: crossings[pair] * cosA - y * sinA, y: crossings[pair] * sinA + y * cosA)
                let to = CGPoint(x: crossings[pair + 1] * cosA - y * sinA, y: crossings[pair + 1] * sinA + y * cosA)
                lines.append((from, to))
                pair += 2
            }
        }
        return lines
    }

    private enum Limits {
        static let hatchLines = 4000
    }

    // MARK: Labels

    enum LabelSide: Sendable, CaseIterable {
        case right, left, above, below, centre
        case aboveRight, aboveLeft, belowRight, belowLeft
    }

    struct LabelRequest {
        /// The label's size in points.
        var size: CGSize
        /// The point the label belongs to.
        var anchor: CGPoint
        /// Where to try, in order of preference.
        var sides: [LabelSide]
        /// Distance from the anchor to the label's near edge.
        var offset: CGFloat
        /// The index in the obstacle rectangles of the thing the label names, which it may touch.
        var ownObstacle: Int?
    }

    /// Where a label went. `isMoved` is true when none of its own sides was clear and it was moved further away: the
    /// caller then draws a leader line from the anchor to the label.
    struct Placement: Equatable {
        var rect: CGRect
        var isMoved: Bool
    }

    /// How much further from the anchor a label that cannot stay beside it is tried.
    static let leaderDistances: [CGFloat] = [14, 28, 44]

    /// Places each label at the first of its sides where it stays inside `frame` and clear of the earlier labels,
    /// the obstacle rectangles and the obstacle segments (walls); if no side is clear, the least bad one.
    /// Labels are placed in order, so the first has the pick.
    static func place(
        _ requests: [LabelRequest], in frame: CGRect, obstacles: [CGRect] = [], segments: [(CGPoint, CGPoint)] = []
    ) -> [CGRect] {
        placeLabels(requests, in: frame, obstacles: obstacles, segments: segments).map(\.rect)
    }

    /// `place`, and when a label's own sides all collide with something, the same eight directions further out
    /// (`leaderDistances`): the clearest spot wins, nearer ones preferred, and the label is marked as moved.
    static func placeLabels(
        _ requests: [LabelRequest], in frame: CGRect, obstacles: [CGRect] = [], segments: [(CGPoint, CGPoint)] = []
    ) -> [Placement] {
        /// What a candidate collides with: a label (100), an obstacle or a segment (10 each).
        func collisions(_ rect: CGRect, placed: [Placement], own: Int?) -> CGFloat {
            var cost = CGFloat(placed.filter { $0.rect.intersects(rect) }.count) * 100
            for (index, obstacle) in obstacles.enumerated() where index != own && obstacle.intersects(rect) { cost += 10 }
            cost += CGFloat(segments.filter { segmentIntersects($0, rect) }.count) * 10
            return cost
        }
        var placed: [Placement] = []
        for request in requests {
            let size = CGSize(
                width: request.size.width.isFinite ? max(request.size.width, 0) : 0,
                height: request.size.height.isFinite ? max(request.size.height, 0) : 0
            )
            let anchor = isFinite(request.anchor) ? request.anchor : CGPoint(x: frame.midX, y: frame.midY)
            let sides = request.sides.isEmpty ? [.centre] : request.sides
            var best: (rect: CGRect, cost: CGFloat, moved: Bool)?
            for (order, side) in sides.enumerated() {
                let raw = candidate(side, size: size, anchor: anchor, offset: request.offset)
                let rect = clamp(raw, into: frame)
                let cost = hypot(rect.minX - raw.minX, rect.minY - raw.minY) * 0.1 + CGFloat(order) * 0.01
                    + collisions(rect, placed: placed, own: request.ownObstacle)
                if best == nil || cost < best!.cost { best = (rect, cost, false) }
            }
            // Nothing beside the anchor is clear: look further out, in every direction.
            if let current = best, current.cost >= 10, !sides.contains(.centre) {
                for extra in leaderDistances {
                    for side in LabelSide.allCases where side != .centre {
                        let raw = candidate(side, size: size, anchor: anchor, offset: request.offset + extra)
                        let rect = clamp(raw, into: frame)
                        let cost = hypot(rect.minX - raw.minX, rect.minY - raw.minY) * 0.1 + extra * 0.05 + 1
                            + collisions(rect, placed: placed, own: request.ownObstacle)
                        if cost < best!.cost { best = (rect, cost, true) }
                    }
                }
            }
            placed.append(Placement(rect: best?.rect ?? .zero, isMoved: best?.moved ?? false))
        }
        return placed
    }

    private static func candidate(_ side: LabelSide, size: CGSize, anchor: CGPoint, offset: CGFloat) -> CGRect {
        let diagonal = offset / 2.0.squareRoot()
        switch side {
        case .right: return CGRect(x: anchor.x + offset, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        case .left: return CGRect(x: anchor.x - offset - size.width, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        case .above: return CGRect(x: anchor.x - size.width / 2, y: anchor.y - offset - size.height, width: size.width, height: size.height)
        case .below: return CGRect(x: anchor.x - size.width / 2, y: anchor.y + offset, width: size.width, height: size.height)
        case .centre: return CGRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        case .aboveRight: return CGRect(x: anchor.x + diagonal, y: anchor.y - diagonal - size.height, width: size.width, height: size.height)
        case .aboveLeft: return CGRect(x: anchor.x - diagonal - size.width, y: anchor.y - diagonal - size.height, width: size.width, height: size.height)
        case .belowRight: return CGRect(x: anchor.x + diagonal, y: anchor.y + diagonal, width: size.width, height: size.height)
        case .belowLeft: return CGRect(x: anchor.x - diagonal - size.width, y: anchor.y + diagonal, width: size.width, height: size.height)
        }
    }

    /// Moves `rect` into `frame`; a rect larger than the frame is pinned to its top left.
    static func clamp(_ rect: CGRect, into frame: CGRect) -> CGRect {
        var result = rect
        result.origin.x = max(frame.minX, min(rect.minX, frame.maxX - rect.width))
        result.origin.y = max(frame.minY, min(rect.minY, frame.maxY - rect.height))
        return result
    }

    /// Whether a segment crosses or lies inside a rectangle (Liang-Barsky).
    static func segmentIntersects(_ segment: (CGPoint, CGPoint), _ rect: CGRect) -> Bool {
        let (p, q) = segment
        guard isFinite(p), isFinite(q) else { return false }
        let dx = q.x - p.x, dy = q.y - p.y
        var t0: CGFloat = 0, t1: CGFloat = 1
        for (pValue, qValue) in [(-dx, p.x - rect.minX), (dx, rect.maxX - p.x), (-dy, p.y - rect.minY), (dy, rect.maxY - p.y)] {
            if pValue == 0 {
                if qValue < 0 { return false }
            } else {
                let ratio = qValue / pValue
                if pValue < 0 { t0 = max(t0, ratio) } else { t1 = min(t1, ratio) }
                if t0 > t1 { return false }
            }
        }
        return true
    }
}

// MARK: - Marching outline

/// The dashed target outline that crawls while the app guides ("Marching outline", a 1 s loop).
enum MarchingOutline {
    /// loop.marchingOutline.
    static let period: TimeInterval = 1
    /// The dashes travel two pattern lengths per period, as in the mockup (a dash pattern of 11 moves 22).
    static let patternsPerPeriod: CGFloat = 2

    /// The `dashPhase` of a stroke at `time` seconds: it falls from 0 to minus two pattern lengths and starts
    /// again, so the dashes move along the path.
    static func dashPhase(at time: TimeInterval, pattern: [CGFloat]) -> CGFloat {
        let length = pattern.filter { $0.isFinite && $0 > 0 }.reduce(0, +)
        guard time.isFinite, length > 0 else { return 0 }
        var fraction = time.truncatingRemainder(dividingBy: period) / period
        if fraction < 0 { fraction += 1 }
        let phase = -CGFloat(fraction) * patternsPerPeriod * length
        return phase == 0 ? 0 : phase
    }
}
