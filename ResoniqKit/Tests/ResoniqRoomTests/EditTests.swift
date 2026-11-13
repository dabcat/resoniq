import Foundation
import Testing
@testable import ResoniqRoom

@Suite struct EditTests {
    @Test func aMoveIntoTheWallStopsAtTheClearance() throws {
        let room = Fixtures.stereoRoom
        let edit = room.moving(Fixtures.rightID, to: PlanPoint(x: 1, z: -3.5))
        #expect(edit.wasClamped)
        let moved = try #require(edit.room.speaker(Fixtures.rightID))
        let gap = try #require(RoomGeometry.distanceToNearestWall(footprint: moved.footprint, in: edit.room))
        #expect(gap >= PlacementRules.speakerWallClearance - 1e-9)
        #expect(gap <= PlacementRules.speakerWallClearance + PlacementRules.clampSearchStep + 0.01)
        #expect(RoomGeometry.contains(moved.position, in: room))
    }

    @Test func anAllowedMoveIsExact() throws {
        let edit = Fixtures.stereoRoom.moving(Fixtures.leftID, to: PlanPoint(x: -1, z: -1.0))
        #expect(!edit.wasClamped)
        #expect(edit.room.speaker(Fixtures.leftID)?.position == PlanPoint(x: -1, z: -1.0))
    }

    @Test func aSpeakerIsKeptOffFurniture() throws {
        let room = Fixtures.stereoRoom
        let table = room.furniture[1].footprint
        let edit = room.moving(Fixtures.rightID, to: table.centre)
        #expect(edit.wasClamped)
        let moved = try #require(edit.room.speaker(Fixtures.rightID))
        #expect(Planar.polygonDistance(moved.footprint.corners, table.corners)
            >= PlacementRules.speakerFurnitureClearance - 1e-9)
    }

    @Test func aSeatMayBeOnASofaButNotInAWall() throws {
        let room = Fixtures.stereoRoom
        let onSofa = room.moving(Fixtures.seatID, to: PlanPoint(x: 0, z: 1.2))
        #expect(!onSofa.wasClamped)
        let inWall = room.moving(Fixtures.seatID, to: PlanPoint(x: 0, z: 2.8))
        #expect(inWall.wasClamped)
        let seat = try #require(inWall.room.seat(Fixtures.seatID))
        #expect(try #require(RoomGeometry.nearestWall(to: seat.position, in: room)).distance
            >= PlacementRules.seatWallClearance - 1e-9)
    }

    @Test func aTurnIntoTheWallMovesTheSpeakerOut() throws {
        // A deep speaker against the right wall, facing along the wall; turning it to face the wall needs room.
        var room = Fixtures.livingRoom
        let id = UUID()
        room.speakers = [
            PlacedSpeaker(
                id: id, role: .single, position: PlanPoint(x: 1.9, z: 0), facing: .pi / 2,
                size: FootprintSize(width: 0.2, depth: 0.5), isConfirmed: true)
        ]
        let edit = room.rotating(id, to: 0)
        #expect(edit.wasClamped)
        let turned = try #require(edit.room.speaker(id))
        #expect(isClose(turned.facing, 0))
        #expect(PlacementRules.allows(speakerFootprint: turned.footprint, ignoring: id, in: edit.room))
    }

    @Test func addAndRemove() throws {
        let room = Fixtures.stereoRoom
        let sub = PlacedSpeaker(role: .subwoofer, position: PlanPoint(x: 5, z: 0), facing: 0, isConfirmed: true)
        let added = room.adding(sub)
        #expect(added.wasClamped)
        let placed = try #require(added.room.speaker(sub.id))
        #expect(PlacementRules.allows(speakerFootprint: placed.footprint, ignoring: sub.id, in: added.room))
        let removed = added.room.removing(sub.id)
        #expect(!removed.wasClamped && removed.room.speakers.count == 2)
        #expect(room.removing(UUID()).wasClamped)
        let seat = Seat(position: PlanPoint(x: 0.5, z: 0.5), isConfirmed: true)
        let withSeat = room.adding(seat)
        #expect(!withSeat.wasClamped && withSeat.room.seats.count == 2)
    }
}
