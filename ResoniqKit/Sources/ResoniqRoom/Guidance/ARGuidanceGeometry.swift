import Foundation

/// A straight piece of an outline on the floor, plan metres.
public struct PlanSegment: Sendable, Equatable {
    public var start: PlanPoint
    public var end: PlanPoint

    public init(start: PlanPoint, end: PlanPoint) {
        self.start = start
        self.end = end
    }

    public var length: Double { start.distance(to: end) }
    public var midpoint: PlanPoint { (start + end) * 0.5 }
}

/// What the AR guide draws on the floor, as plan geometry: footprints, the target's dashed outline and the turn
/// arc. The app turns these into RealityKit entities (or, in the simulator, 2D paths); nothing here knows either.
public enum ARGuidanceGeometry {
    /// The target outline's dash and gap, metres: the mockup's 7:4 at a size that reads from standing height.
    public static let dashLength = 0.04
    public static let gapLength = 0.025
    /// The marching outline's loop, seconds (`motion.loop.marchingOutline` in design/tokens.json).
    public static let marchPeriod = 1.0
    /// How far the dashes move in one loop, metres: two dash periods, as V3OAR's `march` keyframes move 22 px
    /// for an 11 px dash pattern.
    public static let marchDistance = 2 * (dashLength + gapLength)
    /// The turn arc's radius beyond the front edge, metres.
    public static let arcClearance = 0.12
    /// The arc's largest step between points, radians (3°).
    public static let arcStep = 3 * Double.pi / 180

    /// A speaker's footprint at a pose.
    public static func footprint(of pose: PlanPose, size: FootprintSize) -> OrientedRect {
        OrientedRect(centre: pose.position, width: size.width, depth: size.depth, heading: pose.facing)
    }

    /// The middle of the footprint's front edge: where the person puts the reticle to mark the speaker.
    public static func frontEdgeCentre(of pose: PlanPose, size: FootprintSize) -> PlanPoint {
        pose.position + PlanPoint(angle: pose.facing) * (size.depth / 2)
    }

    /// The footprint's centre for a front edge whose middle is at `frontEdge`.
    public static func centre(behindFrontEdge frontEdge: PlanPoint, facing: Double, size: FootprintSize) -> PlanPoint {
        frontEdge - PlanPoint(angle: facing) * (size.depth / 2)
    }

    /// The dashes of a closed outline, `phase` metres along it from the first corner (a march moves `phase` on).
    /// A dash that reaches a corner is split there, so every piece is straight.
    public static func dashes(around corners: [PlanPoint], dash: Double = dashLength, gap: Double = gapLength,
                              phase: Double = 0) -> [PlanSegment] {
        guard corners.count >= 2, dash > 0, gap >= 0 else { return [] }
        let period = dash + gap
        let edges = corners.indices.map { PlanSegment(start: corners[$0], end: corners[($0 + 1) % corners.count]) }
        let perimeter = edges.reduce(0) { $0 + $1.length }
        guard perimeter > 0 else { return [] }
        let offset = phase.truncatingRemainder(dividingBy: period)
        // Dash starts along the perimeter, from one period before 0 so a dash crossing the start is not lost.
        var intervals: [(Double, Double)] = []
        var s = offset - period
        while s < perimeter {
            let a = max(0, s), b = min(perimeter, s + dash)
            if b > a { intervals.append((a, b)) }
            s += period
        }
        var pieces: [PlanSegment] = []
        var edgeStart = 0.0
        for edge in edges {
            let length = edge.length
            guard length > 0 else { continue }
            let direction = (edge.end - edge.start) * (1 / length)
            for (a, b) in intervals {
                let from = max(a, edgeStart), to = min(b, edgeStart + length)
                guard to > from else { continue }
                pieces.append(PlanSegment(start: edge.start + direction * (from - edgeStart),
                                          end: edge.start + direction * (to - edgeStart)))
            }
            edgeStart += length
        }
        return pieces
    }

    /// The march's offset at `time` seconds: `marchDistance` per `marchPeriod`, looping; 0 under Reduce Motion.
    public static func marchPhase(time: TimeInterval, reduceMotion: Bool) -> Double {
        guard !reduceMotion, time.isFinite else { return 0 }
        let loop = (time / marchPeriod).truncatingRemainder(dividingBy: 1)
        return (loop < 0 ? loop + 1 : loop) * marchDistance
    }

    /// Points on a circle about `centre` from plan angle `from` to `to` the short way round, at most `arcStep`
    /// apart, both ends included.
    public static func turnArc(around centre: PlanPoint, radius: Double, from: Double, to: Double) -> [PlanPoint] {
        let sweep = PlanAngle.difference(from: from, to: to)
        let steps = max(2, Int((abs(sweep) / arcStep).rounded(.up)))
        return (0...steps).map { centre + PlanPoint(angle: from + sweep * Double($0) / Double(steps)) * radius }
    }

    /// The arc the turn step draws in front of the target: from the speaker's current facing to the target's,
    /// `arcClearance` beyond the front edge; with the point the label sits at (the arc's end).
    public static func turnArc(speaker: PlanPose, target: PlanPose, size: FootprintSize) -> (points: [PlanPoint], label: PlanPoint) {
        let radius = size.depth / 2 + arcClearance
        let points = turnArc(around: target.position, radius: radius, from: speaker.facing, to: target.facing)
        return (points, target.position + PlanPoint(angle: target.facing) * (radius + arcClearance))
    }
}
