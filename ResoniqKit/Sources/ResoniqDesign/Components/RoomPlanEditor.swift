import SwiftUI

/// The room plan made editable (V3OLayout): tap a speaker or the seat to select it, drag it to move it, and turn a
/// selected speaker by its handle.
///
/// The editor decides nothing. It reports the position a drag proposes, in metres, through `onMove`, and draws the
/// position that closure returns, so the caller (the Kit) can hold an item inside the walls. A drag that the caller
/// does not store springs back when the finger lifts. `onRotate` does the same for a facing in degrees.
///
/// The selected item shows `distance` (V3OLayout "0.90 m") with a dimension line to the wall point supplied.
///
/// Without dragging: every speaker and seat is an element for VoiceOver with the actions "Move left", "Move right",
/// "Move forward", "Move back" (10 cm each, as the item sees it: forward is the way it faces) and, for speakers,
/// "Turn 5° right" and "Turn 5° left". They call the same two closures. Touch targets are at least 44 pt whatever
/// the scale. The plan takes the touches on it, so it does not scroll under a finger.
public struct RoomPlanEditor: View {
    /// A step of the VoiceOver "Move" actions, in metres.
    public static let moveStep = 0.10
    /// A step of the VoiceOver "Turn" actions, in degrees.
    public static let turnStep = 5.0

    private let content: RoomPlanContent
    @Binding private var selection: String?
    private let distance: RoomPlanWallDistance?
    private let height: CGFloat?
    private let accessibilityText: String
    private let onMove: (String, CGPoint) -> CGPoint
    private let onRotate: (String, Double) -> Double

    @State private var drag: DragState?
    @State private var positions: [String: CGPoint] = [:]
    @State private var facings: [String: Double] = [:]

    /// - Parameters:
    ///   - selection: The id of the selected speaker or seat.
    ///   - distance: The distance from the selected item to its nearest wall.
    ///   - height: The panel's height; V3OLayout's is 340. Pass nil to fill the height offered.
    ///   - accessibilityLabel: One sentence that states what the plan shows.
    ///   - onMove: Gets the id and the proposed position in metres; returns the position to draw.
    ///   - onRotate: Gets the id and the proposed facing in degrees; returns the facing to draw.
    public init(
        _ content: RoomPlanContent,
        selection: Binding<String?>,
        distance: RoomPlanWallDistance? = nil,
        height: CGFloat? = 340,
        accessibilityLabel: String,
        onMove: @escaping (String, CGPoint) -> CGPoint,
        onRotate: @escaping (String, Double) -> Double
    ) {
        self.content = content
        _selection = selection
        self.distance = distance
        self.height = height
        self.accessibilityText = accessibilityLabel
        self.onMove = onMove
        self.onRotate = onRotate
    }

    private enum DragState {
        /// `grab` is the offset from the touch to the item's centre, in metres, so the item does not jump.
        case move(id: String, grab: CGVector, start: CGPoint)
        case rotate(id: String, start: CGPoint)
        case background(start: CGPoint)

        var start: CGPoint {
            switch self {
            case .move(_, _, let start), .rotate(_, let start), .background(let start): start
            }
        }
    }

    private var scene: RoomPlanScene {
        let speaker = content.speakers.first { $0.id == selection }
        return RoomPlanScene(
            content: content, positions: positions, facings: facings, selectedID: selection,
            selectedDistance: selection == nil ? nil : distance, showsHandle: speaker != nil
        )
    }

    public var body: some View {
        RoomPlanCanvas(scene: scene, isSuggestionAnimating: false) { fit, _ in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(fit: fit))
                accessibilityItems(fit: fit)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(ResoniqColor.panel, in: RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous)
                .strokeBorder(ResoniqColor.line, lineWidth: ResoniqSize.strokeHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .sensoryFeedback(.selection, trigger: selection)
    }

    // MARK: Dragging

    private func targets(fit: PlanFit) -> [RoomPlanGeometry.Target] {
        var result: [RoomPlanGeometry.Target] = []
        for speaker in content.speakers {
            let position = positions[speaker.id] ?? speaker.position
            guard RoomPlanGeometry.isFinite(position) else { continue }
            let centre = fit.point(position)
            let side = RoomPlanDrawing.glyphSide(of: speaker, fit: fit)
            result.append(.init(id: speaker.id, kind: .item, centre: centre, halfSide: side / 2))
            if speaker.id == selection {
                let facing = facings[speaker.id] ?? speaker.facing
                result.append(.init(
                    id: speaker.id, kind: .rotateHandle,
                    centre: RoomPlanDrawing.handleCentre(of: centre, facing: facing, side: side),
                    halfSide: RoomPlanDrawing.Metrics.handleRadius
                ))
            }
        }
        for seat in content.seats {
            let position = positions[seat.id] ?? seat.position
            guard RoomPlanGeometry.isFinite(position) else { continue }
            result.append(.init(id: seat.id, kind: .item, centre: fit.point(position), halfSide: RoomPlanDrawing.Metrics.seatRing))
        }
        return result
    }

    private func dragGesture(fit: PlanFit) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil { begin(at: value.startLocation, fit: fit) }
                guard let drag, hypot(value.location.x - drag.start.x, value.location.y - drag.start.y) > Metrics.slop else { return }
                switch drag {
                case .move(let id, let grab, _):
                    let touch = fit.metres(value.location)
                    positions[id] = onMove(id, CGPoint(x: touch.x + grab.dx, y: touch.y + grab.dy))
                case .rotate(let id, _):
                    guard let speaker = content.speakers.first(where: { $0.id == id }),
                          let facing = RoomPlanGeometry.facing(from: fit.point(positions[id] ?? speaker.position), to: value.location)
                    else { return }
                    facings[id] = onRotate(id, facing)
                case .background:
                    break
                }
            }
            .onEnded { value in
                if case .background(let start) = drag, hypot(value.location.x - start.x, value.location.y - start.y) <= Metrics.slop {
                    selection = nil
                }
                drag = nil
                positions = [:]
                facings = [:]
            }
    }

    private func begin(at point: CGPoint, fit: PlanFit) {
        guard let hit = RoomPlanGeometry.hit(at: point, targets: targets(fit: fit)) else {
            drag = .background(start: point)
            return
        }
        selection = hit.id
        switch hit.kind {
        case .rotateHandle:
            drag = .rotate(id: hit.id, start: point)
        case .item:
            let touch = fit.metres(point)
            let item = fit.metres(hit.centre)
            drag = .move(id: hit.id, grab: CGVector(dx: item.x - touch.x, dy: item.y - touch.y), start: point)
        }
    }

    // MARK: Accessibility

    private func accessibilityItems(fit: PlanFit) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(content.speakers) { speaker in
                let position = speaker.position
                if RoomPlanGeometry.isFinite(position) {
                    item(
                        id: speaker.id, label: speaker.kind == .subwoofer ? speaker.label : "\(speaker.label) speaker",
                        position: position, facing: speaker.facing, turns: true, fit: fit
                    )
                }
            }
            ForEach(content.seats) { seat in
                if RoomPlanGeometry.isFinite(seat.position) {
                    item(id: seat.id, label: seat.label, position: seat.position, facing: 0, turns: false, fit: fit)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func item(id: String, label: String, position: CGPoint, facing: Double, turns: Bool, fit: PlanFit) -> some View {
        let isSelected = selection == id
        return Color.clear
            .frame(width: ResoniqSize.touchMin, height: ResoniqSize.touchMin)
            .position(fit.point(position))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(isSelected ? (distance.map { "\($0.label) to the nearest wall" } ?? "Selected") : "")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selection = id }
            .accessibilityAction(named: "Move left 10 cm") { move(id, .left, from: position, facing: facing) }
            .accessibilityAction(named: "Move right 10 cm") { move(id, .right, from: position, facing: facing) }
            .accessibilityAction(named: "Move forward 10 cm") { move(id, .forward, from: position, facing: facing) }
            .accessibilityAction(named: "Move back 10 cm") { move(id, .back, from: position, facing: facing) }
            .accessibilityActions {
                if turns {
                    Button("Turn 5\u{00B0} right") { turn(id, by: Self.turnStep, from: facing) }
                    Button("Turn 5\u{00B0} left") { turn(id, by: -Self.turnStep, from: facing) }
                }
            }
    }

    private func move(_ id: String, _ direction: RoomPlanGeometry.Move, from position: CGPoint, facing: Double) {
        selection = id
        let step = RoomPlanGeometry.moveVector(direction, facing: facing, step: Self.moveStep)
        _ = onMove(id, CGPoint(x: position.x + step.dx, y: position.y + step.dy))
    }

    private func turn(_ id: String, by degrees: Double, from facing: Double) {
        selection = id
        _ = onRotate(id, RoomPlanGeometry.normalised(degrees: facing + degrees))
    }

    private enum Metrics {
        /// A touch that moves less than this is a tap.
        static let slop: CGFloat = 4
    }
}

#if DEBUG
#Preview("Room editor") {
    @Previewable @State var content = RoomPlanContent.sampleMeasured
    @Previewable @State var selection: String? = "right"
    ScrollView {
        VStack(spacing: ResoniqSpace.s4) {
            RoomPlanEditor(
                content,
                selection: $selection,
                distance: RoomPlanWallDistance(label: "0.90 m", wallPoint: CGPoint(x: 3.4, y: 0)),
                accessibilityLabel: "Room plan with the left and right speakers and the seat. The right speaker is selected.",
                onMove: { id, proposed in
                    let clamped = CGPoint(x: min(max(proposed.x, 0.2), 4.0), y: min(max(proposed.y, 0.2), 5.4))
                    if let index = content.speakers.firstIndex(where: { $0.id == id }) { content.speakers[index].position = clamped }
                    if let index = content.seats.firstIndex(where: { $0.id == id }) { content.seats[index].position = clamped }
                    return clamped
                },
                onRotate: { id, facing in
                    if let index = content.speakers.firstIndex(where: { $0.id == id }) { content.speakers[index].facing = facing }
                    return facing
                }
            )
            RoomPlanEditor(
                .sampleMeasured, selection: .constant(nil), height: 240,
                accessibilityLabel: "Nothing selected.", onMove: { $1 }, onRotate: { $1 }
            )
        }
        .padding(ResoniqSpace.screenInset)
    }
    .background(ResoniqColor.ink)
}
#endif
