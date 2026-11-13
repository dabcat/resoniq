import Foundation
import Testing
@testable import ResoniqRoom

@Suite struct MoveGuidanceTests {
    let target = MoveGuidance.Target(
        start: PlanPose(position: PlanPoint(x: 1, z: -1.4), facing: 0),
        end: PlanPose(position: PlanPoint(x: 1, z: -1.05), facing: 0.2))

    @Test func halfwayAndTheViewersDirection() {
        let current = PlanPose(position: PlanPoint(x: 1, z: -1.22), facing: 0)
        // The viewer stands beyond the target looking back at the speaker (−z): the speaker comes toward them.
        let viewer = Viewer(position: PlanPoint(x: 1, z: 0), heading: -.pi / 2)
        let progress = MoveGuidance.progress(current: current, target: target, viewer: viewer)
        #expect(isClose(progress.distanceToGo, 0.17, 1e-12))
        #expect(isClose(progress.totalDistance, 0.35, 1e-12))
        #expect(isClose(progress.fractionDone, 1 - 0.17 / 0.35, 1e-12))
        #expect(progress.direction == .towardYou)
        #expect(isClose(abs(progress.bearing), .pi, 1e-12))
        #expect(isClose(progress.turnRemaining, 0.2, 1e-12))
        #expect(!progress.hasArrived)
        #expect(RoomText.slideInstruction(progress.direction!) == "Slide it toward you until it fills the blue outline.")
        #expect(RoomText.moveParts(progress.distanceToGo) == ("17", "cm"))
    }

    @Test func sideways() {
        // Looking along +x, a move toward +z is to the viewer's right.
        let viewer = Viewer(position: .zero, heading: 0)
        let current = PlanPose(position: PlanPoint(x: 1, z: -1.4), facing: 0)
        #expect(MoveGuidance.progress(current: current, target: target, viewer: viewer).direction == .right)
    }

    @Test func arrivalNeedsPositionAndTurn() {
        let viewer = Viewer(position: .zero, heading: 0)
        let near = PlanPose(position: PlanPoint(x: 1.02, z: -1.05), facing: 0)
        let slid = MoveGuidance.progress(current: near, target: target, viewer: viewer)
        #expect(slid.isInPosition && !slid.hasArrived && slid.direction == nil)
        let turned = PlanPose(position: near.position, facing: 0.2 - MoveGuidance.angleTolerance / 2)
        #expect(MoveGuidance.progress(current: turned, target: target, viewer: viewer).hasArrived)
        let short = PlanPose(position: PlanPoint(x: 1, z: -1.05 - 0.04), facing: 0.2)
        #expect(!MoveGuidance.progress(current: short, target: target, viewer: viewer).isInPosition)
        // Overshooting does not make the fraction negative or above one.
        let past = PlanPose(position: PlanPoint(x: 1, z: 0), facing: 0.2)
        let fraction = MoveGuidance.progress(current: past, target: target, viewer: viewer).fractionDone
        #expect(fraction >= 0 && fraction <= 1)
    }

    @Test func tapsSpeedUpAsTheSpeakerNears() throws {
        #expect(MoveGuidance.hapticInterval(distance: 0.02) == nil)
        #expect(MoveGuidance.hapticInterval(distance: 1.5) == nil)
        #expect(MoveGuidance.hapticInterval(distance: .nan) == nil)
        let distances = stride(from: 0.04, through: 1.0, by: 0.02).map { $0 }
        let intervals = try distances.map { try #require(MoveGuidance.hapticInterval(distance: $0)) }
        #expect(zip(intervals, intervals.dropFirst()).allSatisfy { $0 < $1 })
        #expect(isClose(try #require(MoveGuidance.hapticInterval(distance: MoveGuidance.hapticRange)),
                        MoveGuidance.slowestHapticInterval, 1e-12))
        #expect(intervals[0] >= MoveGuidance.fastestHapticInterval)
    }
}

@Suite struct WorldAlignmentTests {
    let rotation = 0.7
    let translation = PlanPoint(x: 2.5, z: -1.2)
    let model = [PlanPoint(x: 0, z: 0), PlanPoint(x: 1, z: 0), PlanPoint(x: 0.3, z: 2), PlanPoint(x: -1, z: 1.5)]

    var world: [PlanPoint] { model.map { $0.rotated(by: rotation) + translation } }

    @Test func recoversAKnownTransformFromTwoAndMorePoints() throws {
        let two = try #require(WorldAlignment.fit(model: Array(model.prefix(2)), world: Array(world.prefix(2))))
        #expect(isClose(two.rotation, rotation, 1e-12) && isClose(two.translation, translation, 1e-12))
        let all = try #require(WorldAlignment.fit(model: model, world: world))
        #expect(isClose(all.rotation, rotation, 1e-12) && isClose(all.translation, translation, 1e-12))
        #expect(all.residual < 1e-12 && all.isConsistent)
        for (m, w) in zip(model, world) {
            #expect(isClose(all.apply(m), w, 1e-12))
            #expect(isClose(all.inverse.apply(w), m, 1e-12))
        }
        #expect(isClose(all.apply(heading: 0.1), 0.8, 1e-12))
    }

    @Test func onePointAndAHeading() {
        let alignment = WorldAlignment(
            modelPoint: model[2], worldPoint: world[2], modelHeading: 0.4, worldHeading: 0.4 + rotation)
        #expect(isClose(alignment.rotation, rotation, 1e-12))
        #expect(isClose(alignment.translation, translation, 1e-12))
        #expect(alignment.residual == 0)
    }

    @Test func inconsistentPointsShowALargeResidual() throws {
        var wrong = world
        wrong[3] = wrong[3] + PlanPoint(x: 1.2, z: 0.4)
        let fit = try #require(WorldAlignment.fit(model: model, world: wrong))
        #expect(fit.residual > WorldAlignment.maximumResidual)
        #expect(!fit.isConsistent)
        // Small noise stays consistent.
        let noisy = world.enumerated().map { $1 + PlanPoint(x: $0.isMultiple(of: 2) ? 0.01 : -0.01, z: 0.01) }
        #expect(try #require(WorldAlignment.fit(model: model, world: noisy)).isConsistent)
    }

    @Test func degenerateInput() {
        #expect(WorldAlignment.fit(model: [.zero], world: [.zero]) == nil)
        #expect(WorldAlignment.fit(model: [.zero, .zero], world: [.zero, PlanPoint(x: 1, z: 0)]) == nil)
    }

    @Test func aRoomCarriedThroughTheTransform() throws {
        let room = Fixtures.stereoRoom
        let alignment = WorldAlignment(rotation: rotation, translation: translation)
        let moved = room.applying(alignment)
        let back = moved.applying(alignment.inverse)
        #expect(isClose(back.speakers[1].position, room.speakers[1].position, 1e-12))
        #expect(isClose(PlanAngle.difference(from: back.speakers[1].facing, to: room.speakers[1].facing), 0, 1e-12))
        let a = try #require(ListeningGeometry(room: room)), b = try #require(ListeningGeometry(room: moved))
        #expect(isClose(a.subtendedAngle, b.subtendedAngle, 1e-12))
    }
}
