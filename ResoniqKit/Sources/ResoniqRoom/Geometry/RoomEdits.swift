import Foundation

/// Where a speaker or seat may stand: the one set of rules every edit, the layout guess and the advisor share.
public enum PlacementRules {
    /// The smallest gap between a speaker's footprint and a wall, metres. A first guess: room for the cable.
    public static let speakerWallClearance = 0.05
    /// The smallest gap between a speaker's footprint and furniture or another speaker, metres. A first guess.
    public static let speakerFurnitureClearance = 0.05
    /// The smallest distance from a seat to a wall, metres: the listener's head is not in the wall. A first guess.
    public static let seatWallClearance = 0.20
    /// Furniture a speaker may stand on or overlap: speakers often sit on a cabinet or a shelf, which RoomPlan
    /// reports as storage.
    public static let furnitureSpeakersMayStandOn: Set<Furniture.Category> = [.storage]
    /// How far an edit looks for the nearest allowed spot before falling back to stopping short, metres.
    public static let clampSearchRadius = 1.5
    /// The step of that search, metres.
    public static let clampSearchStep = 0.01

    /// Whether a speaker footprint may stand here: inside the outline, clear of every wall by
    /// `speakerWallClearance`, of furniture (except `furnitureSpeakersMayStandOn`) and of other speakers by
    /// `speakerFurnitureClearance`. Seats do not block speakers.
    public static func allows(speakerFootprint footprint: OrientedRect, ignoring id: UUID?, in room: RoomModel)
        -> Bool
    {
        let corners = footprint.corners
        guard corners.allSatisfy({ $0.isFinite && RoomGeometry.contains($0, in: room) }) else { return false }
        for wall in room.walls
        where Planar.distance(fromPolygon: corners, toSegment: wall.start, wall.end) < speakerWallClearance {
            return false
        }
        for item in room.furniture where !furnitureSpeakersMayStandOn.contains(item.category) {
            if Planar.polygonDistance(corners, item.footprint.corners) < speakerFurnitureClearance { return false }
        }
        for other in room.speakers where other.id != id {
            if Planar.polygonDistance(corners, other.footprint.corners) < speakerFurnitureClearance { return false }
        }
        return true
    }

    /// Whether a seat may be here: inside the room and `seatWallClearance` from every wall. A seat may be on a sofa
    /// or a chair, so furniture does not block it.
    public static func allows(seatAt point: PlanPoint, in room: RoomModel) -> Bool {
        guard point.isFinite, RoomGeometry.contains(point, in: room) else { return false }
        return room.walls.allSatisfy {
            Planar.distance(from: point, toSegment: $0.start, $0.end) >= seatWallClearance
        }
    }
}

/// The result of an edit: the new room, and whether the request had to be changed to keep the rules.
public struct RoomEdit: Sendable, Equatable {
    public var room: RoomModel
    /// True when the item ended somewhere other than asked, or the edit was refused (an unknown id, a spot with no
    /// allowed place near it).
    public var wasClamped: Bool
}

extension RoomModel {
    /// Moves a speaker or a seat to a point, or to the nearest allowed point when that one breaks
    /// `PlacementRules`.
    public func moving(_ id: UUID, to point: PlanPoint) -> RoomEdit {
        var room = self
        if let index = speakers.firstIndex(where: { $0.id == id }) {
            let speaker = speakers[index]
            guard
                let placed = nearestAllowed(
                    to: point, from: speaker.position,
                    allows: { PlacementRules.allows(speakerFootprint: speaker.footprint.moved(to: $0), ignoring: id, in: self) })
            else { return RoomEdit(room: self, wasClamped: true) }
            room.speakers[index].position = placed
            return RoomEdit(room: room, wasClamped: placed != point)
        }
        if let index = seats.firstIndex(where: { $0.id == id }) {
            guard
                let placed = nearestAllowed(
                    to: point, from: seats[index].position,
                    allows: { PlacementRules.allows(seatAt: $0, in: self) })
            else { return RoomEdit(room: self, wasClamped: true) }
            room.seats[index].position = placed
            return RoomEdit(room: room, wasClamped: placed != point)
        }
        return RoomEdit(room: self, wasClamped: true)
    }

    /// Turns a speaker to face a plan angle. A turn that would push the footprint into a wall or furniture moves
    /// the speaker to the nearest allowed point as well.
    public func rotating(_ id: UUID, to facing: Double) -> RoomEdit {
        guard let index = speakers.firstIndex(where: { $0.id == id }), facing.isFinite else {
            return RoomEdit(room: self, wasClamped: true)
        }
        var turned = self
        turned.speakers[index].facing = PlanAngle.normalized(facing)
        let speaker = turned.speakers[index]
        if PlacementRules.allows(speakerFootprint: speaker.footprint, ignoring: id, in: turned) {
            return RoomEdit(room: turned, wasClamped: false)
        }
        guard
            let placed = turned.nearestAllowed(
                to: speaker.position, from: nil,
                allows: { PlacementRules.allows(speakerFootprint: speaker.footprint.moved(to: $0), ignoring: id, in: turned) })
        else { return RoomEdit(room: self, wasClamped: true) }
        turned.speakers[index].position = placed
        return RoomEdit(room: turned, wasClamped: true)
    }

    /// Adds a speaker, at the nearest allowed point to where it was asked for.
    public func adding(_ speaker: PlacedSpeaker) -> RoomEdit {
        var room = self
        room.speakers.removeAll { $0.id == speaker.id }
        guard
            let placed = room.nearestAllowed(
                to: speaker.position, from: nil,
                allows: { PlacementRules.allows(speakerFootprint: speaker.footprint.moved(to: $0), ignoring: speaker.id, in: room) })
        else { return RoomEdit(room: self, wasClamped: true) }
        var added = speaker
        added.position = placed
        room.speakers.append(added)
        return RoomEdit(room: room, wasClamped: placed != speaker.position)
    }

    /// Adds a seat, at the nearest allowed point to where it was asked for.
    public func adding(_ seat: Seat) -> RoomEdit {
        var room = self
        room.seats.removeAll { $0.id == seat.id }
        guard
            let placed = room.nearestAllowed(
                to: seat.position, from: nil, allows: { PlacementRules.allows(seatAt: $0, in: room) })
        else { return RoomEdit(room: self, wasClamped: true) }
        var added = seat
        added.position = placed
        room.seats.append(added)
        return RoomEdit(room: room, wasClamped: placed != seat.position)
    }

    /// Removes a speaker or a seat; `wasClamped` is true when no item has the id.
    public func removing(_ id: UUID) -> RoomEdit {
        var room = self
        room.speakers.removeAll { $0.id == id }
        room.seats.removeAll { $0.id == id }
        let removed = room.speakers.count != speakers.count || room.seats.count != seats.count
        return RoomEdit(room: room, wasClamped: !removed)
    }

    /// The allowed point nearest `target`: the target itself, else the nearest on rings of growing radius out to
    /// `PlacementRules.clampSearchRadius` (around the target, or around the nearest point of the walls for a target
    /// outside the room), else the farthest allowed point on the way from `origin` to the target
    /// (stopping short, as a dragged speaker stops at a wall). Nil when nothing is allowed.
    func nearestAllowed(to target: PlanPoint, from origin: PlanPoint?, allows: (PlanPoint) -> Bool) -> PlanPoint? {
        guard target.isFinite else { return nil }
        if allows(target) { return target }
        // A point outside the room is searched for from the nearest point of the walls.
        let centre = RoomGeometry.contains(target, in: self)
            ? target : (RoomGeometry.nearestWall(to: target, in: self)?.closestPoint ?? target)
        let step = PlacementRules.clampSearchStep
        var radius = step
        while radius <= PlacementRules.clampSearchRadius + 1e-9 {
            let count = max(8, Int((2 * .pi * radius / step).rounded()))
            var best: PlanPoint?
            for k in 0..<count {
                let p = centre + PlanPoint(angle: 2 * .pi * Double(k) / Double(count)) * radius
                if allows(p) {
                    best = p
                    break
                }
            }
            if let best { return best }
            radius += step
        }
        guard let origin, allows(origin) else { return nil }
        var low = 0.0, high = 1.0
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if allows(origin + (target - origin) * mid) { low = mid } else { high = mid }
        }
        return origin + (target - origin) * low
    }
}
