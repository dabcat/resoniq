import ResoniqDesign
import SwiftUI

/// The picture behind the Scan screen where there is no camera (simulator, previews): V3OScan's camera placeholder,
/// a `panelRaised` field with the mockup's outlined room (back and left walls captured in `guide`, the right wall
/// dashed, a window, a door and a sofa in `ivory`). Decorative; VoiceOver skips it.
struct ScanCameraStandIn: View {
    var body: some View {
        Canvas { context, size in
            // The mockup draws in a 390 × 548 box at the top of the screen; scale it to the width.
            let scale = size.width / Metrics.box.width
            context.scaleBy(x: scale, y: scale)
            let wall = StrokeStyle(lineWidth: Metrics.wallStroke, lineCap: .round, lineJoin: .round)
            let thing = StrokeStyle(lineWidth: Metrics.thingStroke, lineCap: .round, lineJoin: .round)

            context.fill(Path(Metrics.backWall), with: .color(ResoniqColor.guide.opacity(Metrics.backFill)))
            context.fill(polygon(Metrics.leftWall, closed: true), with: .color(ResoniqColor.guide.opacity(Metrics.sideFill)))
            var captured = Path(Metrics.backWall)
            captured.addPath(polygon([CGPoint(x: 95, y: 160), CGPoint(x: 0, y: 70)]))
            captured.addPath(polygon([CGPoint(x: 95, y: 340), CGPoint(x: 0, y: 480)]))
            context.stroke(captured, with: .color(ResoniqColor.guide), style: wall)

            var missing = polygon([CGPoint(x: 295, y: 160), CGPoint(x: 390, y: 70)])
            missing.addPath(polygon([CGPoint(x: 295, y: 340), CGPoint(x: 390, y: 480)]))
            context.stroke(
                missing, with: .color(ResoniqColor.muted),
                style: StrokeStyle(lineWidth: Metrics.missingStroke, lineCap: .round, dash: Metrics.missingDash))

            var things = Path(Metrics.window)
            things.addPath(polygon(Metrics.door, closed: true))
            things.addPath(Path(Metrics.sofaSeat))
            things.addPath(polygon(Metrics.sofaBack))
            context.stroke(things, with: .color(ResoniqColor.ivory), style: thing)
        }
        .background(ResoniqColor.panelRaised)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func polygon(_ points: [CGPoint], closed: Bool = false) -> Path {
        var path = Path()
        path.addLines(points)
        if closed { path.closeSubpath() }
        return path
    }

    /// V3OScan's SVG, in its own 390 × 548 coordinates.
    private enum Metrics {
        static let box = CGSize(width: 390, height: 548)
        static let backWall = CGRect(x: 95, y: 160, width: 200, height: 180)
        static let leftWall = [CGPoint(x: 0, y: 70), CGPoint(x: 95, y: 160), CGPoint(x: 95, y: 340), CGPoint(x: 0, y: 480)]
        static let window = CGRect(x: 150, y: 196, width: 90, height: 72)
        static let door = [CGPoint(x: 30, y: 436), CGPoint(x: 30, y: 225), CGPoint(x: 65, y: 245), CGPoint(x: 65, y: 384)]
        static let sofaSeat = CGRect(x: 132, y: 382, width: 126, height: 44)
        static let sofaBack = [CGPoint(x: 132, y: 382), CGPoint(x: 146, y: 360), CGPoint(x: 244, y: 360), CGPoint(x: 258, y: 382)]
        static let wallStroke: CGFloat = 2.5
        static let thingStroke: CGFloat = 2
        static let missingStroke: CGFloat = 1.5
        static let missingDash: [CGFloat] = [5, 7]
        static let backFill = 0.10
        static let sideFill = 0.06
    }
}

#if DEBUG
#Preview {
    ScanCameraStandIn()
}
#endif
