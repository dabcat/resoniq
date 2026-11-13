import Foundation
import Testing
import ResoniqRoom

/// The RoomPlan conversion rules on primitive values (what `RoomPlanConverter` hands over after destructuring a
/// `CapturedRoom`), and the plain logic of the Scan screen. Without `@testable`: all of it is public.
@Suite struct ScanAssemblyTests {
    /// A rotation of `yaw` about +y as RoomPlan writes it, column-major, with a translation.
    static func transform(yaw: Double, x: Double, y: Double, z: Double) -> [Double] {
        let c = cos(yaw), s = sin(yaw)
        return [c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, x, y, z, 1]
    }

    static let back = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!
    static let right = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!
    static let front = UUID(uuidString: "00000000-0000-4000-8000-0000000000B3")!
    static let left = UUID(uuidString: "00000000-0000-4000-8000-0000000000B4")!

    static func wall(_ id: UUID, yaw: Double, x: Double, z: Double, width: Double,
                     confidence: RoomPlanMapping.Confidence = .high) -> RoomPlanMapping.SurfaceInput {
        RoomPlanMapping.SurfaceInput(
            id: id, kind: .wall, confidence: confidence, transform: transform(yaw: yaw, x: x, y: 1.2, z: z),
            width: width, height: 2.4)
    }

    /// The mockups' 4.20 × 5.60 m room as RoomPlan would report it, axis-aligned and centred on the origin: each
    /// wall's local x runs around the room (back +x, right +z, front −x, left −z), so the ends join.
    static let rectangle: [RoomPlanMapping.SurfaceInput] = [
        wall(back, yaw: 0, x: 0, z: -2.8, width: 4.2),
        wall(right, yaw: -.pi / 2, x: 2.1, z: 0, width: 5.6),
        wall(front, yaw: .pi, x: 0, z: 2.8, width: 4.2),
        wall(left, yaw: .pi / 2, x: -2.1, z: 0, width: 5.6),
    ]

    @Test func aRotatedWallFromAPlausibleScan() throws {
        // A back wall 4.20 m wide, turned 0.1 rad, its centre at (0.3, 1.2, −2.8): RoomPlan's local x is
        // (cos 0.1, 0, −sin 0.1), so the ends are the centre ± 2.1 m along (0.995004, −0.099833).
        let input = Self.wall(Self.back, yaw: 0.1, x: 0.3, z: -2.8, width: 4.2)
        let result = RoomPlanMapping.assemble(walls: [input])
        let wall = try #require(result.room.walls.first)
        #expect(wall.id == Self.back)
        #expect(isClose(wall.start, PlanPoint(x: -1.789509, z: -2.590350), 1e-6))
        #expect(isClose(wall.end, PlanPoint(x: 2.389509, z: -3.009650), 1e-6))
        #expect(wall.height == 2.4)
        #expect(result.room.source == .scanned)
        #expect(result.dropped.isEmpty)
    }

    @Test func fourWallsCloseTheRoom() {
        let room = RoomPlanMapping.assemble(walls: Self.rectangle).room
        let coverage = RoomGeometry.coverage(of: room)
        #expect(coverage.captured == 4)
        #expect(coverage.isClosed)
        let size = RoomGeometry.dimensions(of: room)
        #expect(size.map { isClose($0.width, 4.2, 1e-9) && isClose($0.length, 5.6, 1e-9) } == true)
    }

    @Test func openingsLandOnTheirWall() throws {
        let door = UUID(), window = UUID(), stray = UUID(), passage = UUID()
        let openings = [
            // On the right wall by its parent: 4.3 m from its start at (2.1, −2.8).
            RoomPlanMapping.SurfaceInput(
                id: door, parentID: Self.right, kind: .door, confidence: .high,
                transform: Self.transform(yaw: -.pi / 2, x: 2.1, y: 1.0, z: 1.5), width: 0.9, height: 2.0),
            // No parent: the nearest wall is the back wall, 1.6 m from its start at (−2.1, −2.8).
            RoomPlanMapping.SurfaceInput(
                id: window, kind: .window, confidence: .medium,
                transform: Self.transform(yaw: 0, x: -0.5, y: 1.4, z: -2.78), width: 1.2, height: 1.2),
            // A parent that is not among the walls: nearest again, the front wall (runs −x from (2.1, 2.8)).
            RoomPlanMapping.SurfaceInput(
                id: stray, parentID: UUID(), kind: .window, confidence: .low,
                transform: Self.transform(yaw: .pi, x: 1.0, y: 1.4, z: 2.75), width: 0.8, height: 1.0),
            // A doorless opening is kept as a door on the left wall.
            RoomPlanMapping.SurfaceInput(
                id: passage, parentID: Self.left, kind: .opening, confidence: .high,
                transform: Self.transform(yaw: .pi / 2, x: -2.1, y: 1.0, z: 0), width: 1.4, height: 2.1),
        ]
        let result = RoomPlanMapping.assemble(walls: Self.rectangle, openings: openings)
        func wall(_ id: UUID) -> Wall? { result.room.walls.first { $0.id == id } }

        let onRight = try #require(wall(Self.right)?.openings.first)
        #expect(onRight.id == door && onRight.kind == .door)
        #expect(isClose(onRight.offset, 4.3, 1e-9))
        #expect(onRight.width == 0.9)

        let onBack = try #require(wall(Self.back)?.openings.first)
        #expect(onBack.id == window && onBack.kind == .window)
        #expect(isClose(onBack.offset, 1.6, 1e-9))

        let onFront = try #require(wall(Self.front)?.openings.first)
        #expect(onFront.id == stray)
        #expect(isClose(onFront.offset, 1.1, 1e-9))

        let onLeft = try #require(wall(Self.left)?.openings.first)
        #expect(onLeft.id == passage && onLeft.kind == .door)
        #expect(isClose(onLeft.offset, 2.8, 1e-9))

        #expect(result.lowConfidence == [stray])
        #expect(result.dropped.isEmpty)
    }

    @Test func furnitureIsKeptLowConfidenceIsFlaggedAndBadValuesAreDropped() throws {
        let sofa = UUID(), chair = UUID(), fridge = UUID(), broken = UUID()
        let objects = [
            RoomPlanMapping.ObjectInput(
                id: sofa, categoryName: "sofa", confidence: .high,
                transform: Self.transform(yaw: .pi, x: 0, y: 0.4, z: 1.6), width: 2.1, height: 0.8, depth: 0.95),
            RoomPlanMapping.ObjectInput(
                id: chair, categoryName: "chair", confidence: .low,
                transform: Self.transform(yaw: 0, x: 1.4, y: 0.45, z: 0.5), width: 0.5, height: 0.9, depth: 0.5),
            RoomPlanMapping.ObjectInput(
                id: fridge, categoryName: "refrigerator", confidence: .medium,
                transform: Self.transform(yaw: 0, x: -1.7, y: 0.9, z: -2.4), width: 0.7, height: 1.8, depth: 0.7),
            RoomPlanMapping.ObjectInput(
                id: broken, categoryName: "table", confidence: .high,
                transform: Self.transform(yaw: 0, x: .nan, y: 0.4, z: 0), width: 1, height: 0.7, depth: 1),
        ]
        let zeroWidth = Self.wall(UUID(), yaw: 0, x: 0, z: 0, width: 0)
        let result = RoomPlanMapping.assemble(walls: Self.rectangle + [zeroWidth], objects: objects)

        #expect(result.room.walls.count == 4)
        #expect(result.room.furniture.map(\.id) == [sofa, chair, fridge])
        let couch = try #require(result.room.furniture.first)
        #expect(couch.category == .sofa)
        #expect(isClose(couch.footprint.centre, PlanPoint(x: 0, z: 1.6)))
        // Yaw π turns local +z to −z: the sofa's footprint heads along plan angle −π/2.
        #expect(isClose(PlanAngle.normalized(couch.footprint.heading), -.pi / 2, 1e-9))
        #expect(couch.footprint.width == 2.1 && couch.footprint.depth == 0.95 && couch.height == 0.8)
        #expect(result.room.furniture[2].category == .other)
        #expect(result.lowConfidence == [chair])
        #expect(Set(result.dropped) == [
            RoomPlanMapping.Dropped(id: broken, reason: .invalidGeometry),
            RoomPlanMapping.Dropped(id: zeroWidth.id, reason: .invalidGeometry),
        ])
    }

    @Test func anOpeningWithNoWallIsDropped() {
        let window = UUID()
        let result = RoomPlanMapping.assemble(
            walls: [],
            openings: [
                RoomPlanMapping.SurfaceInput(
                    id: window, kind: .window, confidence: .high,
                    transform: Self.transform(yaw: 0, x: 0, y: 1.4, z: -2.8), width: 1.2, height: 1.2)
            ])
        #expect(result.dropped == [RoomPlanMapping.Dropped(id: window, reason: .noWall)])
    }

    @Test func theLargestFloorPolygonBecomesTheOutline() {
        // RoomPlan's floor lies in its local x–y plane; this transform turns local y into world +z.
        let m: [Double] = [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1]
        let small = RoomPlanMapping.FloorInput(corners: [(x: 0, y: 0, z: 0), (x: 1, y: 0, z: 0), (x: 0, y: 1, z: 0)], transform: m)
        let room = RoomPlanMapping.FloorInput(
            corners: [(x: -2.1, y: -2.8, z: 0), (x: 2.1, y: -2.8, z: 0), (x: 2.1, y: 2.8, z: 0), (x: -2.1, y: 2.8, z: 0)],
            transform: m)
        let line = RoomPlanMapping.FloorInput(corners: [(x: 0, y: 0, z: 0), (x: 1, y: 0, z: 0)], transform: m)
        let result = RoomPlanMapping.assemble(walls: Self.rectangle, floors: [small, room, line])
        #expect(result.room.floorOutline == [
            PlanPoint(x: -2.1, z: -2.8), PlanPoint(x: 2.1, z: -2.8), PlanPoint(x: 2.1, z: 2.8), PlanPoint(x: -2.1, z: 2.8),
        ])
    }

    @Test func markersSitWhereTheLabelsGo() throws {
        let sofa = UUID(), window = UUID()
        let markers = RoomPlanMapping.markers(
            walls: [Self.rectangle[0]],
            openings: [
                RoomPlanMapping.SurfaceInput(
                    id: window, parentID: Self.back, kind: .window, confidence: .high,
                    transform: Self.transform(yaw: 0, x: -0.5, y: 1.4, z: -2.8), width: 1.2, height: 1.2)
            ],
            objects: [
                RoomPlanMapping.ObjectInput(
                    id: sofa, categoryName: "sofa", confidence: .high,
                    transform: Self.transform(yaw: 0, x: 0, y: 0.4, z: 1.6), width: 2.1, height: 0.8, depth: 0.95),
                RoomPlanMapping.ObjectInput(
                    id: UUID(), categoryName: "stove", confidence: .high,
                    transform: Self.transform(yaw: 0, x: 0, y: 0.4, z: 1.6), width: 1, height: 0.9, depth: 0.6),
            ])
        #expect(markers.count == 3, "a category the model does not keep gets no label")
        let wallMarker = try #require(markers.first { $0.id == Self.back })
        #expect(wallMarker.kind == .wall(length: 4.2))
        #expect(wallMarker.position == ScanMarker.Position(x: 0, y: 1.2, z: -2.8))
        let sofaMarker = try #require(markers.first { $0.id == sofa })
        #expect(sofaMarker.kind == .furniture(.sofa))
        #expect(isClose(sofaMarker.position.y, 0.8), "on top of the object")
        #expect(markers.first { $0.id == window }?.kind == .opening(.window))
    }
}

@Suite struct ScanProgressTests {
    @Test func aMissingWallJoinsTheFreeEnds() throws {
        // The rectangle without its left wall: the chain runs (−2.1, −2.8) … (−2.1, 2.8).
        let room = RoomPlanMapping.assemble(walls: Array(ScanAssemblyTests.rectangle.dropLast())).room
        let missing = ScanProgress.missingWalls(of: room)
        let gap = try #require(missing.first)
        #expect(missing.count == 1)
        let ends = Set([gap.start, gap.end].map { PlanPoint(x: ($0.x * 1e6).rounded() / 1e6, z: ($0.z * 1e6).rounded() / 1e6) })
        #expect(ends == [PlanPoint(x: -2.1, z: -2.8), PlanPoint(x: -2.1, z: 2.8)])
    }

    @Test func aClosedOrEmptyRoomMissesNothing() {
        #expect(ScanProgress.missingWalls(of: RoomPlanMapping.assemble(walls: ScanAssemblyTests.rectangle).room).isEmpty)
        #expect(ScanProgress.missingWalls(of: RoomModel(source: .scanned, walls: [])).isEmpty)
    }

    @Test func aSingleWallIsItsOwnChain() {
        let room = RoomPlanMapping.assemble(walls: [ScanAssemblyTests.rectangle[0]]).room
        // One wall cannot say where the room closes; there is nothing sensible to draw.
        #expect(ScanProgress.missingWalls(of: room).isEmpty)
    }

    @Test func cameraFacingOnTheInset() {
        // The inset's facing is degrees clockwise from up the plan (−z): −z is 0, +x is 90, +z is 180.
        #expect(isClose(ScanProgress.insetFacing(planAngle: -.pi / 2), 0, 1e-9))
        #expect(isClose(ScanProgress.insetFacing(planAngle: 0), 90, 1e-9))
        #expect(isClose(ScanProgress.insetFacing(planAngle: .pi / 2), 180, 1e-9))
        #expect(isClose(ScanProgress.insetFacing(planAngle: .pi), 270, 1e-9))
    }
}

@Suite struct ScanReadinessTests {
    @Test(arguments: [
        (true, CameraPermission.authorized, ScanReadiness.ready),
        (true, .notDetermined, .needsPermission),
        (true, .denied, .denied),
        (true, .restricted, .denied),
        (false, .authorized, .unsupported),
        (false, .notDetermined, .unsupported),
    ])
    func readiness(supported: Bool, camera: CameraPermission, expected: ScanReadiness) {
        #expect(ScanReadiness(isSupported: supported, camera: camera) == expected)
    }
}

@Suite struct ScanTextTests {
    static func coverage(_ walls: [RoomPlanMapping.SurfaceInput]) -> WallCoverage {
        RoomGeometry.coverage(of: RoomPlanMapping.assemble(walls: walls).room)
    }

    static let empty = coverage([])
    static let open = coverage(Array(ScanAssemblyTests.rectangle.dropLast()))
    static let closed = coverage(ScanAssemblyTests.rectangle)

    @Test func everyInstructionHasASentenceAndOnlyMovesHaveAnArrow() {
        for instruction in ScanInstruction.allCases {
            let guidance = ScanText.guidance(for: instruction, coverage: Self.open)
            #expect(!guidance.headline.isEmpty && !guidance.detail.isEmpty)
            #expect(guidance.headline.hasSuffix("."))
            #expect(!guidance.headline.contains("will"))
        }
        #expect(ScanText.guidance(for: .moveCloser, coverage: Self.open).direction == .forward)
        #expect(ScanText.guidance(for: .moveAway, coverage: Self.open).direction == .back)
        #expect(ScanText.guidance(for: .slowDown, coverage: Self.open).direction == nil)
        #expect(ScanText.guidance(for: .turnOnLight, coverage: Self.open).direction == nil)
    }

    @Test func normalGuidanceFollowsTheWalls() {
        let start = ScanText.guidance(for: .normal, coverage: Self.empty)
        let going = ScanText.guidance(for: .normal, coverage: Self.open)
        let done = ScanText.guidance(for: .normal, coverage: Self.closed)
        #expect(Set([start.headline, going.headline, done.headline]).count == 3)
        #expect(going.detail == "Walk slowly. Walls, doors and big furniture are picked up on their own.")
        #expect(done.direction == nil)
    }

    @Test func wallCountAndInsetSummary() {
        #expect(ScanText.wallCount(Self.empty) == "No walls yet")
        #expect(ScanText.wallCount(Self.open) == "3 of 4 walls")
        #expect(ScanText.wallCount(Self.coverage([ScanAssemblyTests.rectangle[0]])) == "1 of 2 walls")
        #expect(ScanText.insetSummary(Self.open) == "Floor plan: 3 of 4 walls captured.")
        #expect(ScanText.insetSummary(Self.closed) == "Floor plan: all 4 walls captured.")
        #expect(ScanText.insetSummary(Self.empty) == "Floor plan: no walls captured yet.")
    }

    @Test func labels() {
        #expect(ScanText.label(for: .wall(length: 4.2)) == "4.20 m")
        #expect(ScanText.label(for: .opening(.window)) == "Window")
        #expect(ScanText.label(for: .opening(.door)) == "Door")
        #expect(ScanText.label(for: .furniture(.sofa)) == "Sofa")
        #expect(ScanText.label(for: .furniture(.television)) == "TV")
        #expect(ScanText.label(for: .furniture(.other)) == nil)
    }

    @Test func everyFailureSaysWhatHappenedAndWhatToDo() {
        for failure in ScanFailure.allCases {
            #expect(!ScanText.failureHeadline(failure).isEmpty)
            #expect(ScanText.failureBody(failure).hasSuffix("."))
        }
        #expect(ScanText.failureHeadline(.worldTrackingFailure) != ScanText.failureHeadline(.deviceTooHot))
    }
}
