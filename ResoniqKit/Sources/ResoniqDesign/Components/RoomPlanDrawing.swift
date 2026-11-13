import SwiftUI

/// The distance from a selected item to the nearest wall, as the Kit computed it (V3OLayout "0.90 m").
public struct RoomPlanWallDistance: Sendable, Equatable {
    /// "0.90 m".
    public var label: String
    /// The nearest point on a wall, in the plan's metres.
    public var wallPoint: CGPoint

    public init(label: String, wallPoint: CGPoint) {
        self.label = label
        self.wallPoint = wallPoint
    }
}

/// Everything one frame of the plan needs, so the view and the editor draw the same picture.
struct RoomPlanScene {
    var content: RoomPlanContent
    /// Positions (metres) and facings the caller wants drawn instead of the content's, while something is dragged.
    var positions: [String: CGPoint] = [:]
    var facings: [String: Double] = [:]
    var selectedID: String?
    var selectedDistance: RoomPlanWallDistance?
    /// Draws the rotate handle on the selected speaker.
    var showsHandle = false
    /// A speaker drawn by a view on top of the canvas (the sliding one), so the canvas skips it.
    var hiddenSpeakerID: String?
    var dashPhase: CGFloat = 0
    var background: Color = ResoniqColor.panel

    func position(of speaker: RoomPlanContent.Speaker) -> CGPoint { positions[speaker.id] ?? speaker.position }
    func facing(of speaker: RoomPlanContent.Speaker) -> Double { facings[speaker.id] ?? speaker.facing }
    func position(of seat: RoomPlanContent.Seat) -> CGPoint { positions[seat.id] ?? seat.position }

    func fit(in size: CGSize) -> PlanFit {
        PlanFit.fit(bounds: RoomPlanGeometry.bounds(of: content), in: size, padding: RoomPlanDrawing.Metrics.framePadding)
    }
}

/// Draws a `RoomPlanScene` into a canvas: the Design System's "Room plan".
enum RoomPlanDrawing {
    // MARK: Shared with the editor

    static func glyphSide(of speaker: RoomPlanContent.Speaker, fit: PlanFit) -> CGFloat {
        let drawn = speaker.size.width.isFinite ? fit.length(abs(speaker.size.width)) : 0
        return max(Metrics.minimumGlyph, drawn)
    }

    static func ringRadius(side: CGFloat) -> CGFloat { max(side / 2 + Metrics.ringGap, Metrics.selectionRingMinimum) }

    /// Where the rotate handle of a selected speaker is, in points.
    static func handleCentre(of centre: CGPoint, facing: Double, side: CGFloat) -> CGPoint {
        let direction = RoomPlanGeometry.forward(facing: facing)
        let distance = ringRadius(side: side) + Metrics.handleGap
        return CGPoint(x: centre.x + direction.dx * distance, y: centre.y + direction.dy * distance)
    }

    /// The glyph of a speaker centred on the origin and facing up; turn and move it with a transform.
    static func glyph(kind: RoomPlanContent.Speaker.Kind, side: CGFloat) -> (body: Path, mark: Path) {
        let half = side / 2
        switch kind {
        case .speaker:
            var mark = Path()
            mark.move(to: CGPoint(x: -side * Metrics.notchHalf, y: -half + Metrics.notchInset))
            mark.addLine(to: CGPoint(x: side * Metrics.notchHalf, y: -half + Metrics.notchInset))
            return (Path(roundedRect: CGRect(x: -half, y: -half, width: side, height: side), cornerRadius: Metrics.glyphRadius), mark)
        case .subwoofer:
            let inner = side * Metrics.driverRatio / 2
            return (Path(ellipseIn: CGRect(x: -half, y: -half, width: side, height: side)),
                    Path(ellipseIn: CGRect(x: -inner, y: -inner, width: inner * 2, height: inner * 2)))
        }
    }

    static func transform(at centre: CGPoint, facing: Double) -> CGAffineTransform {
        CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: CGFloat((facing.isFinite ? facing : 0) * .pi / 180))
    }

    // MARK: Draw

    static func draw(_ scene: RoomPlanScene, fit: PlanFit, size: CGSize, in context: inout GraphicsContext) {
        let content = scene.content
        let frame = CGRect(origin: .zero, size: size)
        let pt = fit.point

        // Problem areas under everything.
        for area in content.problemAreas { drawProblemArea(area, fit: fit, in: &context) }

        // Furniture.
        for item in content.furniture where RoomPlanGeometry.isFinite(item.centre) {
            let local = Path(roundedRect: CGRect(x: -fit.length(item.size.width) / 2, y: -fit.length(item.size.height) / 2,
                                                 width: fit.length(item.size.width), height: fit.length(item.size.height)),
                             cornerRadius: min(Metrics.furnitureRadius, fit.length(min(item.size.width, item.size.height)) / 2))
            context.stroke(local.applying(transform(at: pt(item.centre), facing: item.angle)), with: .color(ResoniqColor.muted), lineWidth: Metrics.furnitureStroke)
        }

        // Walls, then the cuts and marks that sit in them.
        let wallStyle = StrokeStyle(lineWidth: ResoniqSize.strokeWall, lineCap: .round, lineJoin: .round)
        for wall in content.walls where RoomPlanGeometry.isFinite(wall) {
            context.stroke(line(pt(wall.a), pt(wall.b)), with: .color(ResoniqColor.ivory), style: wallStyle)
        }
        for window in content.windows where RoomPlanGeometry.isFinite(window) {
            drawWindow(window, fit: fit, background: scene.background, in: &context)
        }
        for door in content.doors where RoomPlanGeometry.isFinite(door.leaf) {
            drawDoor(door, fit: fit, background: scene.background, in: &context)
        }

        // Suggestions: outline, dimension, turn.
        var labels: [LabelItem] = []
        var obstacles: [CGRect] = []
        let centre = pt(CGPoint(x: (RoomPlanGeometry.bounds(of: content) ?? .zero).midX, y: (RoomPlanGeometry.bounds(of: content) ?? .zero).midY))
        for suggestion in content.suggestions {
            guard let speaker = content.speakers.first(where: { $0.id == suggestion.speakerID }),
                  RoomPlanGeometry.isFinite(suggestion.target) else { continue }
            drawSuggestion(suggestion, speaker: speaker, scene: scene, fit: fit, planCentre: centre, labels: &labels, in: &context)
        }

        // Measured spots.
        for spot in content.measuredSpots where RoomPlanGeometry.isFinite(spot) {
            let at = pt(spot)
            context.fill(Path(ellipseIn: CGRect(x: at.x - Metrics.spotRadius, y: at.y - Metrics.spotRadius, width: Metrics.spotRadius * 2, height: Metrics.spotRadius * 2)), with: .color(ResoniqColor.ivory))
            obstacles.append(CGRect(x: at.x - Metrics.spotRadius, y: at.y - Metrics.spotRadius, width: Metrics.spotRadius * 2, height: Metrics.spotRadius * 2))
        }

        // Speakers.
        for speaker in content.speakers {
            let position = scene.position(of: speaker)
            guard RoomPlanGeometry.isFinite(position) else { continue }
            let at = pt(position)
            let side = glyphSide(of: speaker, fit: fit)
            let selected = scene.selectedID == speaker.id
            let facing = scene.facing(of: speaker)
            obstacles.append(CGRect(x: at.x - side / 2, y: at.y - side / 2, width: side, height: side))
            if scene.hiddenSpeakerID != speaker.id {
                drawSpeaker(speaker.kind, at: at, side: side, facing: facing, selected: selected, in: &context)
            }
            if selected && scene.showsHandle { drawHandle(at: at, side: side, facing: facing, in: &context) }
            labels.append(LabelItem(
                text: speaker.label, font: ResoniqFont.captionSemibold, color: selected ? ResoniqColor.lime : ResoniqColor.ivory,
                anchor: at, offset: side / 2 + Metrics.labelGap,
                sides: at.x >= centre.x ? [.right, .left, .below, .above] : [.left, .right, .below, .above],
                ownObstacle: obstacles.count - 1, priority: 0
            ))
        }

        // Seats.
        for seat in content.seats {
            let position = scene.position(of: seat)
            guard RoomPlanGeometry.isFinite(position) else { continue }
            let at = pt(position)
            let selected = scene.selectedID == seat.id
            drawSeat(at: at, selected: selected, in: &context)
            obstacles.append(CGRect(x: at.x - Metrics.seatRing, y: at.y - Metrics.seatRing, width: Metrics.seatRing * 2, height: Metrics.seatRing * 2))
            labels.append(LabelItem(
                text: seat.label, font: Metrics.seatFont, color: selected ? ResoniqColor.lime : ResoniqColor.muted,
                anchor: at, offset: Metrics.seatRing + Metrics.labelGap, sides: [.below, .above, .right, .left],
                ownObstacle: obstacles.count - 1, priority: 4
            ))
        }

        // The distance from the selected item to its nearest wall.
        if let distance = scene.selectedDistance, RoomPlanGeometry.isFinite(distance.wallPoint),
           let selectedID = scene.selectedID, let from = selectedPoint(selectedID, scene: scene, fit: fit) {
            let wall = pt(distance.wallPoint)
            let side = scene.content.speakers.first(where: { $0.id == selectedID }).map { glyphSide(of: $0, fit: fit) } ?? Metrics.seatRing * 2
            let direction = unit(from: from, to: wall)
            let start = CGPoint(x: from.x + direction.dx * (ringRadius(side: side) + Metrics.dimensionGap), y: from.y + direction.dy * (ringRadius(side: side) + Metrics.dimensionGap))
            drawDimension(from: start, to: wall, in: &context)
            labels.append(LabelItem(
                text: distance.label, font: ResoniqFont.axis, color: ResoniqColor.guide,
                anchor: CGPoint(x: (start.x + wall.x) / 2, y: (start.y + wall.y) / 2), offset: Metrics.labelGap,
                sides: [.right, .left, .above, .below], ownObstacle: nil, priority: 2
            ))
        }

        // Labels of problem areas and furniture.
        for area in content.problemAreas {
            guard let label = area.label, let box = boundingBox(RoomPlanGeometry.polygon(of: area.shape).map(pt)) else { continue }
            labels.append(LabelItem(
                text: label, font: ResoniqFont.axis, color: ResoniqColor.signalText,
                anchor: CGPoint(x: box.maxX, y: box.minY), offset: Metrics.problemLabelGap, sides: [.right, .above, .left, .below],
                ownObstacle: nil, priority: 1
            ))
        }
        for item in content.furniture {
            guard let label = item.label, RoomPlanGeometry.isFinite(item.centre) else { continue }
            labels.append(LabelItem(
                text: label, font: Metrics.seatFont, color: ResoniqColor.muted,
                anchor: pt(item.centre), offset: 0, sides: [.centre], ownObstacle: nil, priority: 5
            ))
        }

        drawLabels(labels, obstacles: obstacles, walls: content.walls.filter(RoomPlanGeometry.isFinite).map { (pt($0.a), pt($0.b)) },
                   frame: frame, background: scene.background, in: &context)
    }

    // MARK: Pieces

    private static func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    private static func unit(from a: CGPoint, to b: CGPoint) -> CGVector {
        let dx = b.x - a.x, dy = b.y - a.y
        let distance = hypot(dx, dy)
        return distance > 1e-9 ? CGVector(dx: dx / distance, dy: dy / distance) : CGVector(dx: 0, dy: 0)
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect? {
        let finite = points.filter(RoomPlanGeometry.isFinite)
        guard let minX = finite.map(\.x).min(), let maxX = finite.map(\.x).max(),
              let minY = finite.map(\.y).min(), let maxY = finite.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func selectedPoint(_ id: String, scene: RoomPlanScene, fit: PlanFit) -> CGPoint? {
        if let speaker = scene.content.speakers.first(where: { $0.id == id }) { return fit.point(scene.position(of: speaker)) }
        if let seat = scene.content.seats.first(where: { $0.id == id }) { return fit.point(scene.position(of: seat)) }
        return nil
    }

    private static func drawProblemArea(_ area: RoomPlanContent.ProblemArea, fit: PlanFit, in context: inout GraphicsContext) {
        let metres = RoomPlanGeometry.polygon(of: area.shape)
        guard metres.count >= 3, metres.allSatisfy(RoomPlanGeometry.isFinite) else { return }
        let polygon = metres.map(fit.point)
        var outline = Path()
        outline.addLines(polygon)
        outline.closeSubpath()
        var hatch = Path()
        for (from, to) in RoomPlanGeometry.hatchLines(in: polygon, spacing: Metrics.hatchSpacing, angle: Metrics.hatchAngle) {
            hatch.move(to: from)
            hatch.addLine(to: to)
        }
        context.stroke(hatch, with: .color(ResoniqColor.signal.opacity(Metrics.hatchOpacity)), style: StrokeStyle(lineWidth: Metrics.hatchStroke, lineCap: .butt))
        context.stroke(outline, with: .color(ResoniqColor.signal), style: StrokeStyle(lineWidth: Metrics.problemStroke, lineJoin: .round))
    }

    private static func drawWindow(_ window: RoomPlanContent.Segment, fit: PlanFit, background: Color, in context: inout GraphicsContext) {
        let a = fit.point(window.a), b = fit.point(window.b)
        context.stroke(line(a, b), with: .color(background), style: StrokeStyle(lineWidth: Metrics.wallGap, lineCap: .butt))
        for offset in [-Metrics.windowOffset, Metrics.windowOffset] {
            let (p, q) = RoomPlanGeometry.offsetLine(from: a, to: b, by: offset)
            context.stroke(line(p, q), with: .color(ResoniqColor.ivory), style: StrokeStyle(lineWidth: Metrics.windowStroke, lineCap: .butt))
        }
    }

    private static func drawDoor(_ door: RoomPlanContent.Door, fit: PlanFit, background: Color, in context: inout GraphicsContext) {
        let hinge = fit.point(door.leaf.a), tip = fit.point(door.leaf.b)
        context.stroke(line(hinge, tip), with: .color(background), style: StrokeStyle(lineWidth: Metrics.wallGap, lineCap: .butt))
        let open = fit.point(RoomPlanGeometry.doorOpenTip(door))
        let start = RoomPlanGeometry.facing(from: hinge, to: tip) ?? 0
        let end = RoomPlanGeometry.facing(from: hinge, to: open) ?? start
        let points = RoomPlanGeometry.arc(centre: hinge, radius: hypot(tip.x - hinge.x, tip.y - hinge.y), from: start, to: end)
        guard let first = points.first else { return }
        var arc = Path()
        arc.move(to: first)
        for point in points.dropFirst() { arc.addLine(to: point) }
        context.stroke(arc, with: .color(ResoniqColor.muted), style: StrokeStyle(lineWidth: ResoniqSize.strokeHairline, lineCap: .round, dash: Metrics.doorDash))
    }

    static func drawSpeaker(
        _ kind: RoomPlanContent.Speaker.Kind, at centre: CGPoint, side: CGFloat, facing: Double, selected: Bool,
        in context: inout GraphicsContext
    ) {
        let colour = selected ? ResoniqColor.lime : ResoniqColor.ivory
        if selected {
            let radius = ringRadius(side: side)
            context.stroke(
                Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(ResoniqColor.lime), style: StrokeStyle(lineWidth: Metrics.selectionStroke, lineCap: .round, dash: Metrics.selectionDash)
            )
        }
        let (body, mark) = glyph(kind: kind, side: side)
        let placed = transform(at: centre, facing: facing)
        context.fill(body.applying(placed), with: .color(colour))
        switch kind {
        case .speaker:
            context.stroke(mark.applying(placed), with: .color(ResoniqColor.ink), style: StrokeStyle(lineWidth: Metrics.notchStroke, lineCap: .round))
        case .subwoofer:
            context.stroke(mark.applying(placed), with: .color(ResoniqColor.ink), lineWidth: Metrics.notchStroke)
        }
    }

    private static func drawSeat(at centre: CGPoint, selected: Bool, in context: inout GraphicsContext) {
        let colour = selected ? ResoniqColor.lime : ResoniqColor.ivory
        context.fill(Path(ellipseIn: CGRect(x: centre.x - Metrics.seatDot, y: centre.y - Metrics.seatDot, width: Metrics.seatDot * 2, height: Metrics.seatDot * 2)), with: .color(colour))
        context.stroke(
            Path(ellipseIn: CGRect(x: centre.x - Metrics.seatRing, y: centre.y - Metrics.seatRing, width: Metrics.seatRing * 2, height: Metrics.seatRing * 2)),
            with: .color(colour), style: StrokeStyle(lineWidth: Metrics.seatRingStroke, dash: selected ? Metrics.selectionDash : [])
        )
    }

    private static func drawHandle(at centre: CGPoint, side: CGFloat, facing: Double, in context: inout GraphicsContext) {
        let handle = handleCentre(of: centre, facing: facing, side: side)
        let direction = RoomPlanGeometry.forward(facing: facing)
        let ring = ringRadius(side: side)
        context.stroke(
            line(CGPoint(x: centre.x + direction.dx * ring, y: centre.y + direction.dy * ring), handle),
            with: .color(ResoniqColor.lime), lineWidth: Metrics.handleStem
        )
        let r = Metrics.handleRadius
        context.fill(Path(ellipseIn: CGRect(x: handle.x - r, y: handle.y - r, width: r * 2, height: r * 2)), with: .color(ResoniqColor.lime))
        let inner = Metrics.handleInner
        context.stroke(Path(ellipseIn: CGRect(x: handle.x - inner, y: handle.y - inner, width: inner * 2, height: inner * 2)), with: .color(ResoniqColor.ink), lineWidth: Metrics.notchStroke)
    }

    private static func drawDimension(from a: CGPoint, to b: CGPoint, in context: inout GraphicsContext) {
        var path = line(a, b)
        for (p, q) in RoomPlanGeometry.dimensionTicks(from: a, to: b, length: Metrics.tickLength) {
            path.move(to: p)
            path.addLine(to: q)
        }
        context.stroke(path, with: .color(ResoniqColor.guide), style: StrokeStyle(lineWidth: Metrics.dimensionStroke, lineCap: .round))
    }

    private static func drawSuggestion(
        _ suggestion: RoomPlanContent.Suggestion, speaker: RoomPlanContent.Speaker, scene: RoomPlanScene, fit: PlanFit,
        planCentre: CGPoint, labels: inout [LabelItem], in context: inout GraphicsContext
    ) {
        let side = glyphSide(of: speaker, fit: fit)
        let current = fit.point(scene.position(of: speaker))
        let target = fit.point(suggestion.target)
        let currentFacing = scene.facing(of: speaker)
        let targetFacing = suggestion.targetFacing ?? currentFacing

        // The dashed target outline; it marches while the app is guiding.
        let (body, _) = glyph(kind: speaker.kind, side: side)
        context.stroke(
            body.applying(transform(at: target, facing: targetFacing)), with: .color(ResoniqColor.guide),
            style: StrokeStyle(lineWidth: Metrics.outlineStroke, lineCap: .round, lineJoin: .round, dash: Metrics.outlineDash, dashPhase: scene.dashPhase)
        )

        // The dimension line from where it is now, moved to the inside of the room so it stays clear of the wall.
        if hypot(target.x - current.x, target.y - current.y) > 1 {
            let offset = side / 2 + Metrics.dimensionGap
            var best = RoomPlanGeometry.offsetLine(from: current, to: target, by: offset)
            let other = RoomPlanGeometry.offsetLine(from: current, to: target, by: -offset)
            func distance(_ line: (CGPoint, CGPoint)) -> CGFloat {
                hypot((line.0.x + line.1.x) / 2 - planCentre.x, (line.0.y + line.1.y) / 2 - planCentre.y)
            }
            if distance(other) < distance(best) { best = other }
            drawDimension(from: best.0, to: best.1, in: &context)
            if let label = suggestion.distanceLabel {
                labels.append(LabelItem(
                    text: label, font: ResoniqFont.axis, color: ResoniqColor.guide,
                    anchor: CGPoint(x: (best.0.x + best.1.x) / 2, y: (best.0.y + best.1.y) / 2), offset: Metrics.labelGap,
                    sides: [.right, .left, .above, .below], ownObstacle: nil, priority: 2
                ))
            }
        }

        // The turn.
        if suggestion.turnLabel != nil || abs(RoomPlanGeometry.normalised(degrees: targetFacing - currentFacing)) > 0.5 {
            let radius = side * Metrics.arcRatio + Metrics.arcGap
            let points = RoomPlanGeometry.arc(centre: target, radius: radius, from: currentFacing, to: targetFacing)
            if let first = points.first, points.count > 1 {
                var arc = Path()
                arc.move(to: first)
                for point in points.dropFirst() { arc.addLine(to: point) }
                context.stroke(arc, with: .color(ResoniqColor.guide), style: StrokeStyle(lineWidth: Metrics.arcStroke, lineCap: .round))
                if let label = suggestion.turnLabel {
                    labels.append(LabelItem(
                        text: label, font: ResoniqFont.axis, color: ResoniqColor.guide,
                        anchor: points[points.count / 2], offset: Metrics.labelGap,
                        sides: [.below, .right, .left, .above], ownObstacle: nil, priority: 3
                    ))
                }
            }
        }
    }

    // MARK: Labels

    struct LabelItem {
        var text: String
        var font: Font
        var color: Color
        var anchor: CGPoint
        var offset: CGFloat
        var sides: [RoomPlanGeometry.LabelSide]
        var ownObstacle: Int?
        var priority: Int
    }

    private static func drawLabels(
        _ items: [LabelItem], obstacles: [CGRect], walls: [(CGPoint, CGPoint)], frame: CGRect, background: Color,
        in context: inout GraphicsContext
    ) {
        let ordered = items.enumerated().sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }.map(\.element)
        let resolved = ordered.map { item in context.resolve(Text(item.text).font(item.font).foregroundStyle(item.color)) }
        let requests = zip(ordered, resolved).map { item, text in
            RoomPlanGeometry.LabelRequest(
                size: text.measure(in: CGSize(width: max(frame.width, 1), height: max(frame.height, 1))),
                anchor: item.anchor, sides: item.sides, offset: item.offset, ownObstacle: item.ownObstacle
            )
        }
        let rects = RoomPlanGeometry.place(requests, in: frame.insetBy(dx: Metrics.labelPlate.width, dy: Metrics.labelPlate.height), obstacles: obstacles, segments: walls)
        for (rect, text) in zip(rects, resolved) {
            context.fill(
                Path(roundedRect: rect.insetBy(dx: -Metrics.labelPlate.width, dy: -Metrics.labelPlate.height), cornerRadius: Metrics.labelRadius),
                with: .color(background.opacity(Metrics.labelPlateOpacity))
            )
            context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
        }
    }

    // MARK: Metrics

    /// Values from the mockups (V3Optimize, V3OLayout) that are not tokens.
    enum Metrics {
        /// Room to the frame's edge. The labels sit inside it.
        static let framePadding: CGFloat = 20
        static let minimumGlyph: CGFloat = 24
        static let glyphRadius: CGFloat = 3
        static let notchHalf: CGFloat = 0.2
        static let notchInset: CGFloat = 3.5
        static let notchStroke: CGFloat = 2
        static let driverRatio: CGFloat = 0.56
        static let spotRadius: CGFloat = 4.5
        static let seatDot: CGFloat = 7
        static let seatRing: CGFloat = 13
        static let seatRingStroke: CGFloat = 1.2
        static let furnitureStroke: CGFloat = 1.5
        static let furnitureRadius: CGFloat = 6
        static let wallGap: CGFloat = 4
        static let windowOffset: CGFloat = 3
        static let windowStroke: CGFloat = 1.5
        static let doorDash: [CGFloat] = [2, 4]
        static let hatchSpacing: CGFloat = 7
        static let hatchAngle: Double = 45
        static let hatchStroke: CGFloat = 2.2
        static let hatchOpacity: Double = 0.7
        static let problemStroke: CGFloat = 1.5
        static let outlineStroke: CGFloat = 2
        static let outlineDash: [CGFloat] = [4, 4]
        static let dimensionStroke: CGFloat = 1.5
        static let dimensionGap: CGFloat = 8
        static let tickLength: CGFloat = 12
        static let arcRatio: CGFloat = 0.8
        static let arcGap: CGFloat = 8
        static let arcStroke: CGFloat = 2.5
        static let selectionStroke: CGFloat = 2
        static let selectionDash: [CGFloat] = [4, 5]
        static let selectionRingMinimum: CGFloat = 22
        static let ringGap: CGFloat = 9
        static let handleGap: CGFloat = 14
        static let handleRadius: CGFloat = 8
        static let handleInner: CGFloat = 3
        static let handleStem: CGFloat = 1.5
        static let labelGap: CGFloat = 6
        static let problemLabelGap: CGFloat = 4
        static let labelPlate = CGSize(width: 4, height: 1)
        static let labelPlateOpacity: Double = 0.85
        static let labelRadius: CGFloat = 3
        static let seatFont = ResoniqFont.font(.sansRegular, size: 12, relativeTo: .caption)
    }
}
