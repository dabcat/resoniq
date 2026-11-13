import Foundation
import Testing
@testable import ResoniqRoom

/// The mockup's move (V3OAR): the right speaker 35 cm toward the person, then 12° toward the seat. The world is
/// the model turned by 0.6 rad and shifted, as a fresh AR session would put it.
private enum Move {
    static let sample = ARGuidanceSample.rightSpeaker()
    static var suggestion: PlacementSuggestion { sample.suggestion }
    static let world = WorldAlignment(rotation: 0.6, translation: PlanPoint(x: 3.1, z: -0.7))
    static let depth = PlacedSpeaker.defaultSize.depth

    /// The speaker's world pose before the move.
    static var start: PlanPose { world.apply(suggestion.from) }

    /// Where the reticle sits to mark a speaker whose centre is at `centre` (world): the middle of its front edge.
    static func frontEdge(ofCentre centre: PlanPoint, facing: Double) -> FloorHit {
        FloorHit(point: centre + PlanPoint(angle: facing) * (depth / 2), height: -1.2)
    }

    /// Standing 1.5 m in front of the speaker, looking straight at it.
    static var camera: Viewer {
        Viewer(position: start.position + PlanPoint(angle: start.facing) * 1.5, heading: start.facing + .pi)
    }

    /// The speaker's centre, in the world, `metres` along the slide.
    static func along(_ metres: Double) -> PlanPoint {
        let model = suggestion.from.position + (suggestion.to.position - suggestion.from.position).normalized * metres
        return world.apply(model)
    }

    /// Floor found, tracking normal, the reticle on the front edge, the camera in front.
    static func readyToMark() -> ARGuidanceState {
        var state = ARGuidanceState(suggestion: suggestion, room: sample.room)
        _ = state.apply(.trackingRecovered)
        _ = state.apply(.floorFound)
        _ = state.apply(.cameraMoved(camera))
        _ = state.apply(.reticleMoved(frontEdge(ofCentre: start.position, facing: start.facing)))
        return state
    }

    static func follow(_ state: inout ARGuidanceState, to metres: Double) -> [ARGuidanceEffect] {
        state.apply(.reticleMoved(frontEdge(ofCentre: along(metres), facing: start.facing)))
    }
}

@Suite struct ARGuidanceStateTests {
    @Test func aWholeMoveFromFloorToPlaced() throws {
        var state = ARGuidanceState(suggestion: Move.suggestion, room: Move.sample.room)
        #expect(state.phase == .findingFloor)
        #expect(!state.canMark)
        _ = state.apply(.trackingRecovered)
        _ = state.apply(.floorFound)
        #expect(state.phase == .markingSpeaker)
        // No reticle on the floor yet: nothing to mark.
        #expect(!state.canMark)
        _ = state.apply(.cameraMoved(Move.camera))
        _ = state.apply(.reticleMoved(Move.frontEdge(ofCentre: Move.start.position, facing: Move.start.facing)))
        #expect(state.canMark)
        _ = state.apply(.marked)
        #expect(state.phase == .sliding)
        let progress = try #require(state.progress)
        #expect(isClose(progress.distanceToGo, 0.35, 1e-9))
        #expect(isClose(progress.fractionDone, 0, 1e-9))
        #expect(!state.canConfirm)

        // Without follow, the reticle moving does not move the speaker.
        _ = Move.follow(&state, to: 0.2)
        #expect(isClose(try #require(state.progress).distanceToGo, 0.35, 1e-9))

        _ = state.apply(.follow(true))
        #expect(Move.follow(&state, to: 0.17).isEmpty)
        #expect(isClose(try #require(state.progress).distanceToGo, 0.18, 1e-9))
        #expect(state.hapticInterval != nil)

        let effects = Move.follow(&state, to: 0.34)
        #expect(effects == [.reachedPosition])
        #expect(state.phase == .turning)
        #expect(state.canConfirm)
        #expect(state.hapticInterval == nil)

        let placed = state.apply(.confirm)
        let pose = try #require(state.placedPose)
        #expect(placed == [.placed(pose)])
        #expect(state.phase == .placed(pose))
        // Back in room coordinates: within a centimetre of the target, facing as suggested (confirmed by eye).
        #expect(pose.position.distance(to: Move.suggestion.to.position) < 0.011)
        #expect(isClose(pose.facing, Move.suggestion.to.facing, 1e-12))
        // Finished: nothing more happens.
        #expect(state.apply(.decline).isEmpty)
        #expect(state.phase == .placed(pose))
    }

    @Test func aMoveWithoutATurnArrives() throws {
        let sample = ARGuidanceSample.rightSpeaker(turnDegrees: 0)
        var state = ARGuidanceState(suggestion: sample.suggestion, room: sample.room)
        _ = state.apply(.trackingRecovered)
        _ = state.apply(.floorFound)
        let start = WorldAlignment.identity.apply(sample.suggestion.from)
        _ = state.apply(.cameraMoved(Viewer(position: .zero, heading: start.facing + .pi)))
        _ = state.apply(.reticleMoved(Move.frontEdge(ofCentre: start.position, facing: start.facing)))
        _ = state.apply(.marked)
        _ = state.apply(.follow(true))
        let end = sample.suggestion.to.position
        #expect(state.apply(.reticleMoved(Move.frontEdge(ofCentre: end, facing: start.facing))) == [.reachedPosition])
        #expect(state.phase == .arrived)
        #expect(state.canConfirm)
    }

    @Test func declineFromAnyPhaseBeforeTheEnd() {
        var finding = ARGuidanceState(suggestion: Move.suggestion, room: Move.sample.room)
        #expect(finding.apply(.decline) == [.declined])
        #expect(finding.phase == .declined)

        var sliding = Move.readyToMark()
        _ = sliding.apply(.marked)
        #expect(sliding.apply(.decline) == [.declined])
        #expect(sliding.phase == .declined)
        #expect(sliding.placedPose == nil)
    }

    @Test func trackingLostAndRecoveredMidSlide() throws {
        var state = Move.readyToMark()
        _ = state.apply(.marked)
        _ = state.apply(.follow(true))
        _ = Move.follow(&state, to: 0.10)
        _ = state.apply(.trackingDegraded(.excessiveMotion))
        #expect(state.tracking == .limited(.excessiveMotion))
        #expect(state.phase == .sliding)
        #expect(state.hapticInterval == nil)
        // A reticle while tracking is limited is not trusted: the speaker stays where it was last seen.
        _ = Move.follow(&state, to: 0.30)
        #expect(isClose(try #require(state.progress).distanceToGo, 0.25, 1e-9))

        _ = state.apply(.interrupted)
        #expect(state.tracking == .interrupted)
        _ = state.apply(.interruptionEnded)
        #expect(state.tracking == .limited(.relocalizing))
        #expect(!state.canMark)
        _ = state.apply(.trackingRecovered)
        #expect(state.tracking == .normal)
        // The alignment survived: following again carries on from the same target.
        _ = Move.follow(&state, to: 0.30)
        #expect(isClose(try #require(state.progress).distanceToGo, 0.05, 1e-9))
        #expect(state.hapticInterval != nil)
    }

    @Test func remarkingStartsTheAlignmentAgain() throws {
        var state = Move.readyToMark()
        // A mark 20 cm off to the side, then thought better of.
        let wrong = Move.start.position + PlanPoint(angle: Move.start.facing).rightHand * 0.2
        _ = state.apply(.reticleMoved(Move.frontEdge(ofCentre: wrong, facing: Move.start.facing)))
        _ = state.apply(.marked)
        let wrongTarget = try #require(state.target)
        _ = state.apply(.follow(true))
        _ = state.apply(.remark)
        #expect(state.phase == .markingSpeaker)
        #expect(state.alignment == nil && state.speaker == nil && !state.isFollowing)
        _ = state.apply(.reticleMoved(Move.frontEdge(ofCentre: Move.start.position, facing: Move.start.facing)))
        _ = state.apply(.marked)
        let target = try #require(state.target)
        #expect(target.position.distance(to: Move.world.apply(Move.suggestion.to.position)) < 1e-9)
        #expect(wrongTarget.position.distance(to: target.position) > 0.19)
    }

    @Test func leavingThePositionGoesBackToSliding() {
        var state = Move.readyToMark()
        _ = state.apply(.marked)
        _ = state.apply(.follow(true))
        _ = Move.follow(&state, to: 0.35)
        #expect(state.phase == .turning)
        // Inside the hysteresis it stays put; beyond it, it slides again.
        _ = Move.follow(&state, to: 0.31)
        #expect(state.phase == .turning)
        _ = Move.follow(&state, to: 0.25)
        #expect(state.phase == .sliding)
        #expect(!state.canConfirm)
    }

    @Test func markNeedsNormalTracking() {
        var state = Move.readyToMark()
        _ = state.apply(.trackingDegraded(.insufficientFeatures))
        #expect(!state.canMark)
        _ = state.apply(.marked)
        #expect(state.phase == .markingSpeaker)
    }

    @Test func tooDarkIsReadFromTheLight() {
        #expect(ARTrackingIssue.insufficientFeatures(ambientIntensity: 30) == .tooDark)
        #expect(ARTrackingIssue.insufficientFeatures(ambientIntensity: 900) == .insufficientFeatures)
        #expect(ARTrackingIssue.insufficientFeatures(ambientIntensity: nil) == .insufficientFeatures)
    }
}

@Suite struct ARGuidanceAlignmentTests {
    @Test func aMarkMapsTheModelTargetIntoTheWorldAndBack() throws {
        var state = Move.readyToMark()
        _ = state.apply(.marked)
        let alignment = try #require(state.alignment)
        #expect(isClose(alignment.rotation, Move.world.rotation, 1e-9))
        #expect(isClose(alignment.translation, Move.world.translation, 1e-9))
        let target = try #require(state.target)
        #expect(isClose(target.position, Move.world.apply(Move.suggestion.to.position), 1e-9))
        #expect(isClose(alignment.inverse.apply(target.position), Move.suggestion.to.position, 1e-9))
        #expect(isClose(PlanAngle.difference(from: alignment.inverse.apply(heading: target.facing),
                                             to: Move.suggestion.to.facing), 0, 1e-9))
        let speaker = try #require(state.speaker)
        #expect(isClose(speaker.position, Move.start.position, 1e-9))
    }

    @Test func aCameraHeadingOffByAFewDegreesMovesTheTargetLittle() throws {
        var state = Move.readyToMark()
        var camera = Move.camera
        camera.heading += PlanAngle.radians(5)
        _ = state.apply(.cameraMoved(camera))
        _ = state.apply(.marked)
        let target = try #require(state.target)
        // 5° about a point 15 cm behind the mark moves a target 35 cm away by about 4 cm.
        #expect(target.position.distance(to: Move.world.apply(Move.suggestion.to.position)) < 0.05)
    }

    @Test func aSecondMatchedPointRefitsAndReportsTheResidual() throws {
        var state = Move.readyToMark()
        _ = state.apply(.marked)
        let seat = try #require(Move.sample.room.primarySeat).position
        let refit = try #require(state.refinedAlignment(matching: [(model: seat, world: Move.world.apply(seat))]))
        #expect(refit.isConsistent)
        #expect(isClose(refit.rotation, Move.world.rotation, 1e-6))
        let wrong = Move.world.apply(seat) + PlanPoint(x: 0.6, z: 0)
        let bad = try #require(state.refinedAlignment(matching: [(model: seat, world: wrong)]))
        #expect(!bad.isConsistent)
    }
}

@Suite struct ARGuidanceGeometryTests {
    @Test func footprintCornersOfATurnedPose() {
        let size = FootprintSize(width: 0.2, depth: 0.4)
        // Facing +z: the front is at z + 0.2, the front-right corner at x − 0.1 (right of +z is −x).
        let facingZ = ARGuidanceGeometry.footprint(of: PlanPose(position: PlanPoint(x: 1, z: 2), facing: .pi / 2), size: size)
        let expected = [PlanPoint(x: 0.9, z: 2.2), PlanPoint(x: 1.1, z: 2.2), PlanPoint(x: 1.1, z: 1.8), PlanPoint(x: 0.9, z: 1.8)]
        for (corner, want) in zip(facingZ.corners, expected) { #expect(isClose(corner, want, 1e-12)) }

        // 45°: every corner half the diagonal from the centre, the front edge's middle 0.2 m along the facing.
        let pose = PlanPose(position: .zero, facing: .pi / 4)
        let turned = ARGuidanceGeometry.footprint(of: pose, size: size)
        let halfDiagonal = hypot(0.1, 0.2)
        #expect(turned.corners.allSatisfy { isClose($0.length, halfDiagonal, 1e-12) })
        let front = ARGuidanceGeometry.frontEdgeCentre(of: pose, size: size)
        #expect(isClose(front, PlanPoint(x: 0.2 / 2.0.squareRoot(), z: 0.2 / 2.0.squareRoot()), 1e-12))
        #expect(isClose((turned.corners[0] + turned.corners[1]) * 0.5, front, 1e-12))
        #expect(isClose(ARGuidanceGeometry.centre(behindFrontEdge: front, facing: pose.facing, size: size), .zero, 1e-12))
    }

    @Test func dashesCoverTheOutlineAndMarch() {
        let square = OrientedRect(centre: .zero, width: 1, depth: 1, heading: 0).corners
        let dashes = ARGuidanceGeometry.dashes(around: square, dash: 0.1, gap: 0.1, phase: 0)
        let drawn = dashes.reduce(0) { $0 + $1.start.distance(to: $1.end) }
        #expect(isClose(drawn, 2, 1e-9))
        #expect(dashes.allSatisfy { $0.start.distance(to: $0.end) <= 0.1 + 1e-12 })
        // Half a period on, the dashes sit where the gaps were.
        let marched = ARGuidanceGeometry.dashes(around: square, dash: 0.1, gap: 0.1, phase: 0.1)
        let first = dashes[0], moved = marched[0]
        #expect(!isClose(first.start, moved.start, 1e-6))
        #expect(isClose(marched.reduce(0) { $0 + $1.start.distance(to: $1.end) }, 2, 1e-9))
        #expect(ARGuidanceGeometry.marchPhase(time: 0.25, reduceMotion: true) == 0)
        #expect(isClose(ARGuidanceGeometry.marchPhase(time: 1.25, reduceMotion: false),
                        ARGuidanceGeometry.marchPhase(time: 0.25, reduceMotion: false), 1e-12))
    }

    @Test func theTurnArcRunsFromTheFacingToTheTarget() throws {
        let arc = ARGuidanceGeometry.turnArc(around: .zero, radius: 0.3, from: 0, to: PlanAngle.radians(12))
        let first = try #require(arc.first), last = try #require(arc.last)
        #expect(isClose(first, PlanPoint(x: 0.3, z: 0), 1e-12))
        #expect(isClose(last.angle, PlanAngle.radians(12), 1e-12))
        #expect(arc.allSatisfy { isClose($0.length, 0.3, 1e-12) })
        #expect(arc.count >= 3)
    }
}

@Suite struct ARReadoutTextTests {
    /// V3OAR verbatim.
    @Test func theMockupsReadout() throws {
        var state = Move.readyToMark()
        _ = state.apply(.marked)
        _ = state.apply(.follow(true))
        _ = Move.follow(&state, to: 0.17)
        let readout = try #require(state.readout)
        #expect(readout.title == "Right speaker · step 1 of 2")
        #expect(readout.toGoLabel == "To go")
        #expect(readout.value == "18")
        #expect(readout.unit == "cm")
        #expect(readout.instruction == "Slide it toward you until it fills the blue outline.")
        #expect(readout.totalLine == "35 cm in total")
        #expect(readout.turnLine == "then turn 12° toward your seat")
        #expect(readout.hint == "Taps in your hand speed up as you get closer.")
        #expect(readout.spoken == "18 centimetres to go, toward you")
        #expect(isClose(readout.fraction, 17.0 / 35.0, 1e-9))
        #expect(state.arcLabel == nil)
    }

    @Test func theTurnSaysItCannotBeMeasured() throws {
        var state = Move.readyToMark()
        _ = state.apply(.marked)
        _ = state.apply(.follow(true))
        _ = Move.follow(&state, to: 0.35)
        let readout = try #require(state.readout)
        #expect(readout.title == "Right speaker · step 2 of 2")
        #expect(readout.value == "12")
        #expect(readout.unit == "°")
        #expect(readout.toGoLabel == "Turn")
        #expect(readout.instruction == "Turn it 12° toward your seat until its front lines up with the blue outline.")
        #expect(readout.hint == "I can't see the speaker turn, so line it up by eye.")
        #expect(readout.turnLine == nil)
        #expect(state.arcLabel == "turn 12°")
    }

    @Test func spokenDistances() {
        #expect(RoomText.spokenProgress(distance: 0.01, direction: .left) == "1 centimetre to go, to your left")
        #expect(RoomText.spokenProgress(distance: 1.2, direction: .awayFromYou) == "1.20 metres to go, away from you")
        #expect(RoomText.spokenProgress(distance: 0.02, direction: nil) == "In place")
    }

    @Test func announcementsAreSpacedOut() {
        var announcer = ARProgressAnnouncer()
        func progress(_ distance: Double) -> MoveProgress {
            MoveProgress(distanceToGo: distance, direction: .towardYou, bearing: .pi, turnRemaining: 0,
                         totalDistance: 0.35, fractionDone: 0, isInPosition: false, hasArrived: false)
        }
        #expect(announcer.announcement(for: progress(0.30), at: 0) == "30 centimetres to go, toward you")
        #expect(announcer.announcement(for: progress(0.25), at: 1) == nil)
        #expect(announcer.announcement(for: progress(0.25), at: 3.5) == "25 centimetres to go, toward you")
        // No change worth saying: quiet.
        #expect(announcer.announcement(for: progress(0.245), at: 8) == nil)
    }

    @Test func trackingMessages() {
        for issue in ARTrackingIssue.allCases {
            let message = ARGuidanceText.tracking(.limited(issue))
            #expect(message != nil && !message!.headline.isEmpty && message!.headline.hasSuffix("."))
        }
        #expect(ARGuidanceText.tracking(.normal) == nil)
        #expect(ARGuidanceText.tracking(.limited(.tooDark))?.headline == "It's too dark for me to see the floor.")
        #expect(ARGuidanceText.tracking(.interrupted) != nil)
    }
}
