import Foundation

/// The rigid transform in the floor plane that takes room-model coordinates to AR world coordinates: a rotation
/// about y, then a translation. `world = rotate(model, by: rotation) + translation`.
///
/// RoomScan's lesson (docs/reference/iosar-roomplan-arkit.md, "Relocalization"): keep positions in the room's own
/// frame and convert with one transform at session start, never store raw world coordinates. Matching points comes
/// from the person (they point at the speaker and confirm it); this type only does the arithmetic and says how well
/// the points agree.
public struct WorldAlignment: Sendable, Codable, Hashable {
    /// A fit whose root-mean-square residual is above this does not match the room, metres. A first guess: a
    /// footprint marked on the floor is good to a few centimetres, a wrong speaker is off by a metre.
    public static let maximumResidual = 0.10

    /// Plan angle (`PlanAngle`); ARKit's yaw of the same rotation is `−rotation`.
    public var rotation: Double
    public var translation: PlanPoint
    /// Root-mean-square distance, metres, between the matched world points and the model points carried over. 0 when
    /// the transform was made from one point and a heading, which leaves nothing to check.
    public var residual: Double

    public init(rotation: Double, translation: PlanPoint, residual: Double = 0) {
        self.rotation = PlanAngle.normalized(rotation)
        self.translation = translation
        self.residual = residual
    }

    public static let identity = WorldAlignment(rotation: 0, translation: .zero)

    /// From one matched point and the heading of one matched direction (a speaker's facing in the model and in the
    /// world).
    public init(modelPoint: PlanPoint, worldPoint: PlanPoint, modelHeading: Double, worldHeading: Double) {
        let rotation = PlanAngle.difference(from: modelHeading, to: worldHeading)
        self.init(rotation: rotation, translation: worldPoint - modelPoint.rotated(by: rotation))
    }

    /// The least-squares fit (2D Procrustes without scale) to two or more matched points; nil for fewer than two, or
    /// when the model points all coincide so no rotation can be found.
    public static func fit(model: [PlanPoint], world: [PlanPoint]) -> WorldAlignment? {
        guard model.count == world.count, model.count >= 2 else { return nil }
        let n = Double(model.count)
        let modelCentre = model.reduce(.zero, +) * (1 / n)
        let worldCentre = world.reduce(.zero, +) * (1 / n)
        var dot = 0.0, cross = 0.0
        for (m, w) in zip(model, world) {
            let a = m - modelCentre, b = w - worldCentre
            dot += a.dot(b)
            cross += a.cross(b)
        }
        guard hypot(dot, cross) > 1e-12 else { return nil }
        let rotation = atan2(cross, dot)
        var alignment = WorldAlignment(rotation: rotation, translation: worldCentre - modelCentre.rotated(by: rotation))
        let squared = zip(model, world).reduce(0) { $0 + pow(alignment.apply($1.0).distance(to: $1.1), 2) }
        alignment.residual = (squared / n).squareRoot()
        return alignment
    }

    /// Whether the matched points agree with each other within `maximumResidual`.
    public var isConsistent: Bool { residual <= Self.maximumResidual }

    public func apply(_ point: PlanPoint) -> PlanPoint { point.rotated(by: rotation) + translation }

    public func apply(heading: Double) -> Double { PlanAngle.normalized(heading + rotation) }

    public func apply(_ pose: PlanPose) -> PlanPose {
        PlanPose(position: apply(pose.position), facing: apply(heading: pose.facing))
    }

    /// World to model; carries the same residual.
    public var inverse: WorldAlignment {
        WorldAlignment(rotation: -rotation, translation: (-translation).rotated(by: -rotation), residual: residual)
    }
}
