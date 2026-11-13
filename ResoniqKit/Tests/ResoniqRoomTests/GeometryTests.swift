import Foundation
import Testing
@testable import ResoniqRoom

@Suite struct PlanPointTests {
    @Test func rightHandOfARKitForwardIsPlusX() {
        // ARKit's camera looks along −z and has +x on its right.
        #expect(isClose(PlanPoint(x: 0, z: -1).rightHand, PlanPoint(x: 1, z: 0)))
    }

    @Test func anglesWrapAndRotate() {
        #expect(isClose(PlanAngle.normalized(3 * .pi), .pi))
        #expect(isClose(PlanAngle.difference(from: .pi - 0.1, to: -.pi + 0.1), 0.2))
        #expect(isClose(PlanPoint(x: 1, z: 0).rotated(by: .pi / 2), PlanPoint(x: 0, z: 1)))
        #expect(isClose(PlanPoint(angle: .pi / 2).angle, .pi / 2))
    }

    @Test func footprintCornersSitAtHalfWidthAndDepth() {
        let rect = OrientedRect(centre: PlanPoint(x: 1, z: 1), width: 2, depth: 1, heading: 0)
        let xs = rect.corners.map(\.x).sorted(), zs = rect.corners.map(\.z).sorted()
        #expect(isClose(xs.first!, 0.5) && isClose(xs.last!, 1.5))
        #expect(isClose(zs.first!, 0) && isClose(zs.last!, 2))
    }
}

@Suite struct ManualRoomTests {
    @Test func rectangleHasFourWallsAndTheDimensions() throws {
        let room = try #require(ManualRoom(width: 4.2, length: 5.6, height: 2.5).model())
        #expect(room.source == .manual)
        #expect(room.walls.count == 4)
        #expect(room.walls.map(\.length).map { ($0 * 100).rounded() / 100 } == [4.2, 5.6, 4.2, 5.6])
        let dimensions = try #require(RoomGeometry.dimensions(of: room))
        #expect(isClose(dimensions.width, 4.2) && isClose(dimensions.length, 5.6) && isClose(dimensions.height, 2.5))
        #expect(RoomGeometry.isClosed(room))
        #expect(isClose(RoomGeometry.floorArea(of: room), 4.2 * 5.6, 1e-9))
    }

    @Test(arguments: [
        (1.0, 5.0, 2.4, [ManualRoom.Issue.widthOutOfRange]),
        (4.0, 25.0, 2.4, [.lengthOutOfRange]),
        (4.0, 5.0, 1.2, [.heightOutOfRange]),
        (.nan, 5.0, .infinity, [.widthOutOfRange, .heightOutOfRange]),
        (1.5, 20.0, 6.0, []),
    ])
    func validation(width: Double, length: Double, height: Double, issues: [ManualRoom.Issue]) {
        let room = ManualRoom(width: width, length: length, height: height)
        #expect(room.issues == issues)
        #expect((room.model() == nil) == !issues.isEmpty)
    }

    @Test func issuesHaveText() {
        #expect(RoomText.manualIssue(.widthOutOfRange) == "The width should be between 1.5 and 20.0 m. Is it in metres?")
    }
}

@Suite struct RoomGeometryTests {
    @Test func rectangleContainmentAndNearestWall() throws {
        let room = Fixtures.livingRoom
        #expect(RoomGeometry.contains(PlanPoint(x: 0, z: 0), in: room))
        #expect(!RoomGeometry.contains(PlanPoint(x: 2.2, z: 0), in: room))
        // (1.5, −2.0): 0.6 m from the right wall (x = 2.1), 0.8 m from the back wall (z = −2.8).
        let near = try #require(RoomGeometry.nearestWall(to: PlanPoint(x: 1.5, z: -2.0), in: room))
        #expect(near.wallIndex == 1 && isClose(near.distance, 0.6) && near.isInside)
        #expect(isClose(near.closestPoint, PlanPoint(x: 2.1, z: -2.0)))
        // Outside: 0.5 m beyond the front wall.
        let outside = try #require(RoomGeometry.nearestWall(to: PlanPoint(x: 0, z: 3.3), in: room))
        #expect(outside.wallIndex == 2 && isClose(outside.distance, 0.5) && !outside.isInside)
    }

    @Test func lShapeContainmentAndDistances() throws {
        let room = Fixtures.lRoom
        #expect(RoomGeometry.contains(PlanPoint(x: 1, z: 5), in: room))
        #expect(RoomGeometry.contains(PlanPoint(x: 4, z: 1), in: room))
        // The missing corner is outside, though inside the bounding rectangle.
        #expect(!RoomGeometry.contains(PlanPoint(x: 4, z: 5), in: room))
        #expect(try #require(RoomGeometry.bounds(of: room)).contains(PlanPoint(x: 4, z: 5)))
        // (3, 4) is outside; the inner corner's walls are 1 m away (x = 2 and z = 3).
        let outside = try #require(RoomGeometry.nearestWall(to: PlanPoint(x: 3, z: 4), in: room))
        #expect(isClose(outside.distance, 1) && !outside.isInside)
        // (2.5, 2.6): 0.4 m below the inner wall z = 3.
        let inside = try #require(RoomGeometry.nearestWall(to: PlanPoint(x: 2.5, z: 2.6), in: room))
        #expect(inside.wallIndex == 2 && isClose(inside.distance, 0.4, 1e-12) && inside.isInside)
        #expect(isClose(RoomGeometry.floorArea(of: room), 21))
        #expect(RoomGeometry.wallLengths(of: room) == [5, 3, 3, 3, 2, 6])
        #expect(RoomGeometry.isClosed(room))
    }

    @Test func footprintToWallDistance() throws {
        let room = Fixtures.livingRoom
        // A 0.25 × 0.30 m footprint facing +z with its centre 0.5 m from the back wall: the back edge is 0.35 m away.
        let footprint = OrientedRect(centre: PlanPoint(x: 0, z: -2.3), width: 0.25, depth: 0.3, heading: .pi / 2)
        #expect(isClose(try #require(RoomGeometry.distanceToNearestWall(footprint: footprint, in: room)), 0.35, 1e-12))
        let crossing = footprint.moved(to: PlanPoint(x: 0, z: -2.75))
        #expect(try #require(RoomGeometry.distanceToNearestWall(footprint: crossing, in: room)) == 0)
    }

    @Test func wallBehindASpeakerIsMeasuredSquare() throws {
        let room = Fixtures.stereoRoom
        let right = try #require(room.speaker(role: .right))
        let behind = try #require(RoomGeometry.wallBehind(right, in: room))
        #expect(behind.wallIndex == 0 && isClose(behind.distance, 1.4, 1e-12))
    }

    @Test func wallCoverageDuringAScan() {
        // Three walls of the living room, the front one still missing: "3 of 4 walls".
        var room = Fixtures.livingRoom
        room.walls.remove(at: 2)
        room.floorOutline = []
        let coverage = RoomGeometry.coverage(of: room)
        #expect(coverage == WallCoverage(captured: 3, expected: 4, isClosed: false))
        #expect(RoomText.wallsCaptured(coverage) == "3 of 4 walls")
        #expect(RoomGeometry.outline(of: room).isEmpty)
        // A closed loop of walls stands in for a missing floor polygon.
        var walled = Fixtures.lRoom
        walled.floorOutline = []
        #expect(RoomGeometry.outline(of: walled).count == 6)
        #expect(RoomGeometry.contains(PlanPoint(x: 1, z: 5), in: walled))
        #expect(!RoomGeometry.contains(PlanPoint(x: 4, z: 5), in: walled))
    }

    @Test func sizesInTheProductsStyle() throws {
        let dimensions = try #require(RoomGeometry.dimensions(of: Fixtures.livingRoom))
        #expect(RoomText.dimensions(dimensions) == "4.20 × 5.60 m")
        #expect(RoomText.roomTitle(name: "Living room", dimensions: dimensions) == "Living room · 4.20 × 5.60 m")
        #expect(RoomText.metres(0.9) == "0.90 m")
        #expect(RoomText.metres(4.2) == "4.20 m")
        #expect(RoomText.move(0.35) == "35 cm")
        #expect(RoomText.move(1.2) == "1.20 m")
        #expect(RoomText.moveParts(0.18) == ("18", "cm"))
        #expect(RoomText.degrees(PlanAngle.radians(-12.2)) == "12°")
        #expect(RoomText.frequency(61.25) == "61 Hz")
        #expect(RoomText.problemLabel(AcousticProblem(frequency: 61, deviation: -11, kind: .dip)) == "61 Hz −11 dB")
    }
}
