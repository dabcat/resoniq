import Foundation
import Testing
@testable import ResoniqRoom

@Suite struct PlacementAdvisorTests {
    let dip61 = AcousticProblem(frequency: 61, deviation: 11, kind: .dip)

    /// The rules every suggestion keeps, whatever it is for.
    func checkRules(_ suggestions: [PlacementSuggestion], in room: RoomModel, limits: PlacementLimits = .standard) {
        for suggestion in suggestions {
            guard let speaker = room.speaker(suggestion.speakerID) else {
                Issue.record("unknown speaker")
                continue
            }
            let footprint = OrientedRect(
                centre: suggestion.to.position, width: speaker.size.width, depth: speaker.size.depth,
                heading: suggestion.to.facing)
            #expect(RoomGeometry.contains(suggestion.to.position, in: room))
            #expect(PlacementRules.allows(speakerFootprint: footprint, ignoring: speaker.id, in: room))
            let limit = speaker.role == .subwoofer ? limits.maximumSubwooferMove : limits.maximumMove
            #expect(suggestion.distance <= limit + 1e-9)
            #expect(suggestion.steps.count == suggestion.slides.count + (suggestion.turn == nil ? 0 : 1))
            #expect(suggestion.text.stepLabels.last == RoomText.stepLabel(suggestion.steps.count, of: suggestion.steps.count))
            #expect(!suggestion.text.headline.contains("will"))
        }
    }

    @Test func aBoundaryDipAt61HzIsMovedForwardOrBack() throws {
        let room = Fixtures.stereoRoom
        let advice = PlacementAdvisor.advice(room: room, problems: [dip61])
        let explanation = try #require(advice.explanations.first)
        // Both speakers' rear-wall dips (61.25 Hz) and the length's second mode (61.25 Hz, speakers on its null).
        #expect(explanation.terms.count == 3)
        if case .boundary(_, let dip) = explanation.terms[0] { #expect(dip.surface == .wallBehind) } else {
            Issue.record("a boundary term should come first")
        }

        let suggestions = advice.suggestions
        #expect(suggestions.count >= 2)
        let best = try #require(suggestions.first)
        let slide = try #require(best.slides.first)
        #expect(best.slides.count == 1)
        #expect(slide.direction == .forward || slide.direction == .back)
        #expect(slide.distance <= PlacementLimits.standard.maximumMove + 1e-9)
        #expect(best.problem == dip61)
        #expect(best.basis == .measured([dip61]))
        guard case .boundary(.wallBehind, let before, let after) = best.reason else {
            Issue.record("the reason should be the wall behind, got \(best.reason)")
            return
        }
        #expect(isClose(before, 61.25, 1e-9))
        // The new rear-wall dip is c/4d at the new distance, at least a sixth of an octave away from 61 Hz.
        let newDistance = best.to.position.z - (-2.8)
        #expect(isClose(after, 343 / (4 * newDistance), 1e-6))
        #expect(abs(log2(after / 61)) >= PlacementAdvisor.boundaryTolerance)
        // With today's constants: 40 cm forward is the smallest grid step that moves the dip a third of an octave
        // (1.40 m · 2^(1/3) = 1.76 m), to 343 / 7.2 = 47.6 Hz. Going back 30 cm would land it on the side wall's
        // 78 Hz dip, which the stacking penalty ranks lower.
        #expect(slide.direction == .forward && isClose(slide.distance, 0.4, 1e-9))
        #expect(isClose(after, 343 / 7.2, 1e-6))

        // The mockup's sentence form.
        let verb = slide.direction == .forward ? "Pull" : "Push"
        let way = slide.direction == .forward ? "forward" : "back"
        let name = best.role == .right ? "right" : "left"
        #expect(best.text.headline
            == "\(verb) the \(name) speaker \(RoomText.move(slide.distance)) \(way) and the missing bass note should return.")
        #expect(best.text.totalDistance == "\(RoomText.move(slide.distance)) in total")
        if let turn = best.turn {
            #expect(best.text.thenTurn == "then turn \(RoomText.degrees(turn.angle)) toward your seat")
            #expect(best.text.stepLabels == ["step 1 of 2", "step 2 of 2"])
            #expect(best.steps.last == .turn(turn))
        }

        // A distinct second suggestion for "Can't move it".
        let second = suggestions[1]
        #expect(second.speakerID != best.speakerID || second.slides.first?.direction != slide.direction)
        #expect(second.score <= best.score)
        checkRules(suggestions, in: room)
    }

    @Test func turnsAimAtTheSeat() throws {
        let room = Fixtures.stereoRoom
        let seat = try #require(room.primarySeat).position
        for suggestion in PlacementAdvisor.suggestions(room: room, problems: [dip61]) where suggestion.turn != nil {
            #expect(isClose(suggestion.to.facing, (seat - suggestion.to.position).angle, 1e-9))
        }
    }

    @Test func directionsAreTheListenersView() throws {
        let room = Fixtures.stereoRoom
        let frame = PlacementAdvisor.frame(in: room, seat: try #require(room.primarySeat).position)
        // The listener faces the pair (−z): forward is +z (toward the seat), left is −x.
        #expect(isClose(try #require(frame[.forward]), PlanPoint(x: 0, z: 1), 1e-12))
        #expect(isClose(try #require(frame[.back]), PlanPoint(x: 0, z: -1), 1e-12))
        #expect(isClose(try #require(frame[.left]), PlanPoint(x: -1, z: 0), 1e-12))
        #expect(isClose(try #require(frame[.right]), PlanPoint(x: 1, z: 0), 1e-12))
    }

    @Test func anUnexplainedProblemGetsNoMove() throws {
        let room = Fixtures.stereoRoom
        // A peak at 250 Hz: above every mode the model keeps and no boundary makes peaks. A dip at 24 Hz: below the
        // first mode (30.6 Hz) by more than the tolerance, and no surface is 3.6 m from a speaker.
        let problems = [
            AcousticProblem(frequency: 250, deviation: 8, kind: .peak),
            AcousticProblem(frequency: 24, deviation: 9, kind: .dip),
        ]
        let advice = PlacementAdvisor.advice(room: room, problems: problems)
        #expect(advice.suggestions.isEmpty)
        #expect(advice.unexplained == problems)
        #expect(advice.unexplainedText[0]
            == "I can't tie the peak at 250 Hz to the room's shape, so I won't guess a move for it.")
    }

    @Test func noProblemsGivesOnlyGeometry() throws {
        var room = Fixtures.stereoRoom
        // Uneven: the right speaker 30 cm farther back and pointing straight ahead.
        room.speakers[1].position = PlanPoint(x: 1, z: -1.7)
        room.speakers[1].facing = .pi / 2
        let suggestions = PlacementAdvisor.suggestions(room: room, problems: [])
        #expect(!suggestions.isEmpty)
        for suggestion in suggestions {
            #expect(suggestion.basis == .roomShape)
            #expect(suggestion.problem == nil)
            #expect(suggestion.text.reason.hasPrefix(RoomText.roomShapeBasis))
        }
        #expect(suggestions.contains { $0.goal == .evenDistances })
        // Every move ends pointed at the seat.
        #expect(suggestions.allSatisfy { $0.turn != nil })
        checkRules(suggestions, in: room)

        // An even triangle with both speakers facing straight down the room: a turn on its own for each.
        var straight = Fixtures.stereoRoom
        straight.speakers[0].facing = .pi / 2
        straight.speakers[1].facing = .pi / 2
        let turns = PlacementAdvisor.suggestions(room: straight, problems: [])
        #expect(turns.count == 2)
        for turn in turns {
            #expect(turn.goal == .toeIn && turn.slides.isEmpty && turn.steps.count == 1)
            // 30° each: the seat is atan(1/√3) off the speakers' axis.
            #expect(isClose(abs(try #require(turn.turn).angle), .pi / 6, 1e-9))
        }
        #expect(turns.first?.text.headline == "Turn the left speaker 30° toward your seat and the stereo image should sharpen.")
        #expect(turns.first?.text.totalDistance == nil)
        // An even, toed-in triangle gets nothing.
        #expect(PlacementAdvisor.suggestions(room: Fixtures.stereoRoom, problems: []).isEmpty)
    }

    @Test(arguments: [0.2, 0.5])
    func suggestionsKeepTheRules(maximumMove: Double) {
        let room = Fixtures.stereoRoom
        let limits = PlacementLimits(maximumMove: maximumMove)
        let problems = [dip61, AcousticProblem(frequency: 41, deviation: 7, kind: .peak),
                        AcousticProblem(frequency: 95, deviation: 6, kind: .dip)]
        checkRules(PlacementAdvisor.suggestions(room: room, problems: problems, limits: limits), in: room, limits: limits)
    }

    @Test func aWallOrFurnitureLimitsTheMove() throws {
        // The right speaker 0.30 m from the back wall, turned toward the seat: its footprint reaches about 0.18 m
        // behind its centre, so with the 5 cm clearance it can go back 5 cm at most.
        var room = Fixtures.stereoRoom
        room.speakers[1].position = PlanPoint(x: 1, z: -2.5)
        let dip = AcousticProblem(frequency: 343 / (4 * 0.3), deviation: 10, kind: .dip)
        let suggestions = PlacementAdvisor.suggestions(room: room, problems: [dip])
        #expect(!suggestions.isEmpty)
        for suggestion in suggestions where suggestion.slides.first?.direction == .back {
            #expect(suggestion.distance <= 0.05 + 1e-9)
        }
        checkRules(suggestions, in: room)
    }

    @Test func aSubwooferIsPlacedAlongTheWalls() throws {
        var room = Fixtures.stereoRoom
        // A subwoofer in the back-left corner, exciting the length's first mode; the seat is near its antinode? The
        // seat at z = 0.33 is 3.13 m from the back wall: |cos(π·3.13/5.6)| = 0.18, so a peak there is not
        // explained. Use the width's second mode (81.7 Hz): seat at x = 0, 2.1 m from the side, |cos(2π·2.1/4.2)| = 1.
        room.speakers.append(
            PlacedSpeaker(id: Fixtures.subID, role: .subwoofer, position: PlanPoint(x: -1.8, z: -2.5), facing: .pi / 2,
                          isConfirmed: true))
        let peak = AcousticProblem(frequency: 82, deviation: 9, kind: .peak)
        let advice = PlacementAdvisor.advice(room: room, problems: [peak])
        let subSuggestions = advice.suggestions.filter { $0.role == .subwoofer }
        #expect(!subSuggestions.isEmpty)
        let best = try #require(subSuggestions.first)
        guard case .mode(let mode, .peak, let before, let after) = best.reason else {
            Issue.record("a subwoofer suggestion rests on a mode, got \(best.reason)")
            return
        }
        #expect(mode.dimension == .width && mode.order == 2)
        #expect(after < before)
        #expect(best.turn == nil)
        #expect(best.text.headline.hasSuffix("the boomy bass note should calm down."))
        // Along a wall: the footprint is near one.
        let footprint = OrientedRect(centre: best.to.position, width: 0.35, depth: 0.35, heading: best.to.facing)
        #expect(try #require(RoomGeometry.distanceToNearestWall(footprint: footprint, in: room)) < 0.2)
        checkRules(advice.suggestions, in: room)
    }

    @Test func noSeatMeansNoSuggestion() {
        var room = Fixtures.stereoRoom
        room.seats = []
        let advice = PlacementAdvisor.advice(room: room, problems: [dip61])
        #expect(advice.suggestions.isEmpty && advice.unexplained == [dip61])
    }
}
