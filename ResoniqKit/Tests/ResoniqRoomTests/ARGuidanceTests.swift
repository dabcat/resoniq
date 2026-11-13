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

    /// The left speaker, the second mark: the middle of its front edge in the world.
    static var leftFront: PlanPoint {
        let left = sample.room.speaker(ARGuidanceSample.leftID)!
        return world.apply(ARGuidanceGeometry.frontEdgeCentre(of: left.pose, size: left.size))
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

    /// Both marks: the speaker's front edge (where the reticle is), then the left speaker's front.
    static func markBoth(_ state: inout ARGuidanceState, secondAt second: PlanPoint? = nil) {
        _ = state.apply(.marked)
        _ = state.apply(.reticleMoved(FloorHit(point: second ?? leftFront, height: -1.2)))
        _ = state.apply(.marked)
    }

    /// Ready to mark, then both marks: the target is drawn.
    static func marked() -> ARGuidanceState {
        var state = readyToMark()
        markBoth(&state)
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
        // The second mark is the other speaker of the pair.
        #expect(state.reference?.kind == .speaker(.left))
        _ = state.apply(.trackingRecovered)
        _ = state.apply(.floorFound)
        #expect(state.phase == .markingSpeaker)
        // No reticle on the floor yet: nothing to mark.
        #expect(!state.canMark)
        _ = state.apply(.cameraMoved(Move.camera))
        _ = state.apply(.reticleMoved(Move.frontEdge(ofCentre: Move.start.position, facing: Move.start.facing)))
        #expect(state.canMark)
        _ = state.apply(.marked)
        // One mark draws nothing: the second point comes first.
        #expect(state.phase == .markingReference)
        #expect(state.target == nil && state.progress == nil && !state.canFollow)
        _ = state.apply(.reticleMoved(FloorHit(point: Move.leftFront, height: -1.2)))
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
        let placement = try #require(state.placement)
        #expect(placed == [.placed(placement)])
        #expect(state.phase == .placed(placement))
        // Where the speaker was last pointed at (1 cm short), not the plan's target; within the tolerance.
        #expect(isClose(placement.distanceFromTarget, 0.01, 1e-9))
        #expect(!placement.isApproximate)
        #expect(isClose(placement.pose.facing, Move.suggestion.to.facing, 1e-12))
        // Finished: nothing more happens.
        #expect(state.apply(.decline).isEmpty)
        #expect(state.phase == .placed(placement))
    }

    @Test func stoppingShortIsRecordedAsApproximate() throws {
        var state = Move.marked()
        _ = state.apply(.follow(true))
        _ = Move.follow(&state, to: 0.33)
        // 2 cm short is in position; "It's in place" hands back that spot, 2 cm from the target.
        #expect(state.canConfirm)
        _ = state.apply(.confirm)
        let close = try #require(state.placement)
        #expect(isClose(close.distanceFromTarget, 0.02, 1e-9) && !close.isApproximate)

        // The plan's speaker 6 cm off where it really stands: the marks still agree (the residual is small), the
        // target follows the marked speaker, and the stored spot is where the person marked it, recorded as
        // approximate because it is not the suggested one.
        var shifted = Move.readyToMark()
        let edge = Move.frontEdge(ofCentre: Move.start.position, facing: Move.start.facing).point
        // 12 cm along the baseline, away from the other speaker: the fit's residual is 6 cm (under the limit), and
        // the fit puts the marked speaker 6 cm from the plan's.
        let offset = (Move.leftFront - edge).normalized * -0.12
        _ = shifted.apply(.reticleMoved(Move.frontEdge(ofCentre: Move.start.position + offset, facing: Move.start.facing)))
        Move.markBoth(&shifted)
        #expect(shifted.phase == .sliding)
        _ = shifted.apply(.follow(true))
        let target = try #require(shifted.target)
        _ = shifted.apply(.reticleMoved(Move.frontEdge(ofCentre: target.position, facing: Move.start.facing)))
        _ = shifted.apply(.confirm)
        let placement = try #require(shifted.placement)
        #expect(placement.isApproximate)
        #expect(placement.distanceFromTarget > MoveGuidance.positionTolerance)
    }

    @Test func aMoveWithoutATurnArrives() throws {
        let sample = ARGuidanceSample.rightSpeaker(turnDegrees: 0)
        var state = ARGuidanceState(suggestion: sample.suggestion, room: sample.room)
        _ = state.apply(.trackingRecovered)
        _ = state.apply(.floorFound)
        let start = sample.suggestion.from
        _ = state.apply(.cameraMoved(Viewer(position: .zero, heading: start.facing + .pi)))
        _ = state.apply(.reticleMoved(Move.frontEdge(ofCentre: start.position, facing: start.facing)))
        _ = state.apply(.marked)
        let left = try #require(sample.room.speaker(ARGuidanceSample.leftID))
        let leftFront = ARGuidanceGeometry.frontEdgeCentre(of: left.pose, size: left.size)
        _ = state.apply(.reticleMoved(FloorHit(point: leftFront, height: 0)))
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

        var sliding = Move.marked()
        #expect(sliding.apply(.decline) == [.declined])
        #expect(sliding.phase == .declined)
        #expect(sliding.placedPose == nil)
    }

    @Test func trackingLostAndRecoveredMidSlide() throws {
        var state = Move.marked()
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

    @Test func marksThatDisagreeStopTheGuideAndMarkingAgainStartsOver() throws {
        var state = Move.readyToMark()
        // The second mark 60 cm beyond where the plan has the left speaker: the marks do not agree, no target.
        let first = Move.frontEdge(ofCentre: Move.start.position, facing: Move.start.facing).point
        let outward = (Move.leftFront - first).normalized
        Move.markBoth(&state, secondAt: Move.leftFront + outward * 0.6)
        guard case .cannotAlign(.marksDisagree(let residual)) = state.phase else {
            Issue.record("marks 60 cm off the plan should not align, got \(state.phase)")
            return
        }
        #expect(residual > WorldAlignment.maximumResidual)
        #expect(state.target == nil && !state.canFollow && !state.canConfirm && !state.canMark)
        _ = state.apply(.remark)
        #expect(state.phase == .markingSpeaker)
        #expect(state.alignment == nil && state.speaker == nil && state.speakerMark == nil && state.referenceMark == nil)
        _ = state.apply(.reticleMoved(Move.frontEdge(ofCentre: Move.start.position, facing: Move.start.facing)))
        Move.markBoth(&state)
        let target = try #require(state.target)
        #expect(target.position.distance(to: Move.world.apply(Move.suggestion.to.position)) < 1e-9)
    }

    @Test func leavingThePositionGoesBackToSliding() {
        var state = Move.marked()
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

    @Test func withNothingElseToMarkNoTargetIsShown() {
        var room = Move.sample.room
        room.speakers.removeAll { $0.id == ARGuidanceSample.leftID }
        room.seats = []
        var state = ARGuidanceState(suggestion: Move.suggestion, room: room)
        #expect(state.reference == nil)
        _ = state.apply(.trackingRecovered)
        _ = state.apply(.floorFound)
        _ = state.apply(.reticleMoved(Move.frontEdge(ofCentre: Move.start.position, facing: Move.start.facing)))
        _ = state.apply(.marked)
        #expect(state.phase == .cannotAlign(.nothingElseToMark))
        #expect(state.target == nil)
    }

    @Test func tooDarkIsReadFromTheLight() {
        #expect(ARTrackingIssue.insufficientFeatures(ambientIntensity: 30) == .tooDark)
        #expect(ARTrackingIssue.insufficientFeatures(ambientIntensity: 900) == .insufficientFeatures)
        #expect(ARTrackingIssue.insufficientFeatures(ambientIntensity: nil) == .insufficientFeatures)
    }
}

@Suite struct ARReferenceTests {
    @Test func thePairPartnerThenTheSeatThenASubwoofer() throws {
        let sample = ARGuidanceSample.rightSpeaker()
        #expect(ARReference.choose(for: sample.suggestion, in: sample.room)?.kind == .speaker(.left))

        var noPartner = sample.room
        noPartner.speakers.removeAll { $0.id == ARGuidanceSample.leftID }
        let seat = try #require(ARReference.choose(for: sample.suggestion, in: noPartner))
        #expect(seat.kind == .seat)
        #expect(seat.modelPoint == noPartner.primarySeat?.position)

        // A subwoofer far enough away is the last resort.
        var subOnly = noPartner
        subOnly.seats = []
        subOnly.speakers.append(PlacedSpeaker(role: .subwoofer, position: PlanPoint(x: -1.5, z: -2.3), facing: .pi / 2, isConfirmed: true))
        #expect(ARReference.choose(for: sample.suggestion, in: subOnly)?.kind == .speaker(.subwoofer))
    }

    @Test func aPointTooCloseToTheSpeakerIsNotUsed() {
        let sample = ARGuidanceSample.rightSpeaker()
        var room = sample.room
        room.speakers.removeAll { $0.id == ARGuidanceSample.leftID }
        // The only seat 30 cm in front of the speaker: too short a baseline.
        let from = sample.suggestion.from
        room.seats = [Seat(position: from.position + PlanPoint(angle: from.facing) * 0.3, isConfirmed: true)]
        #expect(ARReference.choose(for: sample.suggestion, in: room) == nil)
    }
}

@Suite struct ARGuidanceAlignmentTests {
    @Test func twoMarksMapTheModelTargetIntoTheWorldAndBack() throws {
        let state = Move.marked()
        let alignment = try #require(state.alignment)
        #expect(isClose(alignment.rotation, Move.world.rotation, 1e-9))
        #expect(isClose(alignment.translation, Move.world.translation, 1e-9))
        #expect(alignment.residual < 1e-9)
        let target = try #require(state.target)
        #expect(isClose(target.position, Move.world.apply(Move.suggestion.to.position), 1e-9))
        #expect(isClose(alignment.inverse.apply(target.position), Move.suggestion.to.position, 1e-9))
        #expect(isClose(PlanAngle.difference(from: alignment.inverse.apply(heading: target.facing),
                                             to: Move.suggestion.to.facing), 0, 1e-9))
        let speaker = try #require(state.speaker)
        #expect(isClose(speaker.position, Move.start.position, 1e-9))
    }

    /// The finding: one mark and the camera's heading put a 35 cm target 12 cm off for a 20° heading error. With two
    /// marks the camera's heading is not used for the alignment at all; with each mark 1.5 cm off as well (a person
    /// is not exact), the target stays within a few centimetres.
    @Test(arguments: [20.0, 30.0, -20.0])
    func aHeadingErrorWithTwoMarksKeepsTheTargetClose(degrees: Double) throws {
        var state = Move.readyToMark()
        var camera = Move.camera
        camera.heading += PlanAngle.radians(degrees)
        _ = state.apply(.cameraMoved(camera))
        // Each mark 1.5 cm off, in opposite directions across the baseline: the worst case for the rotation.
        let first = Move.frontEdge(ofCentre: Move.start.position, facing: Move.start.facing)
        let across = (Move.leftFront - first.point).normalized.rightHand * 0.015
        _ = state.apply(.reticleMoved(FloorHit(point: first.point + across, height: first.height)))
        Move.markBoth(&state, secondAt: Move.leftFront - across)
        #expect(state.phase == .sliding)
        let target = try #require(state.target)
        let truth = Move.world.apply(Move.suggestion.to.position)
        #expect(target.position.distance(to: truth) < 0.025)
        // The fitted rotation is within a degree of the truth.
        let rotationError = PlanAngle.difference(from: Move.world.rotation, to: try #require(state.alignment).rotation)
        #expect(abs(rotationError) < PlanAngle.radians(1))
    }

    @Test func theTargetFollowsTheMarkedSpeakerNotTheFitsAverage() throws {
        // The room's pair 10 cm wider than the plan's: the fit splits that between the marks (a residual of 5 cm;
        // 10 cm, a pair 20 cm off, would stop the guide), and the target stays the slide from where the speaker was
        // marked.
        var state = Move.readyToMark()
        let first = Move.frontEdge(ofCentre: Move.start.position, facing: Move.start.facing).point
        let outward = (Move.leftFront - first).normalized
        Move.markBoth(&state, secondAt: Move.leftFront + outward * 0.1)
        #expect(state.phase == .sliding)
        let alignment = try #require(state.alignment)
        #expect(isClose(alignment.residual, 0.05, 1e-6))
        let start = try #require(state.markedStart)
        let target = try #require(state.target)
        #expect(isClose(target.position.distance(to: start.position), 0.35, 1e-9))
        #expect(isClose(start.position, Move.start.position, 1e-9))
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
        var state = Move.marked()
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
        var state = Move.marked()
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
