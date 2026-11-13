import Foundation
@testable import ResoniqRoom

/// Rooms the tests share. Every expected number in the tests is worked out by hand from these coordinates.
enum Fixtures {
    static func walls(around outline: [PlanPoint], height: Double = 2.4) -> [Wall] {
        outline.indices.map { Wall(start: outline[$0], end: outline[($0 + 1) % outline.count], height: height) }
    }

    /// The mockups' living room: 4.20 m along x, 5.60 m along z, 2.40 m high, centred on the origin.
    static var livingRoom: RoomModel { ManualRoom(width: 4.2, length: 5.6, height: 2.4).model()! }

    /// An L: a 5 × 6 m square with the 3 × 3 m corner at x > 2, z > 3 missing.
    static let lOutline = [
        PlanPoint(x: 0, z: 0), PlanPoint(x: 5, z: 0), PlanPoint(x: 5, z: 3),
        PlanPoint(x: 2, z: 3), PlanPoint(x: 2, z: 6), PlanPoint(x: 0, z: 6),
    ]

    static var lRoom: RoomModel {
        RoomModel(source: .scanned, walls: walls(around: lOutline), floorOutline: lOutline)
    }

    static let leftID = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
    static let rightID = UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!
    static let seatID = UUID(uuidString: "00000000-0000-4000-8000-00000000000C")!
    static let subID = UUID(uuidString: "00000000-0000-4000-8000-00000000000D")!

    /// The living room with a stereo pair 1.40 m from the back wall (z = −2.8), 2.0 m apart, and the seat at the
    /// apex of an equilateral triangle (√3 m from the speakers' line), every speaker pointed at the seat.
    static var stereoRoom: RoomModel {
        var room = livingRoom
        let seat = PlanPoint(x: 0, z: -1.4 + 3.0.squareRoot())
        let left = PlanPoint(x: -1, z: -1.4), right = PlanPoint(x: 1, z: -1.4)
        room.seats = [Seat(id: seatID, position: seat, isConfirmed: true)]
        room.speakers = [
            PlacedSpeaker(id: leftID, role: .left, position: left, facing: (seat - left).angle, isConfirmed: true),
            PlacedSpeaker(id: rightID, role: .right, position: right, facing: (seat - right).angle, isConfirmed: true),
        ]
        room.furniture = [
            Furniture(
                category: .sofa,
                footprint: OrientedRect(centre: PlanPoint(x: 0, z: 1.2), width: 2.0, depth: 0.9, heading: -.pi / 2)),
            Furniture(
                category: .table,
                footprint: OrientedRect(centre: PlanPoint(x: 1.6, z: -0.3), width: 0.6, depth: 0.6, heading: 0)),
        ]
        return room
    }
}

func isClose(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }
func isClose(_ a: PlanPoint, _ b: PlanPoint, _ tolerance: Double = 1e-9) -> Bool { a.distance(to: b) <= tolerance }
