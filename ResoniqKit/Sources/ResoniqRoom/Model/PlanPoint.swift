import Foundation

/// A point or a vector on the floor plan, in metres.
///
/// The plan is the x–z plane of ARKit and RoomPlan, seen from above with y up (right-handed, metres). `x` and `z`
/// are the world's x and z; height is never part of a plan point.
public struct PlanPoint: Sendable, Codable, Hashable {
    public var x: Double
    public var z: Double

    public init(x: Double, z: Double) {
        self.x = x
        self.z = z
    }

    public static let zero = PlanPoint(x: 0, z: 0)

    /// The unit vector of a plan angle (see `PlanAngle`).
    public init(angle: Double) {
        self.init(x: cos(angle), z: sin(angle))
    }

    public var length: Double { hypot(x, z) }

    /// The plan angle of this vector, `atan2(z, x)`.
    public var angle: Double { atan2(z, x) }

    /// The vector scaled to length 1, or `.zero` for the zero vector.
    public var normalized: PlanPoint {
        let l = length
        return l > 0 ? PlanPoint(x: x / l, z: z / l) : .zero
    }

    /// The direction 90° to the right of this one for a person facing along it, seen from above with y up.
    ///
    /// A camera facing −z (ARKit's forward) has +x on its right, so the right of `(x, z)` is `(−z, x)`.
    public var rightHand: PlanPoint { PlanPoint(x: -z, z: x) }

    public func dot(_ other: PlanPoint) -> Double { x * other.x + z * other.z }

    /// The z component of the 3D cross product `self × other` taken in (x, z): positive when `other` lies at a
    /// positive plan angle from `self`.
    public func cross(_ other: PlanPoint) -> Double { x * other.z - z * other.x }

    public func distance(to other: PlanPoint) -> Double { (self - other).length }

    /// Rotated by a plan angle about the origin.
    public func rotated(by angle: Double) -> PlanPoint {
        let c = cos(angle), s = sin(angle)
        return PlanPoint(x: x * c - z * s, z: x * s + z * c)
    }

    public var isFinite: Bool { x.isFinite && z.isFinite }

    public static func + (a: PlanPoint, b: PlanPoint) -> PlanPoint { PlanPoint(x: a.x + b.x, z: a.z + b.z) }
    public static func - (a: PlanPoint, b: PlanPoint) -> PlanPoint { PlanPoint(x: a.x - b.x, z: a.z - b.z) }
    public static func * (a: PlanPoint, s: Double) -> PlanPoint { PlanPoint(x: a.x * s, z: a.z * s) }
    public static func * (s: Double, a: PlanPoint) -> PlanPoint { a * s }
    public static prefix func - (a: PlanPoint) -> PlanPoint { PlanPoint(x: -a.x, z: -a.z) }
}

/// Plan angles: radians in the x–z plane, `atan2(z, x)`, so 0 points along +x and π/2 along +z.
///
/// Seen from above with y up, a positive plan angle turns from +x toward +z, which is clockwise. ARKit's yaw
/// (rotation about +y) runs the other way: a plan angle is `−yaw` of the direction it names. Nothing user-facing
/// depends on the sense of rotation; turns are described as "toward your seat".
public enum PlanAngle {
    /// The angle wrapped to −π…π.
    public static func normalized(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a <= -.pi { a += 2 * .pi }
        return a
    }

    /// The signed turn from `from` to `to`, −π…π.
    public static func difference(from: Double, to: Double) -> Double { normalized(to - from) }

    public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
}

/// A position and the direction something faces, on the plan.
public struct PlanPose: Sendable, Codable, Hashable {
    public var position: PlanPoint
    /// A plan angle (`PlanAngle`).
    public var facing: Double

    public init(position: PlanPoint, facing: Double) {
        self.position = position
        self.facing = facing
    }
}

/// A rectangle on the plan that may be turned: a footprint.
///
/// `heading` is the plan angle of the rectangle's front. `depth` runs along the heading and `width` across it, so a
/// sofa 2 m wide and 0.9 m deep facing +z has `heading == π/2`, `width == 2`, `depth == 0.9`.
public struct OrientedRect: Sendable, Codable, Hashable {
    public var centre: PlanPoint
    public var width: Double
    public var depth: Double
    public var heading: Double

    public init(centre: PlanPoint, width: Double, depth: Double, heading: Double) {
        self.centre = centre
        self.width = width
        self.depth = depth
        self.heading = heading
    }

    public var area: Double { width * depth }

    /// The four corners in order around the rectangle: front-right, front-left, back-left, back-right.
    public var corners: [PlanPoint] {
        let front = PlanPoint(angle: heading) * (depth / 2)
        let side = PlanPoint(angle: heading).rightHand * (width / 2)
        return [centre + front + side, centre + front - side, centre - front - side, centre - front + side]
    }

    /// The same footprint moved to a new centre.
    public func moved(to centre: PlanPoint) -> OrientedRect {
        OrientedRect(centre: centre, width: width, depth: depth, heading: heading)
    }
}
