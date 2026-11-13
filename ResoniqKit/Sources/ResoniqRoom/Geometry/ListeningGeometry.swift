import Foundation

/// The triangle a stereo pair makes with a seat.
///
/// The thresholds are the classic placement guidance (an equilateral triangle, both speakers the same distance away,
/// each pointed at the listener), not a measurement: a result from this type is from the room's shape and says so
/// (`SuggestionBasis.roomShape`).
public struct ListeningGeometry: Sendable, Equatable {
    /// The angle the pair should subtend at the seat: 60°, an equilateral triangle. Classic guidance (e.g. ITU-R
    /// BS.775's ±30° front pair), not a measurement.
    public static let idealAngle = Double.pi / 3
    /// How far the angle may be from `idealAngle` and still count as even: ±10°. A first guess.
    public static let angleTolerance = 10 * Double.pi / 180
    /// How much closer one speaker may be than the other and still count as even, metres. 5 cm is about 0.15 ms of
    /// arrival difference, below what moves a centred image audibly. A first guess.
    public static let distanceTolerance = 0.05
    /// How far a speaker may point away from the seat and still count as toed in, ±10°. A first guess.
    public static let toeInTolerance = 10 * Double.pi / 180

    /// What is uneven about the triangle.
    public enum Issue: Sendable, Equatable, Hashable, Codable {
        case tooWide
        case tooNarrow
        /// One speaker is farther away than the other by more than `distanceTolerance`.
        case closerTo(SpeakerRole)
        /// A speaker points away from the seat by more than `toeInTolerance`.
        case notToedIn(SpeakerRole)
    }

    public let seat: PlanPoint
    public let left: PlacedSpeaker
    public let right: PlacedSpeaker

    public init(seat: PlanPoint, left: PlacedSpeaker, right: PlacedSpeaker) {
        self.seat = seat
        self.left = left
        self.right = right
    }

    /// The pair's geometry for the room's `primarySeat` and its first left and right speakers; nil without them.
    public init?(room: RoomModel) {
        guard let seat = room.primarySeat, let left = room.speaker(role: .left), let right = room.speaker(role: .right)
        else { return nil }
        self.init(seat: seat.position, left: left, right: right)
    }

    public var leftDistance: Double { seat.distance(to: left.position) }
    public var rightDistance: Double { seat.distance(to: right.position) }
    /// `leftDistance − rightDistance`: positive when the right speaker is closer.
    public var distanceDifference: Double { leftDistance - rightDistance }
    /// Centre to centre, metres.
    public var spacing: Double { left.position.distance(to: right.position) }

    /// The angle between the two speakers seen from the seat, 0…π.
    public var subtendedAngle: Double {
        let a = left.position - seat, b = right.position - seat
        return abs(atan2(a.cross(b), a.dot(b)))
    }

    /// How far a speaker points away from the seat, 0…π: 0 when it points straight at it.
    public static func toeInError(of speaker: PlacedSpeaker, toward seat: PlanPoint) -> Double {
        abs(PlanAngle.difference(from: speaker.facing, to: (seat - speaker.position).angle))
    }

    public var leftToeInError: Double { Self.toeInError(of: left, toward: seat) }
    public var rightToeInError: Double { Self.toeInError(of: right, toward: seat) }

    /// Everything outside the thresholds, in a fixed order: angle, distance, toe-in left, toe-in right.
    public var issues: [Issue] {
        var found: [Issue] = []
        if subtendedAngle > Self.idealAngle + Self.angleTolerance { found.append(.tooWide) }
        if subtendedAngle < Self.idealAngle - Self.angleTolerance { found.append(.tooNarrow) }
        if abs(distanceDifference) > Self.distanceTolerance {
            found.append(.closerTo(distanceDifference > 0 ? .right : .left))
        }
        if leftToeInError > Self.toeInTolerance { found.append(.notToedIn(.left)) }
        if rightToeInError > Self.toeInTolerance { found.append(.notToedIn(.right)) }
        return found
    }

    /// True when nothing is outside the thresholds.
    public var isEven: Bool { issues.isEmpty }

    /// How far the triangle is from even, in units of the tolerances: 0 is ideal, 1 is at the edge. The advisor
    /// uses it to penalise moves that make the triangle worse; toe-in is left out because a move ends with a turn.
    public var unevenness: Double {
        abs(subtendedAngle - Self.idealAngle) / Self.angleTolerance + abs(distanceDifference) / Self.distanceTolerance
    }
}
