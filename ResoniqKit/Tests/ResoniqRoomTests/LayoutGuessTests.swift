import Foundation
import Testing
@testable import ResoniqRoom

@Suite struct LayoutGuessTests {
    func check(_ room: RoomModel) throws -> (seat: Seat, left: PlacedSpeaker, right: PlacedSpeaker) {
        let guessed = LayoutGuess.place(in: room)
        #expect(LayoutGuess.place(in: room) == guessed)
        let seat = try #require(guessed.seats.first)
        let left = try #require(guessed.speaker(role: .left)), right = try #require(guessed.speaker(role: .right))
        #expect(!seat.isConfirmed && !left.isConfirmed && !right.isConfirmed)
        #expect(PlacementRules.allows(seatAt: seat.position, in: guessed))
        for speaker in [left, right] {
            #expect(PlacementRules.allows(speakerFootprint: speaker.footprint, ignoring: speaker.id, in: guessed))
            #expect(ListeningGeometry.toeInError(of: speaker, toward: seat.position) < 1e-9)
        }
        return (seat, left, right)
    }

    @Test func emptyRectangleGivesAnEvenPairAlongTheLongSide() throws {
        let (seat, left, right) = try check(Fixtures.livingRoom)
        #expect(isClose(seat.position, .zero))
        // Faces −z (the long side, ties to −z): the wall is 2.8 m ahead, the pair 0.6 m out from it.
        #expect(isClose(left.position.z, -2.2, 1e-9) && isClose(right.position.z, -2.2, 1e-9))
        #expect(isClose(left.position.x, -right.position.x, 1e-9))
        // Seen facing −z, the listener's left is −x.
        #expect(left.position.x < 0)
        let geometry = ListeningGeometry(seat: seat.position, left: left, right: right)
        #expect(isClose(geometry.subtendedAngle, .pi / 3, 1e-9))
    }

    @Test func seatOnTheLargestSofaFacingTheOpenRoom() throws {
        var room = Fixtures.livingRoom
        room.furniture = [
            Furniture(category: .sofa, footprint: OrientedRect(centre: PlanPoint(x: 1.5, z: 0), width: 1, depth: 0.8, heading: 0)),
            // Against the front wall, its reported heading toward the wall: the guess faces the room instead.
            Furniture(category: .sofa, footprint: OrientedRect(centre: PlanPoint(x: 0, z: 2.2), width: 2.2, depth: 0.9, heading: .pi / 2)),
        ]
        let (seat, left, right) = try check(room)
        #expect(isClose(seat.position, PlanPoint(x: 0, z: 2.2)))
        #expect(left.position.z < seat.position.z && right.position.z < seat.position.z)
        // Facing −z the pair sits 0.6 m from the back wall.
        #expect(isClose(left.position.z, -2.2, 1e-9))
        // Facing −z, left is −x.
        #expect(left.position.x < right.position.x)
    }

    @Test func pairFlanksATelevision() throws {
        var room = Fixtures.livingRoom
        room.furniture = [
            Furniture(category: .sofa, footprint: OrientedRect(centre: PlanPoint(x: 0, z: 2.0), width: 2, depth: 0.9, heading: -.pi / 2)),
            Furniture(category: .television, footprint: OrientedRect(centre: PlanPoint(x: 0.3, z: -2.6), width: 1.4, depth: 0.1, heading: .pi / 2)),
        ]
        let (seat, left, right) = try check(room)
        let tv = room.furniture[1].footprint
        // Symmetric about the line from the seat to the television, each clear of it.
        let axis = (tv.centre - seat.position).normalized
        #expect(isClose((left.position - seat.position).dot(axis), (right.position - seat.position).dot(axis), 1e-9))
        #expect(isClose(left.position.distance(to: tv.centre), right.position.distance(to: tv.centre), 1e-9))
        #expect(left.position.distance(to: right.position) >= tv.width + PlacedSpeaker.defaultSize.width)
    }

    @Test func lShapedRoomWithoutFurniture() throws {
        let (seat, left, right) = try check(Fixtures.lRoom)
        // The bounding centre (2.5, 3) is on the inner corner; the seat moves to the nearest allowed point.
        #expect(RoomGeometry.contains(seat.position, in: Fixtures.lRoom))
        #expect(seat.position.distance(to: PlanPoint(x: 2.5, z: 3)) < 0.5)
        #expect(left.id == LayoutGuess.leftID && right.id == LayoutGuess.rightID)
    }

    @Test func confirmedItemsAreKept() {
        let room = Fixtures.stereoRoom
        #expect(LayoutGuess.place(in: room) == room)
    }
}
