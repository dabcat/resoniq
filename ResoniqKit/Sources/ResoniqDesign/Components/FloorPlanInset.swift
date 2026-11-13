import SwiftUI

/// The numbers of the inset, apart from drawing so they can be tested on the Mac.
enum FloorPlanInsetGeometry {
    /// Half the angle the camera sees, in degrees; V3OScan's wedge is about 28.6 degrees to each side.
    static let wedgeHalfAngle: Double = 28.6
    /// How far the wedge reaches, in points.
    static let wedgeLength: CGFloat = 25

    /// The three points of the camera's wedge: the apex at the camera and two corners ahead of it.
    static func wedge(apex: CGPoint, facing: Double, halfAngle: Double = wedgeHalfAngle, length: CGFloat = wedgeLength) -> [CGPoint] {
        guard RoomPlanGeometry.isFinite(apex), length.isFinite else { return [] }
        // The corners lie at `length` along the facing, so the far edge is flat, as in the mockup.
        let reach = length / CGFloat(max(cos(halfAngle * .pi / 180), 0.1))
        let corners = [facing - halfAngle, facing + halfAngle].map { angle -> CGPoint in
            let direction = RoomPlanGeometry.forward(facing: angle)
            return CGPoint(x: apex.x + direction.dx * reach, y: apex.y + direction.dy * reach)
        }
        return [apex] + corners
    }

    /// The box around the walls and the camera, in metres.
    static func bounds(walls: [FloorPlanInset.Wall], camera: CGPoint) -> CGRect? {
        var content = RoomPlanContent(walls: walls.map(\.segment))
        content.measuredSpots = [camera]
        return RoomPlanGeometry.bounds(of: content)
    }
}

/// The mini floor plan in a corner of the camera view while a room is scanned (V3OScan "Floor plan"): the walls
/// captured so far are solid `guide`, a wall still missing is dashed `muted` (and pulses while it waits, still
/// under Reduce Motion), the camera is an `ivory` dot, and a `lime` wedge shows where it points.
///
/// It sits on an `ink` backing so it reads over the picture. 104 x 132 pt as in the mockup. One element for
/// VoiceOver: the sentence passed as `accessibilityLabel`.
public struct FloorPlanInset: View {
    public struct Wall: Sendable, Equatable {
        public var segment: RoomPlanContent.Segment
        public var isCaptured: Bool

        public init(_ segment: RoomPlanContent.Segment, isCaptured: Bool) {
            self.segment = segment
            self.isCaptured = isCaptured
        }
    }

    private let walls: [Wall]
    private let camera: CGPoint
    private let cameraFacing: Double
    private let caption: String
    private let accessibilityText: String

    /// - Parameters:
    ///   - walls: The walls in metres, captured or still missing.
    ///   - camera: Where the phone is, in the same metres.
    ///   - cameraFacing: The way it points, in degrees (0 up the plan, clockwise).
    ///   - caption: The caps label; "Floor plan".
    public init(walls: [Wall], camera: CGPoint, cameraFacing: Double, caption: String = "Floor plan", accessibilityLabel: String) {
        self.walls = walls
        self.camera = camera
        self.cameraFacing = cameraFacing
        self.caption = caption
        self.accessibilityText = accessibilityLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Text(caption)
                .font(Metrics.captionFont)
                .tracking(Metrics.captionSize * ResoniqFont.Tracking.capsLabel)
                .textCase(.uppercase)
                .foregroundStyle(ResoniqColor.muted)
                .lineLimit(1)
                .minimumScaleFactor(Metrics.minimumScale)
            GeometryReader { proxy in
                let fit = PlanFit.fit(
                    bounds: FloorPlanInsetGeometry.bounds(walls: walls, camera: camera), in: proxy.size, padding: Metrics.planPadding
                )
                ZStack {
                    Canvas { context, _ in drawCaptured(fit: fit, in: &context) }
                    LoopingPhase(isRunning: true, animation: ResoniqMotion.waiting) { phase, isActive in
                        Canvas { context, _ in drawMissing(fit: fit, in: &context) }
                            .opacity(isActive && !phase ? Metrics.missingLow : 1)
                    }
                }
            }
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width, height: Metrics.height)
        .background(ResoniqColor.ink, in: RoundedRectangle(cornerRadius: ResoniqRadius.control, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
    }

    private func path(_ wall: Wall, fit: PlanFit) -> Path {
        var path = Path()
        path.move(to: fit.point(wall.segment.a))
        path.addLine(to: fit.point(wall.segment.b))
        return path
    }

    private func drawCaptured(fit: PlanFit, in context: inout GraphicsContext) {
        for wall in walls where wall.isCaptured && RoomPlanGeometry.isFinite(wall.segment) {
            context.stroke(path(wall, fit: fit), with: .color(ResoniqColor.guide), style: StrokeStyle(lineWidth: ResoniqSize.strokeWall, lineCap: .round, lineJoin: .round))
        }
        guard RoomPlanGeometry.isFinite(camera) else { return }
        let apex = fit.point(camera)
        let points = FloorPlanInsetGeometry.wedge(apex: apex, facing: cameraFacing)
        if points.count == 3 {
            var wedge = Path()
            wedge.addLines(points)
            wedge.closeSubpath()
            context.fill(wedge, with: .color(ResoniqColor.lime.opacity(Metrics.wedgeOpacity)))
        }
        context.fill(
            Path(ellipseIn: CGRect(x: apex.x - Metrics.cameraRadius, y: apex.y - Metrics.cameraRadius, width: Metrics.cameraRadius * 2, height: Metrics.cameraRadius * 2)),
            with: .color(ResoniqColor.ivory)
        )
    }

    private func drawMissing(fit: PlanFit, in context: inout GraphicsContext) {
        for wall in walls where !wall.isCaptured && RoomPlanGeometry.isFinite(wall.segment) {
            context.stroke(
                path(wall, fit: fit), with: .color(ResoniqColor.muted),
                style: StrokeStyle(lineWidth: Metrics.missingStroke, lineCap: .round, dash: Metrics.missingDash)
            )
        }
    }

    private enum Metrics {
        static let width: CGFloat = 104
        static let height: CGFloat = 132
        static let padding: CGFloat = 10
        static let gap: CGFloat = 6
        static let planPadding: CGFloat = 6
        static let captionSize: CGFloat = 10
        static let captionFont = ResoniqFont.font(.monoRegular, size: captionSize, relativeTo: .caption2)
        static let minimumScale: CGFloat = 0.7
        static let cameraRadius: CGFloat = 4
        static let wedgeOpacity: Double = 0.5
        static let missingStroke: CGFloat = 2
        static let missingDash: [CGFloat] = [3, 5]
        static let missingLow: Double = 0.3
    }
}

#if DEBUG
public extension FloorPlanInset {
    /// Three of four walls captured, the camera looking at the missing one.
    static let sampleWalls: [Wall] = [
        Wall(.init(x1: 0, y1: 0, x2: 4.2, y2: 0), isCaptured: true),
        Wall(.init(x1: 0, y1: 0, x2: 0, y2: 5.6), isCaptured: true),
        Wall(.init(x1: 0, y1: 5.6, x2: 4.2, y2: 5.6), isCaptured: true),
        Wall(.init(x1: 4.2, y1: 0, x2: 4.2, y2: 5.6), isCaptured: false),
    ]
}

#Preview("Floor plan inset") {
    HStack(alignment: .top, spacing: ResoniqSpace.s4) {
        FloorPlanInset(
            walls: FloorPlanInset.sampleWalls, camera: CGPoint(x: 2, y: 3.6), cameraFacing: 70,
            accessibilityLabel: "Small floor plan: three walls drawn, the right wall still missing, a wedge shows where the camera points."
        )
        FloorPlanInset(
            walls: FloorPlanInset.sampleWalls.map { FloorPlanInset.Wall($0.segment, isCaptured: true) }, camera: CGPoint(x: 2, y: 3.6), cameraFacing: 0,
            accessibilityLabel: "Small floor plan: all four walls drawn."
        )
        FloorPlanInset(walls: [], camera: .zero, cameraFacing: 0, accessibilityLabel: "Small floor plan: nothing captured yet.")
    }
    .padding(ResoniqSpace.s4)
    .background(ResoniqColor.panelRaised)
}
#endif
