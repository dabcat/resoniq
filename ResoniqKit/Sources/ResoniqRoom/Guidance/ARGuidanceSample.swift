import Foundation

/// The mockups' move, for previews, debug screens and tests: in the 4.20 × 5.60 m living room with a stereo pair
/// 2 m apart, the right speaker is pulled 35 cm toward the seat (the wall behind it may be cancelling 61 Hz),
/// then turned 12° toward the seat (V3OAR: "35 cm in total", "then turn 12° toward your seat").
public enum ARGuidanceSample {
    public static let leftID = UUID(uuidString: "A2000000-0000-4000-8000-00000000000A")!
    public static let rightID = UUID(uuidString: "A2000000-0000-4000-8000-00000000000B")!
    public static let seatID = UUID(uuidString: "A2000000-0000-4000-8000-00000000000C")!

    /// The room and the suggestion. `turnDegrees` 0 leaves the turn out (a slide on its own).
    public static func rightSpeaker(turnDegrees: Double = 12) -> (room: RoomModel, suggestion: PlacementSuggestion) {
        var room = ManualRoom(width: 4.2, length: 5.6, height: 2.4).model() ?? RoomModel(source: .manual, walls: [])
        let seat = PlanPoint(x: 0, z: -1.4 + 3.0.squareRoot())
        let left = PlanPoint(x: -1, z: -1.4), right = PlanPoint(x: 1, z: -1.4)
        room.seats = [Seat(id: seatID, position: seat, isConfirmed: true)]
        room.speakers = [
            PlacedSpeaker(id: leftID, role: .left, position: left, facing: (seat - left).angle, isConfirmed: true),
            PlacedSpeaker(id: rightID, role: .right, position: right, facing: (seat - right).angle, isConfirmed: true),
        ]
        let from = PlanPose(position: right, facing: (seat - right).angle)
        let slide = Slide(direction: .forward, distance: 0.35)
        let turn = turnDegrees == 0 ? nil : Turn(angle: PlanAngle.radians(turnDegrees))
        let to = PlanPose(position: right + PlanPoint(x: 0, z: slide.distance),
                          facing: from.facing + (turn?.angle ?? 0))
        let problem = AcousticProblem(frequency: 61, deviation: 11, kind: .dip)
        let goal = SuggestionGoal.problem(problem)
        let reason = SuggestionReason.boundary(surface: .wallBehind, from: 61, to: 78)
        let steps: [SuggestionStep] = [.slide(slide)] + (turn.map { [.turn($0)] } ?? [])
        let text = SuggestionText(
            headline: RoomText.headline(role: .right, slides: [slide], turn: turn, goal: goal),
            reason: RoomText.reason(reason, slides: [slide], geometry: nil),
            totalDistance: RoomText.totalDistance(slide.distance),
            thenTurn: turn.map(RoomText.thenTurn),
            steps: steps.map(RoomText.stepInstruction),
            stepLabels: steps.indices.map { RoomText.stepLabel($0 + 1, of: steps.count) })
        let suggestion = PlacementSuggestion(
            speakerID: rightID, role: .right, from: from, to: to, slides: [slide], turn: turn, steps: steps,
            goal: goal, reason: reason, score: 1, basis: .measured([problem]), text: text)
        return (room, suggestion)
    }
}
