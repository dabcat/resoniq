import Foundation
import Testing
@testable import ResoniqRoom

@Suite struct LayoutMatchTests {
    @Test func theSameLayoutMatchesWhateverElseChanged() {
        let room = Fixtures.stereoRoom
        #expect(LayoutMatch.matches(room, room))
        // Confirmation, furniture and walls are not where the speakers are.
        var edited = room
        edited.speakers[0].isConfirmed = false
        edited.furniture = []
        edited.walls.removeLast()
        #expect(LayoutMatch.matches(room, edited))
    }

    @Test func aSpeakerOrSeatMovedBeyondTheToleranceDoesNotMatch() {
        let room = Fixtures.stereoRoom
        var nudged = room
        nudged.speakers[1].position.x += LayoutMatch.positionTolerance * 0.9
        #expect(LayoutMatch.matches(room, nudged))
        var moved = room
        moved.speakers[1].position.x += LayoutMatch.positionTolerance * 1.5
        #expect(!LayoutMatch.matches(room, moved))
        var turned = room
        turned.speakers[0].facing += LayoutMatch.facingTolerance * 1.5
        #expect(!LayoutMatch.matches(room, turned))
        var seat = room
        seat.seats[0].position.z += 0.1
        #expect(!LayoutMatch.matches(room, seat))
    }

    @Test func differentItemsDoNotMatch() {
        let room = Fixtures.stereoRoom
        // A rescan guesses new speakers with new ids, even in the same places.
        var rescanned = room
        rescanned.speakers = room.speakers.map {
            PlacedSpeaker(role: $0.role, position: $0.position, facing: $0.facing, isConfirmed: true)
        }
        #expect(!LayoutMatch.matches(room, rescanned))
        var added = room
        added.speakers.append(PlacedSpeaker(role: .subwoofer, position: PlanPoint(x: 0, z: -2.4), facing: .pi / 2, isConfirmed: true))
        #expect(!LayoutMatch.matches(room, added))
        #expect(!LayoutMatch.matches(added, room))
    }
}
