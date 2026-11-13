#if !targetEnvironment(simulator)
import ARKit
import Combine
import RealityKit
import ResoniqDesign
import ResoniqRoom
import SwiftUI

/// The camera with the floor overlay (V3OAR, design/DESIGN_SYSTEM.md "AR overlay"): RealityKit's `ARView` on the
/// live source's own session, as RoomScan's `RescanOverlay` does (`ARView(frame:cameraMode:.ar,
/// automaticallyConfigureSession: false)`, `view.session = …`), so there is one camera owner.
///
/// `ARView` rather than `RealityView`: on iOS 26 a `RealityView` camera runs on a `SpatialTrackingSession`, which
/// does not hand back ARKit's tracking state and its reasons, interruptions or raycasts against plane geometry;
/// the guide needs all three every poll. `ARView` is not deprecated in the iOS 27.1 SDK (only its old
/// `init(frame:cameraMode:automaticallyConfigureSession:)` spelling without labels is).
///
/// Entities, all on one `AnchorEntity(world: .zero)` in world coordinates: the reticle, the target's faint fill
/// and its dashed `guide` outline (thin boxes laid along the outline, re-laid at 30 Hz to march at
/// `motion.loop.marchingOutline`, still under Reduce Motion), the speaker's `ivory` outline, and the turn arc.
/// The arc's label is SwiftUI over the camera, at the point this view projects.
struct ARGuidanceRealityView: UIViewRepresentable {
    let model: ARGuidanceModel
    let session: ARSession

    func makeCoordinator() -> ARGuidanceOverlay { ARGuidanceOverlay(model: model) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        view.renderOptions.insert(.disableMotionBlur)
        view.environment.background = .cameraFeed()
        context.coordinator.install(in: view)
        model.haptics.attach(to: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.update(model.drawing)
    }

    static func dismantleUIView(_ view: ARView, coordinator: ARGuidanceOverlay) {
        coordinator.uninstall()
    }
}

/// Owns the entities and lays them out from an `ARFloorDrawing`. Decides nothing.
final class ARGuidanceOverlay {
    private let model: ARGuidanceModel
    private let root = AnchorEntity(world: .zero)
    private let reticle: ModelEntity
    private let fill: ModelEntity
    private var dashes: [ModelEntity] = []
    private var speakerEdges: [ModelEntity] = []
    private var arcPieces: [ModelEntity] = []
    private var drawing = ARFloorDrawing.empty
    private var updates: (any Cancellable)?
    private weak var view: ARView?
    private var clock: TimeInterval = 0
    private var sinceMarch: TimeInterval = .infinity
    private var sinceLabel: TimeInterval = .infinity

    private let unitBox = MeshResource.generateBox(size: 1)
    private let guideMaterial = UnlitMaterial(color: UIColor(ResoniqColor.guide))
    private let ivoryMaterial = UnlitMaterial(color: UIColor(ResoniqColor.ivory))

    init(model: ARGuidanceModel) {
        self.model = model
        reticle = ModelEntity(
            mesh: .generateCylinder(height: Metrics.thickness, radius: Metrics.reticleRadius),
            materials: [UnlitMaterial(color: UIColor(ResoniqColor.ivory))])
        var fillMaterial = UnlitMaterial(color: UIColor(ResoniqColor.guide))
        fillMaterial.blending = .transparent(opacity: .init(floatLiteral: Metrics.fillOpacity))
        fill = ModelEntity(mesh: .generatePlane(width: 1, depth: 1), materials: [fillMaterial])
    }

    func install(in view: ARView) {
        self.view = view
        for entity in [reticle, fill] {
            entity.isEnabled = false
            root.addChild(entity)
        }
        view.scene.addAnchor(root)
        updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            let delta = event.deltaTime
            MainActor.assumeIsolated { self?.tick(delta) }
        }
    }

    func uninstall() {
        updates?.cancel()
        updates = nil
        root.removeFromParent()
        model.setArcLabelPoint(nil)
    }

    func update(_ drawing: ARFloorDrawing) {
        guard drawing != self.drawing else { return }
        self.drawing = drawing
        let floor = Float(drawing.floorHeight)

        if let hit = drawing.reticle {
            reticle.position = SIMD3(Float(hit.point.x), Float(hit.height) + Metrics.reticleLift, Float(hit.point.z))
            reticle.isEnabled = true
        } else {
            reticle.isEnabled = false
        }

        if let target = drawing.target {
            fill.position = SIMD3(Float(target.centre.x), floor + Metrics.fillLift, Float(target.centre.z))
            fill.orientation = Self.yaw(target.heading)
            // The unit plane's x runs along the heading (depth), its z across (width).
            fill.scale = SIMD3(Float(target.depth), 1, Float(target.width))
            fill.isEnabled = true
        } else {
            fill.isEnabled = false
        }

        let edges = drawing.speaker.map { Self.edges(of: $0.corners) } ?? []
        lay(edges, in: &speakerEdges, material: ivoryMaterial, width: Metrics.speakerStroke, y: floor + Metrics.lineLift)

        let arc = drawing.arc.map { points in
            zip(points, points.dropFirst()).map { PlanSegment(start: $0, end: $1) }
        } ?? []
        lay(arc, in: &arcPieces, material: guideMaterial, width: Metrics.arcStroke, y: floor + Metrics.lineLift)

        sinceMarch = .infinity
        sinceLabel = .infinity
        tick(0)
    }

    /// Per rendered frame, cheap: the march re-lays the dashes at most 30 times a second, the label is projected
    /// at most 10 times a second.
    private func tick(_ delta: TimeInterval) {
        clock += delta
        sinceMarch += delta
        sinceLabel += delta
        if sinceMarch >= Metrics.marchStep {
            sinceMarch = 0
            let phase = ARGuidanceGeometry.marchPhase(time: clock, reduceMotion: UIAccessibility.isReduceMotionEnabled)
            let pieces = drawing.target.map { ARGuidanceGeometry.dashes(around: $0.corners, phase: phase) } ?? []
            lay(pieces, in: &dashes, material: guideMaterial, width: Metrics.targetStroke,
                y: Float(drawing.floorHeight) + Metrics.lineLift)
        }
        if sinceLabel >= Metrics.labelStep {
            sinceLabel = 0
            projectLabel()
        }
    }

    private func projectLabel() {
        guard let view, let label = drawing.arcLabel else {
            model.setArcLabelPoint(nil)
            return
        }
        let point = SIMD3(Float(label.x), Float(drawing.floorHeight), Float(label.z))
        model.setArcLabelPoint(view.project(point))
    }

    /// Thin boxes along each segment, reusing a pool; the ones left over are hidden.
    private func lay(_ segments: [PlanSegment], in pool: inout [ModelEntity], material: UnlitMaterial, width: Float, y: Float) {
        while pool.count < segments.count {
            let entity = ModelEntity(mesh: unitBox, materials: [material])
            root.addChild(entity)
            pool.append(entity)
        }
        for (index, entity) in pool.enumerated() {
            guard index < segments.count else {
                entity.isEnabled = false
                continue
            }
            let segment = segments[index]
            let middle = segment.midpoint
            entity.position = SIMD3(Float(middle.x), y, Float(middle.z))
            entity.orientation = Self.yaw((segment.end - segment.start).angle)
            entity.scale = SIMD3(Float(segment.length), Metrics.thickness, width)
            entity.isEnabled = true
        }
    }

    private static func edges(of corners: [PlanPoint]) -> [PlanSegment] {
        corners.indices.map { PlanSegment(start: corners[$0], end: corners[($0 + 1) % corners.count]) }
    }

    /// A rotation about +y that turns local +x to the plan angle: ARKit's yaw is −angle (`PlanAngle`).
    private static func yaw(_ planAngle: Double) -> simd_quatf {
        simd_quatf(angle: Float(-planAngle), axis: SIMD3(0, 1, 0))
    }

    private enum Metrics {
        /// The overlay's lines, metres, lifted a few millimetres off the floor so they do not flicker into it.
        static let targetStroke: Float = 0.012
        static let speakerStroke: Float = 0.010
        static let arcStroke: Float = 0.008
        static let thickness: Float = 0.002
        static let reticleRadius: Float = 0.022
        static let fillLift: Float = 0.002
        static let lineLift: Float = 0.004
        static let reticleLift: Float = 0.006
        /// V3OAR's fill-opacity.
        static let fillOpacity: Float = 0.18
        static let marchStep: TimeInterval = 1.0 / 30
        static let labelStep: TimeInterval = 0.1
    }
}
#endif
