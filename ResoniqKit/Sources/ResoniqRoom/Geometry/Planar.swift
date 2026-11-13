import Foundation

/// Plane geometry on plan points. Internal: the public questions are asked through `RoomGeometry`.
enum Planar {
    /// Two values closer than this are the same point, metres.
    static let epsilon = 1e-9

    static func closestPoint(on a: PlanPoint, _ b: PlanPoint, to p: PlanPoint) -> PlanPoint {
        let ab = b - a
        let lengthSquared = ab.dot(ab)
        guard lengthSquared > 0 else { return a }
        let t = min(max((p - a).dot(ab) / lengthSquared, 0), 1)
        return a + ab * t
    }

    static func distance(from p: PlanPoint, toSegment a: PlanPoint, _ b: PlanPoint) -> Double {
        p.distance(to: closestPoint(on: a, b, to: p))
    }

    /// Whether two closed segments touch or cross.
    static func segmentsIntersect(_ a: PlanPoint, _ b: PlanPoint, _ c: PlanPoint, _ d: PlanPoint) -> Bool {
        func orientation(_ p: PlanPoint, _ q: PlanPoint, _ r: PlanPoint) -> Double { (q - p).cross(r - p) }
        let o1 = orientation(a, b, c), o2 = orientation(a, b, d)
        let o3 = orientation(c, d, a), o4 = orientation(c, d, b)
        if ((o1 > epsilon && o2 < -epsilon) || (o1 < -epsilon && o2 > epsilon))
            && ((o3 > epsilon && o4 < -epsilon) || (o3 < -epsilon && o4 > epsilon)) {
            return true
        }
        return distance(from: c, toSegment: a, b) <= epsilon || distance(from: d, toSegment: a, b) <= epsilon
            || distance(from: a, toSegment: c, d) <= epsilon || distance(from: b, toSegment: c, d) <= epsilon
    }

    static func segmentDistance(_ a: PlanPoint, _ b: PlanPoint, _ c: PlanPoint, _ d: PlanPoint) -> Double {
        if segmentsIntersect(a, b, c, d) { return 0 }
        return min(
            distance(from: a, toSegment: c, d), distance(from: b, toSegment: c, d),
            distance(from: c, toSegment: a, b), distance(from: d, toSegment: a, b))
    }

    /// Even-odd point-in-polygon. A point within `edgeTolerance` of an edge counts as inside (RoomScan's
    /// `Geometry.containsXZ` policy).
    static func contains(_ p: PlanPoint, polygon: [PlanPoint], edgeTolerance: Double = 1e-6) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if distance(from: p, toSegment: a, b) <= edgeTolerance { return true }
            if (a.z > p.z) != (b.z > p.z) {
                let xAtZ = a.x + (p.z - a.z) / (b.z - a.z) * (b.x - a.x)
                if p.x < xAtZ { inside.toggle() }
            }
        }
        return inside
    }

    static func edges(of polygon: [PlanPoint]) -> [(PlanPoint, PlanPoint)] {
        guard polygon.count >= 2 else { return [] }
        return polygon.indices.map { (polygon[$0], polygon[($0 + 1) % polygon.count]) }
    }

    /// Distance between two polygons: 0 when they overlap or one holds the other.
    static func polygonDistance(_ p: [PlanPoint], _ q: [PlanPoint]) -> Double {
        if let first = p.first, contains(first, polygon: q) { return 0 }
        if let first = q.first, contains(first, polygon: p) { return 0 }
        var best = Double.infinity
        for (a, b) in edges(of: p) {
            for (c, d) in edges(of: q) { best = min(best, segmentDistance(a, b, c, d)) }
        }
        return best
    }

    /// Distance from a polygon to a segment: 0 when they touch or the segment lies inside.
    static func distance(fromPolygon p: [PlanPoint], toSegment a: PlanPoint, _ b: PlanPoint) -> Double {
        if contains(a, polygon: p) { return 0 }
        var best = Double.infinity
        for (c, d) in edges(of: p) { best = min(best, segmentDistance(a, b, c, d)) }
        return best
    }

    /// Distance along a ray from `origin` in unit `direction` to a segment, or nil when the ray misses it.
    static func rayDistance(from origin: PlanPoint, direction: PlanPoint, toSegment a: PlanPoint, _ b: PlanPoint)
        -> Double?
    {
        let edge = b - a
        let denominator = direction.cross(edge)
        guard abs(denominator) > epsilon else { return nil }
        let toStart = a - origin
        let t = toStart.cross(edge) / denominator
        let u = toStart.cross(direction) / denominator
        guard t > epsilon, u >= -epsilon, u <= 1 + epsilon else { return nil }
        return t
    }

    /// The centroid of a polygon's area, or the vertex mean when the area is zero.
    static func centroid(of polygon: [PlanPoint]) -> PlanPoint? {
        guard !polygon.isEmpty else { return nil }
        var area = 0.0, cx = 0.0, cz = 0.0
        for (a, b) in edges(of: polygon) {
            let c = a.cross(b)
            area += c
            cx += (a.x + b.x) * c
            cz += (a.z + b.z) * c
        }
        if abs(area) < epsilon {
            let sum = polygon.reduce(PlanPoint.zero, +)
            return sum * (1 / Double(polygon.count))
        }
        return PlanPoint(x: cx / (3 * area), z: cz / (3 * area))
    }
}
