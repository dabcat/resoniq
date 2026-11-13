import ResoniqDesign
import ResoniqRoom
import SwiftUI

/// The picture behind the AR guide where there is no camera (simulator, previews): V3OAR's camera placeholder, a
/// `panelRaised` field with its horizon and floor lines, and the same floor overlay the RealityKit view draws,
/// projected in 2D from the scripted camera: the target's faint fill and marching dashed `guide` outline (still
/// under Reduce Motion), the speaker's `ivory` outline, the turn arc with its label, and the reticle.
/// Decorative for VoiceOver, which hears the readout instead.
struct ARGuidanceCameraStandIn: View {
    let model: ARGuidanceModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let drawing = model.drawing
        TimelineView(.animation(minimumInterval: Metrics.marchStep, paused: reduceMotion || drawing.target == nil)) { timeline in
            Canvas { context, size in
                drawFloorLines(in: &context, size: size)
                guard let projection = FloorProjection(drawing: drawing, size: size) else { return }
                let time = timeline.date.timeIntervalSinceReferenceDate
                draw(drawing, with: projection, time: time, in: &context)
            }
            .overlay {
                GeometryReader { proxy in
                    if let text = drawing.arcText, let label = drawing.arcLabel,
                       let point = FloorProjection(drawing: drawing, size: proxy.size)?.project(label) {
                        ARTurnLabel(text: text).position(point)
                    }
                }
            }
        }
        .background(ResoniqColor.panelRaised)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func draw(_ drawing: ARFloorDrawing, with projection: FloorProjection, time: TimeInterval,
                      in context: inout GraphicsContext) {
        if let target = drawing.target, let outline = projection.path(target.corners, closed: true) {
            context.fill(outline, with: .color(ResoniqColor.guide.opacity(Metrics.fillOpacity)))
            let phase = ARGuidanceGeometry.marchPhase(time: time, reduceMotion: reduceMotion)
            var dashes = Path()
            for dash in ARGuidanceGeometry.dashes(around: target.corners, phase: phase) {
                if let a = projection.project(dash.start), let b = projection.project(dash.end) {
                    dashes.move(to: a)
                    dashes.addLine(to: b)
                }
            }
            context.stroke(dashes, with: .color(ResoniqColor.guide),
                           style: StrokeStyle(lineWidth: Metrics.targetStroke, lineCap: .butt))
        }
        if let arc = drawing.arc, let path = projection.path(arc, closed: false) {
            context.stroke(path, with: .color(ResoniqColor.guide),
                           style: StrokeStyle(lineWidth: Metrics.arcStroke, lineCap: .round))
        }
        if let speaker = drawing.speaker, let outline = projection.path(speaker.corners, closed: true) {
            context.stroke(outline, with: .color(ResoniqColor.ivory),
                           style: StrokeStyle(lineWidth: Metrics.speakerStroke, lineJoin: .round))
        }
        if let reticle = drawing.reticle, let centre = projection.project(reticle.point) {
            let dot = CGRect(x: centre.x - Metrics.reticle / 2, y: centre.y - Metrics.reticle / 2,
                             width: Metrics.reticle, height: Metrics.reticle)
            context.fill(Path(ellipseIn: dot), with: .color(ResoniqColor.ivory))
        }
    }

    /// V3OAR's horizon and floor lines, from its 390 × 520 camera box, scaled to the width.
    private func drawFloorLines(in context: inout GraphicsContext, size: CGSize) {
        let scale = size.width / Metrics.box.width
        var horizon = Path()
        horizon.move(to: CGPoint(x: 0, y: Metrics.horizonY * scale))
        horizon.addLine(to: CGPoint(x: size.width, y: Metrics.horizonY * scale))
        context.stroke(horizon, with: .color(ResoniqColor.muted), lineWidth: Metrics.horizonStroke)
        var lines = Path()
        let vanishing = CGPoint(x: Metrics.box.width / 2 * scale, y: Metrics.horizonY * scale)
        for x in Metrics.rays {
            lines.move(to: vanishing)
            lines.addLine(to: CGPoint(x: x * scale, y: Metrics.box.height * scale))
        }
        for y in Metrics.rows {
            lines.move(to: CGPoint(x: 0, y: y * scale))
            lines.addLine(to: CGPoint(x: size.width, y: y * scale))
        }
        context.stroke(lines, with: .color(ResoniqColor.line), lineWidth: Metrics.lineStroke)
    }

    private enum Metrics {
        static let box = CGSize(width: 390, height: 520)
        static let horizonY: CGFloat = 200
        static let rays: [CGFloat] = [-150, 10, 135, 255, 380, 540]
        static let rows: [CGFloat] = [250, 322, 430]
        static let horizonStroke: CGFloat = 1.5
        static let lineStroke: CGFloat = 1.2
        static let targetStroke: CGFloat = 3
        static let speakerStroke: CGFloat = 2.5
        static let arcStroke: CGFloat = 2.5
        static let reticle: CGFloat = 10
        static let fillOpacity = 0.18
        static let marchStep: TimeInterval = 1.0 / 30
    }
}

/// A pinhole camera at standing height over the floor, pitched down to look at the target, for the stand-in
/// only (the device draws with RealityKit's real camera).
private struct FloorProjection {
    /// Metres: eye height, and how far ahead the camera looks when there is nothing to look at.
    static let height = 1.3
    static let defaultAim = 1.4

    let camera: Viewer
    let pitch: Double
    let focal: Double
    let centre: CGPoint

    init?(drawing: ARFloorDrawing, size: CGSize) {
        guard let camera = drawing.camera, size.width > 0 else { return nil }
        self.camera = camera
        let aim = drawing.target.map { $0.centre.distance(to: camera.position) } ?? Self.defaultAim
        pitch = atan2(Self.height, max(aim, 0.3))
        focal = size.width * 1.2
        // The camera area is the top of the screen above the sheet.
        centre = CGPoint(x: size.width / 2, y: size.height * 0.36)
    }

    func project(_ point: PlanPoint) -> CGPoint? {
        let look = PlanPoint(angle: camera.heading)
        let offset = point - camera.position
        let ahead = offset.dot(look), side = offset.dot(look.rightHand)
        let depth = ahead * cos(pitch) + Self.height * sin(pitch)
        guard depth > 0.05 else { return nil }
        let up = ahead * sin(pitch) - Self.height * cos(pitch)
        return CGPoint(x: centre.x + focal * side / depth, y: centre.y - focal * up / depth)
    }

    func path(_ points: [PlanPoint], closed: Bool) -> Path? {
        let projected = points.compactMap(project)
        guard projected.count == points.count, projected.count >= 2 else { return nil }
        var path = Path()
        path.addLines(projected)
        if closed { path.closeSubpath() }
        return path
    }
}

/// The turn arc's label on the floor (V3OAR "turn 12°"): `guide` mono text on an `ink` pill.
struct ARTurnLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(ResoniqFont.axis)
            .foregroundStyle(ResoniqColor.guide)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, ResoniqSpace.s3)
            .frame(minHeight: Metrics.height)
            .background(ResoniqColor.ink, in: Capsule())
            .accessibilityHidden(true)
    }

    private enum Metrics {
        static let height: CGFloat = 26
    }
}
