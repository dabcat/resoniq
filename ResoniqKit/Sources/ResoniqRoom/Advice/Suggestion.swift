import Foundation

/// A measured problem at the seat, as the app maps it from the seat report: a plain value.
public struct AcousticProblem: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// Too loud: a boomy note.
        case peak
        /// Too quiet: a missing note.
        case dip
    }

    /// Hertz, the centre of the problem.
    public var frequency: Double
    /// How far outside the even band, decibels, as a magnitude (the kind gives the sign).
    public var deviation: Double
    public var kind: Kind

    public init(frequency: Double, deviation: Double, kind: Kind) {
        self.frequency = frequency
        self.deviation = abs(deviation)
        self.kind = kind
    }
}

/// A direction a person can follow, relative to the listener's view from the seat: the listener faces the
/// speakers, "forward" is toward the seat, "back" is away from it (toward the wall behind a front speaker), and
/// "left" and "right" are the listener's left and right. This is the one definition; `PlacementAdvisor.frame`
/// computes it.
public enum MoveDirection: String, Sendable, Codable, CaseIterable {
    case forward
    case back
    case left
    case right
}

/// A straight slide.
public struct Slide: Sendable, Codable, Hashable {
    public var direction: MoveDirection
    /// Metres.
    public var distance: Double

    public init(direction: MoveDirection, distance: Double) {
        self.direction = direction
        self.distance = distance
    }
}

/// A turn on the spot. Every turn the advisor suggests ends with the speaker pointing at the seat.
public struct Turn: Sendable, Codable, Hashable {
    /// The signed plan-angle change, radians (`PlanAngle`).
    public var angle: Double
    public var isTowardSeat: Bool

    public init(angle: Double, isTowardSeat: Bool = true) {
        self.angle = angle
        self.isTowardSeat = isTowardSeat
    }
}

/// One step of a suggestion, in the order a person does them: slides first, then the turn.
public enum SuggestionStep: Sendable, Codable, Hashable {
    case slide(Slide)
    case turn(Turn)
}

/// What a suggestion is for.
public enum SuggestionGoal: Sendable, Codable, Hashable {
    /// A measured problem.
    case problem(AcousticProblem)
    /// From the room's shape: both speakers the same distance from the seat.
    case evenDistances
    /// From the room's shape: the pair spanning about 60°.
    case evenAngle
    /// From the room's shape: the speaker pointed at the seat.
    case toeIn
}

/// Why the model expects a suggestion to help.
public enum SuggestionReason: Sendable, Codable, Hashable {
    /// A boundary dip moves from one frequency to another.
    case boundary(surface: BoundarySurface, from: Double, to: Double)
    /// The speaker's coupling to a mode changes: the magnitude of `cos(nπx/L)` at the old and new spot.
    case mode(RoomMode, kind: AcousticProblem.Kind, couplingBefore: Double, couplingAfter: Double)
    /// The listening triangle is uneven.
    case geometry(ListeningGeometry.Issue)
}

/// What a suggestion rests on.
public enum SuggestionBasis: Sendable, Codable, Hashable {
    /// Measured problems at the seat, explained by the room model. The suggestion is still a guess about the fix:
    /// suggested, not yet tested, until a second measurement shows it.
    case measured([AcousticProblem])
    /// Only the room's shape: classic listening-triangle guidance, no measurement.
    case roomShape
}

/// The strings a suggestion shows, from `RoomText`.
public struct SuggestionText: Sendable, Codable, Hashable {
    /// "Pull the right speaker 35 cm forward and the missing bass note should return."
    public var headline: String
    /// The model's reason, with units: "The wall behind it may be cancelling 61 Hz. …"
    public var reason: String
    /// "35 cm in total"; nil for a turn on its own.
    public var totalDistance: String?
    /// "then turn 12° toward your seat"; nil without a turn.
    public var thenTurn: String?
    /// One instruction per step.
    public var steps: [String]
    /// "step 1 of 2", one per step.
    public var stepLabels: [String]
}

/// One way to move one speaker. Every suggestion is `guide`: suggested, not yet tested.
public struct PlacementSuggestion: Sendable, Codable, Hashable {
    public var speakerID: UUID
    public var role: SpeakerRole
    public var from: PlanPose
    public var to: PlanPose
    /// The slides in order; empty for a turn on its own.
    public var slides: [Slide]
    public var turn: Turn?
    /// Slides, then the turn.
    public var steps: [SuggestionStep]
    public var goal: SuggestionGoal
    public var reason: SuggestionReason
    /// Higher is better; only comparable within one call to the advisor.
    public var score: Double
    public var basis: SuggestionBasis
    public var text: SuggestionText

    /// The straight-line distance from `from` to `to`, metres.
    public var distance: Double { from.position.distance(to: to.position) }

    /// The measured problem this targets, if any.
    public var problem: AcousticProblem? {
        if case .problem(let problem) = goal { return problem }
        return nil
    }

    /// Where AR guidance starts and ends.
    public var target: MoveGuidance.Target { MoveGuidance.Target(start: from, end: to) }
}

/// A model term that could explain a measured problem.
public enum ModelTerm: Sendable, Codable, Hashable {
    /// A speaker's boundary dip near a measured dip.
    case boundary(speakerID: UUID, dip: BoundaryDip)
    /// An axial mode near the problem, with the magnitude of its pressure at the seat and at each speaker.
    case mode(RoomMode, seatCoupling: Double, speakerCouplings: [SpeakerCoupling])

    public var frequency: Double {
        switch self {
        case .boundary(_, let dip): dip.frequency
        case .mode(let mode, _, _): mode.frequency
        }
    }
}

public struct SpeakerCoupling: Sendable, Codable, Hashable {
    public var speakerID: UUID
    /// `|cos(nπx/L)|` at the speaker, 0…1.
    public var coupling: Double
}

/// How the model accounts for one measured problem.
public struct ProblemExplanation: Sendable, Codable, Hashable {
    public var problem: AcousticProblem
    /// Every term within tolerance, closest in frequency first; empty when unexplained.
    public var terms: [ModelTerm]

    public var isExplained: Bool { !terms.isEmpty }
}

/// The advisor's answer: suggestions, and how each problem was explained.
public struct PlacementAdvice: Sendable, Codable, Hashable {
    /// The best first; main speakers and the subwoofer in one ranking.
    public var suggestions: [PlacementSuggestion]
    public var explanations: [ProblemExplanation]

    /// Measured problems no model term explains; the advisor suggests nothing for them.
    public var unexplained: [AcousticProblem] { explanations.filter { !$0.isExplained }.map(\.problem) }

    /// One sentence per unexplained problem.
    public var unexplainedText: [String] { unexplained.map(RoomText.unexplained) }
}

/// What the advisor may suggest.
public struct PlacementLimits: Sendable, Codable, Hashable {
    /// The longest slide suggested for a main speaker, metres. A first guess: a nudge, not a new layout.
    public var maximumMove: Double
    /// The longest move suggested for a subwoofer, metres; a subwoofer is placed by ear more freely. A first guess.
    public var maximumSubwooferMove: Double
    /// How many main-speaker suggestions to return at most.
    public var maximumSuggestions: Int
    /// How many subwoofer suggestions to return at most.
    public var maximumSubwooferSuggestions: Int

    public init(maximumMove: Double = 0.5, maximumSubwooferMove: Double = 3.0, maximumSuggestions: Int = 3,
                maximumSubwooferSuggestions: Int = 2) {
        self.maximumMove = maximumMove
        self.maximumSubwooferMove = maximumSubwooferMove
        self.maximumSuggestions = maximumSuggestions
        self.maximumSubwooferSuggestions = maximumSubwooferSuggestions
    }

    public static let standard = PlacementLimits()
}
