import Foundation

/// The axis-aligned rectangle around a room on the plan.
public struct PlanRect: Sendable, Codable, Hashable {
    public var minX: Double
    public var maxX: Double
    public var minZ: Double
    public var maxZ: Double

    public init(minX: Double, maxX: Double, minZ: Double, maxZ: Double) {
        self.minX = minX
        self.maxX = maxX
        self.minZ = minZ
        self.maxZ = maxZ
    }

    /// The extent along x.
    public var width: Double { maxX - minX }
    /// The extent along z.
    public var length: Double { maxZ - minZ }
    public var centre: PlanPoint { PlanPoint(x: (minX + maxX) / 2, z: (minZ + maxZ) / 2) }

    public func contains(_ p: PlanPoint) -> Bool { p.x >= minX && p.x <= maxX && p.z >= minZ && p.z <= maxZ }
}

/// A room's size: the bounding rectangle's two sides and the ceiling height, metres.
public struct RoomDimensions: Sendable, Codable, Hashable {
    /// Along x.
    public var width: Double
    /// Along z.
    public var length: Double
    public var height: Double

    public init(width: Double, length: Double, height: Double) {
        self.width = width
        self.length = length
        self.height = height
    }

    /// The two plan sides, shorter first, as a room is described ("4.20 × 5.60 m").
    public var sortedSides: (shorter: Double, longer: Double) { (min(width, length), max(width, length)) }
}

/// How near a point is to a wall.
public struct WallDistance: Sendable, Equatable {
    public var wallID: UUID
    public var wallIndex: Int
    /// Metres, never negative.
    public var distance: Double
    /// The point on the wall nearest the point asked about.
    public var closestPoint: PlanPoint
    /// Whether the point asked about is inside the room.
    public var isInside: Bool
}

/// How much of the room's outline a scan has, for "3 of 4 walls".
public struct WallCoverage: Sendable, Equatable {
    public var captured: Int
    /// The walls a closed room needs at least: the captured ones plus one for each open chain, since one wall can
    /// close a chain. An estimate while scanning; exact once the outline is closed.
    public var expected: Int
    public var isClosed: Bool
}

/// Distances and sizes on the plan. Every answer comes from the model; nothing here knows about acoustics.
public enum RoomGeometry {
    /// Two wall ends closer than this are joined, metres. RoomScan's rule (`RoomLayoutRefinement.cornerJoinM`).
    public static let cornerJoin = 0.05

    // MARK: Outline and size

    /// The floor outline: the model's `floorOutline` when it has one, else the walls joined end to end when they
    /// close a loop, else empty.
    public static func outline(of room: RoomModel) -> [PlanPoint] {
        if room.floorOutline.count >= 3 { return room.floorOutline }
        return closedWallLoop(room.walls) ?? []
    }

    /// The rectangle around the outline and every wall end; nil for a room with neither.
    public static func bounds(of room: RoomModel) -> PlanRect? {
        let points = outline(of: room) + room.walls.flatMap { [$0.start, $0.end] }
        guard let first = points.first else { return nil }
        var rect = PlanRect(minX: first.x, maxX: first.x, minZ: first.z, maxZ: first.z)
        for p in points {
            rect.minX = min(rect.minX, p.x)
            rect.maxX = max(rect.maxX, p.x)
            rect.minZ = min(rect.minZ, p.z)
            rect.maxZ = max(rect.maxZ, p.z)
        }
        return rect
    }

    /// The ceiling height: the median wall height, or `RoomModel.defaultHeight` without walls.
    public static func height(of room: RoomModel) -> Double {
        let heights = room.walls.map(\.height).filter { $0.isFinite && $0 > 0 }.sorted()
        guard !heights.isEmpty else { return RoomModel.defaultHeight }
        let mid = heights.count / 2
        return heights.count.isMultiple(of: 2) ? (heights[mid - 1] + heights[mid]) / 2 : heights[mid]
    }

    public static func dimensions(of room: RoomModel) -> RoomDimensions? {
        guard let rect = bounds(of: room) else { return nil }
        return RoomDimensions(width: rect.width, length: rect.length, height: height(of: room))
    }

    public static func wallLengths(of room: RoomModel) -> [Double] { room.walls.map(\.length) }

    /// The area of the outline, square metres; 0 without one.
    public static func floorArea(of room: RoomModel) -> Double {
        let polygon = outline(of: room)
        guard polygon.count >= 3 else { return 0 }
        return abs(Planar.edges(of: polygon).reduce(0) { $0 + $1.0.cross($1.1) }) / 2
    }

    // MARK: Points

    /// Whether a point is inside the room. With no closed outline, inside the bounding rectangle.
    public static func contains(_ point: PlanPoint, in room: RoomModel) -> Bool {
        let polygon = outline(of: room)
        if polygon.count >= 3 { return Planar.contains(point, polygon: polygon) }
        return bounds(of: room)?.contains(point) ?? false
    }

    /// Whether a point can be shown to be inside the room: inside a closed outline. A room whose walls do not close a
    /// loop (a scan with walls missing) has only its bounding rectangle, which `contains` falls back to for editing;
    /// that is a guess, so nothing counts as shown to be inside it. The advisor suggests only such points.
    public static func isProvablyInside(_ point: PlanPoint, in room: RoomModel) -> Bool {
        let polygon = outline(of: room)
        guard polygon.count >= 3, point.isFinite else { return false }
        return Planar.contains(point, polygon: polygon)
    }

    /// The nearest wall to a point, inside the room or outside it; nil for a room without walls.
    public static func nearestWall(to point: PlanPoint, in room: RoomModel) -> WallDistance? {
        var best: WallDistance?
        for (index, wall) in room.walls.enumerated() {
            let closest = Planar.closestPoint(on: wall.start, wall.end, to: point)
            let distance = point.distance(to: closest)
            if best == nil || distance < best!.distance {
                best = WallDistance(
                    wallID: wall.id, wallIndex: index, distance: distance, closestPoint: closest, isInside: false)
            }
        }
        best?.isInside = contains(point, in: room)
        return best
    }

    /// The gap between a footprint and the nearest wall, metres: 0 when it touches or crosses a wall. Nil for a
    /// room without walls.
    public static func distanceToNearestWall(footprint: OrientedRect, in room: RoomModel) -> Double? {
        guard !room.walls.isEmpty else { return nil }
        let corners = footprint.corners
        return room.walls.map { Planar.distance(fromPolygon: corners, toSegment: $0.start, $0.end) }.min()
    }

    /// The wall first hit going from a point along a direction, and how far away it is; nil when nothing is hit.
    public static func wallAhead(of point: PlanPoint, direction: PlanPoint, in room: RoomModel) -> WallDistance? {
        let unit = direction.normalized
        guard unit != .zero else { return nil }
        var best: WallDistance?
        for (index, wall) in room.walls.enumerated() {
            guard let t = Planar.rayDistance(from: point, direction: unit, toSegment: wall.start, wall.end) else {
                continue
            }
            if best == nil || t < best!.distance {
                best = WallDistance(
                    wallID: wall.id, wallIndex: index, distance: t, closestPoint: point + unit * t, isInside: false)
            }
        }
        best?.isInside = contains(point, in: room)
        return best
    }

    /// A wall is behind a speaker when the way from the wall to the speaker is within this angle of the speaker's
    /// facing (60°): toe-in turns a speaker by up to about 45°, and the wall behind stays behind it.
    public static let behindCosine = 0.5

    /// The wall behind a speaker, with the perpendicular distance from the speaker's position to it: the distance a
    /// person measures with a tape and the one the boundary model uses.
    ///
    /// "Behind" is the wall whose nearest point lies most squarely behind the speaker's facing (the largest cosine
    /// between the facing and the way from that point to the speaker, at least `behindCosine`), so a toed-in speaker
    /// near a corner still reports the wall it backs onto, not the side wall its back ray happens to hit first.
    public static func wallBehind(_ speaker: PlacedSpeaker, in room: RoomModel) -> WallDistance? {
        wallBehind(position: speaker.position, facing: speaker.facing, in: room)
    }

    static func wallBehind(position: PlanPoint, facing: Double, in room: RoomModel) -> WallDistance? {
        let front = PlanPoint(angle: facing)
        var best: (cosine: Double, distance: WallDistance)?
        for (index, wall) in room.walls.enumerated() {
            let closest = Planar.closestPoint(on: wall.start, wall.end, to: position)
            let away = position - closest
            guard away.length > Planar.epsilon else { continue }
            let cosine = away.normalized.dot(front)
            guard cosine >= behindCosine else { continue }
            if let current = best,
                cosine < current.cosine - 1e-9
                    || (abs(cosine - current.cosine) <= 1e-9 && away.length >= current.distance.distance)
            {
                continue
            }
            best = (cosine, WallDistance(
                wallID: wall.id, wallIndex: index, distance: away.length, closestPoint: closest,
                isInside: contains(position, in: room)))
        }
        return best?.distance
    }

    // MARK: Walls captured

    /// Whether the walls close a loop, joined end to end within `cornerJoin`.
    public static func isClosed(_ room: RoomModel) -> Bool { coverage(of: room).isClosed }

    /// How many walls there are and how many a closed outline needs ("3 of 4 walls").
    public static func coverage(of room: RoomModel) -> WallCoverage {
        let walls = room.walls
        guard !walls.isEmpty else { return WallCoverage(captured: 0, expected: 0, isClosed: false) }
        // Union walls that share a joined end; a chain is open if any of its ends joins nothing.
        var parent = Array(walls.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { i = parent[i] }
            return i
        }
        var endJoined = Array(repeating: [false, false], count: walls.count)
        for i in walls.indices {
            for j in walls.indices where j != i {
                for (ei, e) in [walls[i].start, walls[i].end].enumerated()
                where [walls[j].start, walls[j].end].contains(where: { $0.distance(to: e) <= cornerJoin }) {
                    endJoined[i][ei] = true
                    parent[root(i)] = root(j)
                }
            }
        }
        var openChains = Set<Int>()
        for i in walls.indices where endJoined[i].contains(false) { openChains.insert(root(i)) }
        let chains = Set(walls.indices.map(root)).count
        return WallCoverage(
            captured: walls.count, expected: walls.count + openChains.count,
            isClosed: openChains.isEmpty && chains == 1)
    }

    /// The walls joined end to end into a polygon, when they form exactly one closed loop.
    static func closedWallLoop(_ walls: [Wall]) -> [PlanPoint]? {
        guard walls.count >= 3 else { return nil }
        var remaining = Array(walls.dropFirst())
        var points = [walls[0].start]
        var current = walls[0].end
        while !remaining.isEmpty {
            guard
                let next = remaining.firstIndex(where: {
                    $0.start.distance(to: current) <= cornerJoin || $0.end.distance(to: current) <= cornerJoin
                })
            else { return nil }
            let wall = remaining.remove(at: next)
            points.append(current)
            current = wall.start.distance(to: current) <= cornerJoin ? wall.end : wall.start
        }
        return current.distance(to: points[0]) <= cornerJoin ? points : nil
    }
}
