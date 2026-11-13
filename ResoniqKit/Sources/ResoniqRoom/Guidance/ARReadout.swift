import Foundation

/// What the AR guide's readout shows (V3OAR): the step title, the "to go" value, the instruction, the bar and the
/// lines under it, the haptics line, and the sentence VoiceOver speaks. All strings come from `RoomText` and
/// `ARGuidanceText`.
public struct ARReadoutText: Sendable, Equatable {
    /// "Right speaker · step 1 of 2".
    public var title: String
    /// "To go", or "Turn" on the turn step.
    public var toGoLabel: String
    /// "18".
    public var value: String
    /// "cm", "m" or "°".
    public var unit: String
    /// The bar, 0…1.
    public var fraction: Double
    /// What the bar measures, for VoiceOver.
    public var progressLabel: String
    /// "Slide it toward you until it fills the blue outline."
    public var instruction: String
    /// "35 cm in total".
    public var totalLine: String?
    /// "then turn 12° toward your seat".
    public var turnLine: String?
    /// The line with the dot: what the haptics do, or that the turn is by eye.
    public var hint: String?
    /// "18 centimetres to go, toward you".
    public var spoken: String

    /// The slide step.
    public static func sliding(_ progress: MoveProgress, suggestion: PlacementSuggestion) -> ARReadoutText {
        let parts = RoomText.moveParts(progress.distanceToGo)
        let instruction = progress.direction.map(RoomText.slideInstruction) ?? ARGuidanceText.arrivedInstruction
        return ARReadoutText(
            title: title(suggestion, step: 1),
            toGoLabel: RoomText.toGoLabel, value: parts.value, unit: parts.unit,
            fraction: progress.fractionDone, progressLabel: ARGuidanceText.slideProgressLabel,
            instruction: instruction,
            totalLine: RoomText.totalDistance(suggestion.target.totalDistance),
            turnLine: suggestion.turn.map(RoomText.thenTurn),
            hint: RoomText.hapticHint,
            spoken: RoomText.spokenProgress(distance: progress.distanceToGo, direction: progress.direction))
    }

    /// The turn step: the angle still to turn, as suggested (the phone cannot see the speaker turn).
    public static func turning(_ progress: MoveProgress, suggestion: PlacementSuggestion) -> ARReadoutText {
        let angle = progress.turnRemaining
        return ARReadoutText(
            title: title(suggestion, step: suggestion.steps.count),
            toGoLabel: ARGuidanceText.turnLabel, value: "\(Int(PlanAngle.degrees(abs(angle)).rounded()))", unit: "°",
            fraction: 1, progressLabel: ARGuidanceText.slideProgressLabel,
            instruction: ARGuidanceText.turnInstruction(angle),
            totalLine: RoomText.totalDistance(suggestion.target.totalDistance),
            turnLine: nil,
            hint: ARGuidanceText.turnHint,
            spoken: ARGuidanceText.turnInstruction(angle))
    }

    /// In position, nothing to turn.
    public static func arrived(suggestion: PlacementSuggestion) -> ARReadoutText {
        let parts = RoomText.moveParts(0)
        return ARReadoutText(
            title: title(suggestion, step: suggestion.steps.count),
            toGoLabel: RoomText.toGoLabel, value: parts.value, unit: parts.unit,
            fraction: 1, progressLabel: ARGuidanceText.slideProgressLabel,
            instruction: ARGuidanceText.arrivedInstruction,
            totalLine: RoomText.totalDistance(suggestion.target.totalDistance),
            turnLine: nil, hint: nil, spoken: ARGuidanceText.arrivedInstruction)
    }

    static func title(_ suggestion: PlacementSuggestion, step: Int) -> String {
        let count = max(1, suggestion.steps.count)
        return RoomText.stepTitle(role: suggestion.role, step: min(max(1, step), count), of: count)
    }
}

extension ARGuidanceState {
    /// The readout for the step the guide is on; nil before the mark and once finished.
    public var readout: ARReadoutText? {
        guard let progress else { return nil }
        switch phase {
        case .sliding: return .sliding(progress, suggestion: suggestion)
        case .turning: return .turning(progress, suggestion: suggestion)
        case .arrived: return .arrived(suggestion: suggestion)
        default: return nil
        }
    }

    /// The label at the turn arc's end, "turn 12°", while the arc shows.
    public var arcLabel: String? {
        guard showsTurn, let progress else { return nil }
        return RoomText.turnLabel(progress.turnRemaining)
    }
}

/// Decides when VoiceOver hears the distance again: no more often than `minimumInterval`, and only when the
/// distance has changed by `minimumChange` or the direction has changed. The haptics and the bar say it too;
/// this keeps the spoken line useful without talking over the person.
public struct ARProgressAnnouncer: Sendable {
    /// Seconds between announcements. A first guess.
    public static let minimumInterval: TimeInterval = 3
    /// Metres the distance must change by to be worth saying again. A first guess.
    public static let minimumChange = 0.02

    private var lastTime: TimeInterval?
    private var lastDistance: Double?
    private var lastDirection: ViewerDirection?

    public init() {}

    public mutating func announcement(for progress: MoveProgress, at time: TimeInterval) -> String? {
        if let lastTime, time - lastTime < Self.minimumInterval { return nil }
        if let lastDistance, abs(progress.distanceToGo - lastDistance) < Self.minimumChange,
           progress.direction == lastDirection {
            return nil
        }
        lastTime = time
        lastDistance = progress.distanceToGo
        lastDirection = progress.direction
        return RoomText.spokenProgress(distance: progress.distanceToGo, direction: progress.direction)
    }

    /// Forget what was said, so the next progress is announced at once (a new step).
    public mutating func reset() {
        self = ARProgressAnnouncer()
    }
}
