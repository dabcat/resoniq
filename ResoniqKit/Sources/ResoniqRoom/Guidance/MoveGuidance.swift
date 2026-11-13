import Foundation

/// Which way to go, as the person holding the phone sees it.
public enum ViewerDirection: String, Sendable, Codable, CaseIterable {
    case towardYou
    case awayFromYou
    case left
    case right
}

/// The phone's place and the direction it looks, flattened onto the plan.
public struct Viewer: Sendable, Codable, Hashable {
    public var position: PlanPoint
    /// The plan angle the camera looks along, projected onto the floor.
    public var heading: Double

    public init(position: PlanPoint, heading: Double) {
        self.position = position
        self.heading = heading
    }
}

/// How far a move has come, for the AR readout.
public struct MoveProgress: Sendable, Equatable {
    /// Metres from the speaker's current position to the target.
    public var distanceToGo: Double
    /// The dominant way to go, seen by the viewer; nil once in position.
    public var direction: ViewerDirection?
    /// The way to go relative to where the viewer looks, radians: 0 straight ahead, positive to the right.
    public var bearing: Double
    /// The signed plan-angle turn still to make, radians.
    public var turnRemaining: Double
    /// The whole slide, start to target, metres.
    public var totalDistance: Double
    /// 0 at the start, 1 at the target; never outside 0…1.
    public var fractionDone: Double
    /// Within `MoveGuidance.positionTolerance` of the target.
    public var isInPosition: Bool
    /// In position and within `MoveGuidance.angleTolerance` of the target facing.
    public var hasArrived: Bool
}

/// Counting a move down in AR (phase 5): what is left and how fast the taps come.
public enum MoveGuidance {
    /// Where a move starts and ends.
    public struct Target: Sendable, Codable, Hashable {
        public var start: PlanPose
        public var end: PlanPose

        public init(start: PlanPose, end: PlanPose) {
            self.start = start
            self.end = end
        }

        public var totalDistance: Double { start.position.distance(to: end.position) }
    }

    /// Closer than this is in position, metres. A first guess: about what a re-marked footprint can be trusted to
    /// in AR, and smaller than any boundary model difference that matters.
    public static let positionTolerance = 0.03
    /// A facing within this of the target is turned enough, radians (3°). A first guess.
    public static let angleTolerance = 3 * Double.pi / 180
    /// No taps beyond this distance, metres: the readout is enough far away. A first guess.
    public static let hapticRange = 1.0
    /// The gap between taps just outside `positionTolerance`, seconds. A first guess.
    public static let fastestHapticInterval = 0.08
    /// The gap between taps at `hapticRange`, seconds. A first guess.
    public static let slowestHapticInterval = 0.8

    public static func progress(current: PlanPose, target: Target, viewer: Viewer) -> MoveProgress {
        let toGo = target.end.position - current.position
        let distance = toGo.length
        let total = target.totalDistance
        let turn = PlanAngle.difference(from: current.facing, to: target.end.facing)
        let inPosition = distance <= positionTolerance
        let look = PlanPoint(angle: viewer.heading)
        let ahead = toGo.dot(look), side = toGo.dot(look.rightHand)
        let direction: ViewerDirection? = inPosition
            ? nil
            : abs(ahead) >= abs(side) ? (ahead >= 0 ? .awayFromYou : .towardYou) : (side >= 0 ? .right : .left)
        let fraction = total > 0 ? min(1, max(0, 1 - distance / total)) : (inPosition ? 1 : 0)
        return MoveProgress(
            distanceToGo: distance, direction: direction, bearing: atan2(side, ahead), turnRemaining: turn,
            totalDistance: total, fractionDone: fraction, isInPosition: inPosition,
            hasArrived: inPosition && abs(turn) <= angleTolerance)
    }

    /// The gap between taps in the hand, seconds: shorter the closer the speaker is, linear between
    /// `fastestHapticInterval` at `positionTolerance` and `slowestHapticInterval` at `hapticRange`. Nil when in
    /// position, beyond the range, or for a distance that is not a number.
    public static func hapticInterval(distance: Double) -> TimeInterval? {
        guard distance.isFinite, distance > positionTolerance, distance <= hapticRange else { return nil }
        let t = (distance - positionTolerance) / (hapticRange - positionTolerance)
        return fastestHapticInterval + t * (slowestHapticInterval - fastestHapticInterval)
    }
}
