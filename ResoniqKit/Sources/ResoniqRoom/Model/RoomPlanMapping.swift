import Foundation

/// The primitive-typed helpers the RoomPlan converter calls, so the conversion rules are tested on the Mac without
/// RoomPlan (the RoomScan pattern: `SurfaceMapping`).
///
/// A transform is RoomPlan's 4×4 as 16 numbers in column-major order (`columns.0.x, .y, .z, .w, columns.1.x, …`),
/// widened to `Double`. Its translation (column 3) is the centre of the geometry, not a corner; `dimensions` are
/// local `(x, y, z)`, a wall's being `(width, height, thickness)` and possibly zero.
public enum RoomPlanMapping {
    /// The plan position of a transform's translation.
    public static func centre(of transform: [Double]) -> PlanPoint {
        precondition(transform.count == 16, "a transform is 16 numbers, column-major")
        return PlanPoint(x: transform[12], z: transform[14])
    }

    /// The plan direction of a transform's local x axis (column 0, projected onto x–z).
    public static func localX(of transform: [Double]) -> PlanPoint {
        precondition(transform.count == 16, "a transform is 16 numbers, column-major")
        return PlanPoint(x: transform[0], z: transform[2]).normalized
    }

    /// The plan direction of a transform's local z axis (column 2, projected onto x–z).
    public static func localZ(of transform: [Double]) -> PlanPoint {
        precondition(transform.count == 16, "a transform is 16 numbers, column-major")
        return PlanPoint(x: transform[8], z: transform[10]).normalized
    }

    /// A wall from its transform and dimensions: the segment runs along the local x axis through the centre, `width`
    /// long; `height` is the y dimension. Nil when a value is not finite or the width is zero.
    public static func wall(id: UUID, transform: [Double], width: Double, height: Double,
                            openings: [Opening] = []) -> Wall? {
        let centre = centre(of: transform), axis = localX(of: transform)
        guard centre.isFinite, axis != .zero, width.isFinite, width > 0, height.isFinite else { return nil }
        let half = axis * (width / 2)
        return Wall(id: id, start: centre - half, end: centre + half, height: height, openings: openings)
    }

    /// A door or window placed on its wall: its centre projected onto the wall gives the offset from the wall's
    /// start. Nil for a non-finite transform or width.
    public static func opening(id: UUID, kind: Opening.Kind, transform: [Double], width: Double, on wall: Wall)
        -> Opening?
    {
        let centre = centre(of: transform)
        guard centre.isFinite, width.isFinite, width >= 0 else { return nil }
        let offset = (centre - wall.start).dot(wall.direction)
        return Opening(id: id, kind: kind, offset: min(max(offset, 0), wall.length), width: width)
    }

    /// A piece of furniture: the footprint's heading is the local +z axis, `width` the x dimension and `depth` the
    /// z dimension. Whether RoomPlan's +z is an object's front is not established (RoomScan never needed it), so
    /// `LayoutGuess` does not rely on it. Nil for non-finite values.
    public static func furniture(id: UUID, categoryName: String, transform: [Double], width: Double, height: Double,
                                 depth: Double) -> Furniture? {
        let centre = centre(of: transform), heading = localZ(of: transform)
        guard centre.isFinite, heading != .zero, width.isFinite, depth.isFinite, height.isFinite else { return nil }
        let footprint = OrientedRect(centre: centre, width: width, depth: depth, heading: heading.angle)
        return Furniture(id: id, category: category(named: categoryName), footprint: footprint, height: height)
    }

    /// RoomPlan's object category by its case name (`"sofa"`, `"television"`, `"storage"`); anything this model does
    /// not keep, and any name it does not know, is `.other`.
    public static func category(named name: String) -> Furniture.Category {
        Furniture.Category(rawValue: name.lowercased()) ?? .other
    }

    /// A floor polygon's corners carried through the floor's transform onto the plan. RoomPlan's polygon corners are
    /// in the surface's own plane (local x–y, z = 0) and must go through the transform first (RoomScan pitfall 12).
    public static func floorOutline(corners: [(x: Double, y: Double, z: Double)], transform: [Double]) -> [PlanPoint] {
        precondition(transform.count == 16, "a transform is 16 numbers, column-major")
        let m = transform
        return corners.map { c in
            PlanPoint(
                x: m[0] * c.x + m[4] * c.y + m[8] * c.z + m[12],
                z: m[2] * c.x + m[6] * c.y + m[10] * c.z + m[14])
        }.filter(\.isFinite)
    }
}

extension RoomModel {
    /// The model carried through a rigid plan transform: every point, footprint and facing. For putting a scan in a
    /// room-anchored frame, or drawing it in the AR world.
    public func applying(_ alignment: WorldAlignment) -> RoomModel {
        var room = self
        room.walls = walls.map {
            var wall = $0
            wall.start = alignment.apply($0.start)
            wall.end = alignment.apply($0.end)
            return wall
        }
        room.floorOutline = floorOutline.map(alignment.apply)
        room.furniture = furniture.map {
            var item = $0
            item.footprint.centre = alignment.apply($0.footprint.centre)
            item.footprint.heading = alignment.apply(heading: $0.footprint.heading)
            return item
        }
        room.speakers = speakers.map {
            var speaker = $0
            speaker.position = alignment.apply($0.position)
            speaker.facing = alignment.apply(heading: $0.facing)
            return speaker
        }
        room.seats = seats.map {
            var seat = $0
            seat.position = alignment.apply($0.position)
            return seat
        }
        return room
    }
}
