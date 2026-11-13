import ResoniqDesign
import ResoniqRoom
import SwiftUI

/// The "3D" side of Confirm layout: the same model seen from above and a little to the side, with the walls,
/// furniture and speakers as boxes and the seat as a head on a stalk. Drag to turn it round; nothing is edited here.
///
/// It is the plan in an isometric-style projection drawn in a `Canvas`, not a RealityKit scene: the view only has to
/// confirm that the positions are right, and a projection of boxes does that without a renderer, an entity graph or
/// a camera to get wrong. Heights other than the walls' are for orientation only (`Metrics`).
struct Room3DView: View {
    let room: RoomModel
    let height: CGFloat?

    @State private var yaw: Double = Metrics.initialYaw
    @GestureState private var dragYaw: Double = 0

    var body: some View {
        Canvas { context, size in
            Projection(room: room, yaw: yaw + dragYaw).draw(in: &context, size: size)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(ResoniqColor.panel, in: RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous)
                .strokeBorder(ResoniqColor.line, lineWidth: ResoniqSize.strokeHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous))
        .gesture(
            DragGesture()
                .updating($dragYaw) { value, state, _ in state = value.translation.width * Metrics.radiansPerPoint }
                .onEnded { value in yaw += value.translation.width * Metrics.radiansPerPoint }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(OptimizeText.threeDSummary) \(RoomDisplay.layoutSummary(of: room))")
        .accessibilityAddTraits(.isImage)
        // VoiceOver turns it a step at a time.
        .accessibilityAdjustableAction { direction in
            yaw += (direction == .increment ? 1 : -1) * Metrics.accessibilityStep
        }
    }

    fileprivate enum Metrics {
        static let initialYaw = 0.5
        static let radiansPerPoint = 0.012
        static let accessibilityStep = Double.pi / 8
        /// How far the view looks down: 90° is straight down (the plan), 0° is level.
        static let pitch = 55.0 * Double.pi / 180
        static let margin: CGFloat = 28
        /// Heights for orientation only: furniture without a height, and the seat's head (a seated listener's ears).
        static let defaultFurnitureHeight = 0.8
        static let seatHeadHeight = 1.1
        static let seatHeadRadius = 0.12
        static let speakerHeightPerDriverHeight = 1.2
        static let subwooferHeightPerDriverHeight = 2.0
        static let labelGap: CGFloat = 8
    }

    /// The room turned by `yaw` and tilted by `Metrics.pitch`, in points.
    fileprivate struct Projection {
        let room: RoomModel
        let yaw: Double

        private var centre: PlanPoint { RoomGeometry.bounds(of: room)?.centre ?? .zero }

        /// Plan point and height to the unscaled screen: x to the right, y down.
        func raw(_ point: PlanPoint, height: Double = 0) -> CGPoint {
            let dx = point.x - centre.x, dz = point.z - centre.z
            let turnedX = dx * cos(yaw) - dz * sin(yaw)
            let turnedZ = dx * sin(yaw) + dz * cos(yaw)
            return CGPoint(x: turnedX, y: turnedZ * sin(Metrics.pitch) - height * cos(Metrics.pitch))
        }

        /// Nearer to the viewer is larger; items are drawn far first.
        func depth(_ point: PlanPoint) -> Double {
            let dx = point.x - centre.x, dz = point.z - centre.z
            return dx * sin(yaw) + dz * cos(yaw)
        }

        private struct Item {
            var depth: Double
            var draw: (inout GraphicsContext, (CGPoint) -> CGPoint) -> Void
        }

        func draw(in context: inout GraphicsContext, size: CGSize) {
            var points: [CGPoint] = []
            var items: [Item] = []

            // Floor.
            let outline = RoomGeometry.outline(of: room)
            if outline.count >= 3 {
                points += outline.map { raw($0) }
                items.append(Item(depth: -.infinity) { context, map in
                    var path = Path()
                    path.addLines(outline.map { map(raw($0)) })
                    path.closeSubpath()
                    context.fill(path, with: .color(ResoniqColor.panelRaised))
                })
            }

            // Walls: the base and the top edge and the two ends, as lines.
            for wall in room.walls {
                points += [raw(wall.start), raw(wall.end), raw(wall.start, height: wall.height), raw(wall.end, height: wall.height)]
                let middle = (wall.start + wall.end) * 0.5
                items.append(Item(depth: depth(middle)) { context, map in
                    var path = Path()
                    path.move(to: map(raw(wall.start)))
                    path.addLine(to: map(raw(wall.end)))
                    path.addLine(to: map(raw(wall.end, height: wall.height)))
                    path.addLine(to: map(raw(wall.start, height: wall.height)))
                    path.closeSubpath()
                    context.stroke(path, with: .color(ResoniqColor.ivory), lineWidth: ResoniqSize.strokeHairline)
                })
            }

            // Furniture and speakers.
            for item in room.furniture {
                let top = item.height ?? Metrics.defaultFurnitureHeight
                points += box(item.footprint, height: top).flatMap { $0 }
                items.append(Item(depth: depth(item.footprint.centre)) { context, map in
                    drawBox(item.footprint, height: top, fill: ResoniqColor.panel, stroke: ResoniqColor.muted, in: &context, map: map)
                })
            }
            for speaker in room.speakers {
                let factor = speaker.role == .subwoofer ? Metrics.subwooferHeightPerDriverHeight : Metrics.speakerHeightPerDriverHeight
                let top = speaker.driverHeight * factor
                points += box(speaker.footprint, height: top).flatMap { $0 }
                items.append(Item(depth: depth(speaker.position)) { context, map in
                    drawBox(speaker.footprint, height: top, fill: ResoniqColor.ivory, stroke: ResoniqColor.ink, in: &context, map: map)
                    let label = context.resolve(
                        Text(RoomText.shortName(speaker.role)).font(ResoniqFont.caption).foregroundStyle(ResoniqColor.ivory))
                    let anchor = map(raw(speaker.position, height: top))
                    context.draw(label, at: CGPoint(x: anchor.x, y: anchor.y - Metrics.labelGap), anchor: .bottom)
                })
            }
            for seat in room.seats {
                points += [raw(seat.position), raw(seat.position, height: Metrics.seatHeadHeight + Metrics.seatHeadRadius)]
                items.append(Item(depth: depth(seat.position)) { context, map in
                    let floor = map(raw(seat.position)), head = map(raw(seat.position, height: Metrics.seatHeadHeight))
                    var stalk = Path()
                    stalk.move(to: floor)
                    stalk.addLine(to: head)
                    context.stroke(stalk, with: .color(ResoniqColor.ivory), lineWidth: ResoniqSize.strokeHairline)
                    let radius = abs(map(raw(seat.position, height: Metrics.seatHeadHeight + Metrics.seatHeadRadius)).y - head.y)
                    context.fill(
                        Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(ResoniqColor.ivory))
                })
            }

            // Fit everything drawn into the frame at one scale.
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
            let width = max(maxX - minX, 0.001), height = max(maxY - minY, 0.001)
            let scale = min((size.width - 2 * Metrics.margin) / width, (size.height - 2 * Metrics.margin) / height)
            let offsetX = (size.width - width * scale) / 2 - minX * scale
            let offsetY = (size.height - height * scale) / 2 - minY * scale
            let map: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * scale + offsetX, y: $0.y * scale + offsetY) }
            for item in items.sorted(by: { $0.depth < $1.depth }) { item.draw(&context, map) }
        }

        /// The four faces' corners of a box standing on the floor: the base corners, then the top corners.
        private func box(_ rect: OrientedRect, height: Double) -> [[CGPoint]] {
            let base = rect.corners
            return [base.map { raw($0) }, base.map { raw($0, height: height) }]
        }

        private func drawBox(
            _ rect: OrientedRect, height: Double, fill: Color, stroke: Color, in context: inout GraphicsContext,
            map: (CGPoint) -> CGPoint
        ) {
            let base = rect.corners
            // Sides far first, then the top.
            let sides = base.indices.map { index -> (depth: Double, path: Path) in
                let a = base[index], b = base[(index + 1) % base.count]
                var path = Path()
                path.addLines([map(raw(a)), map(raw(b)), map(raw(b, height: height)), map(raw(a, height: height))])
                path.closeSubpath()
                return (depth(PlanPoint(x: (a.x + b.x) / 2, z: (a.z + b.z) / 2)), path)
            }
            for side in sides.sorted(by: { $0.depth < $1.depth }) {
                context.fill(side.path, with: .color(fill))
                context.stroke(side.path, with: .color(stroke), lineWidth: ResoniqSize.strokeHairline)
            }
            var top = Path()
            top.addLines(base.map { map(raw($0, height: height)) })
            top.closeSubpath()
            context.fill(top, with: .color(fill))
            context.stroke(top, with: .color(stroke), lineWidth: ResoniqSize.strokeHairline)
        }
    }
}
