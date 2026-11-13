import Foundation
import Testing
import ResoniqRoom

/// Without `@testable`: the model, its initialisers and its encoding are public.
@Suite struct ModelCodingTests {
    @Test func fullModelRoundTrips() throws {
        var room = Fixtures.stereoRoom
        room.source = .scanned
        room.walls[0].openings = [
            Opening(kind: .window, offset: 2.1, width: 1.2), Opening(kind: .door, offset: 0.6, width: 0.8),
        ]
        room.furniture.append(
            Furniture(category: .television, footprint: OrientedRect(centre: PlanPoint(x: 0, z: -2.7), width: 1.2, depth: 0.08, heading: .pi / 2), height: 1.1))
        room.speakers.append(
            PlacedSpeaker(role: .subwoofer, position: PlanPoint(x: -1.8, z: -2.5), facing: .pi / 2, isConfirmed: false))
        let data = try JSONEncoder().encode(room)
        let decoded = try JSONDecoder().decode(RoomModel.self, from: data)
        #expect(decoded == room)
        #expect(decoded.schemaVersion == RoomModel.currentSchemaVersion)
        #expect(decoded.speakers.last?.size == PlacedSpeaker.defaultSubwooferSize)
    }

    @Test func adviceRoundTrips() throws {
        let advice = PlacementAdvisor.advice(
            room: Fixtures.stereoRoom, problems: [AcousticProblem(frequency: 61, deviation: 11, kind: .dip)])
        let decoded = try JSONDecoder().decode(PlacementAdvice.self, from: JSONEncoder().encode(advice))
        #expect(decoded == advice)
    }
}

@Suite struct RoomPlanMappingTests {
    /// A rotation of `angle` about +y as RoomPlan writes it, column-major, with a translation.
    func transform(yaw: Double, x: Double, y: Double, z: Double) -> [Double] {
        let c = cos(yaw), s = sin(yaw)
        // Rotation about +y: x axis → (c, 0, −s), z axis → (s, 0, c).
        return [c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, x, y, z, 1]
    }

    @Test func aWallRunsAlongItsLocalXThroughItsCentre() throws {
        // Yaw 90° turns local x to −z (plan angle −90°).
        let wall = try #require(
            RoomPlanMapping.wall(id: UUID(), transform: transform(yaw: .pi / 2, x: 2, y: 1.25, z: 0), width: 4, height: 2.5))
        #expect(isClose(wall.start, PlanPoint(x: 2, z: 2), 1e-12))
        #expect(isClose(wall.end, PlanPoint(x: 2, z: -2), 1e-12))
        #expect(wall.height == 2.5)
        let window = try #require(
            RoomPlanMapping.opening(id: UUID(), kind: .window, transform: transform(yaw: .pi / 2, x: 2, y: 1.4, z: 1), width: 1, on: wall))
        #expect(isClose(window.offset, 1, 1e-12))
        #expect(RoomPlanMapping.wall(id: UUID(), transform: transform(yaw: 0, x: .nan, y: 0, z: 0), width: 4, height: 2.5) == nil)
    }

    @Test func furnitureAndCategories() throws {
        let sofa = try #require(
            RoomPlanMapping.furniture(id: UUID(), categoryName: "sofa", transform: transform(yaw: 0, x: 1, y: 0.4, z: 2), width: 2, height: 0.8, depth: 0.9))
        #expect(sofa.category == .sofa)
        #expect(isClose(sofa.footprint.centre, PlanPoint(x: 1, z: 2)))
        #expect(isClose(sofa.footprint.heading, .pi / 2, 1e-12))
        #expect(RoomPlanMapping.category(named: "television") == .television)
        #expect(RoomPlanMapping.category(named: "refrigerator") == .other)
    }

    @Test func floorCornersGoThroughTheTransform() {
        // A floor's polygon is in its local x–y plane; RoomPlan's floor turns local y to world z (pitch −90°).
        let m: [Double] = [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0.5, 0, -0.5, 1]
        let outline = RoomPlanMapping.floorOutline(corners: [(x: 1, y: 2, z: 0)], transform: m)
        #expect(outline == [PlanPoint(x: 1.5, z: 1.5)])
    }
}
