import ResoniqDesign
import ResoniqRoom
import ResoniqStore
import SwiftUI

/// Confirm layout (design/screens/V3OLayout.dc.html): "Is this where everything really is?" The room plan with the
/// speakers and the seat, which can be dragged (or moved with VoiceOver's actions), the chips to add a subwoofer or
/// a seat or fix a wall, and "Looks right, measure the room".
///
/// The screen decides nothing about the room. A drag or a turn goes to the Kit's `moving` and `rotating`, and the
/// plan shows what the Kit returns, so an item stops at a wall or a piece of furniture. An item the person moved, or
/// that was there when they said "Looks right", comes back `isConfirmed`.
///
/// **Plan and 3D.** The 3D side is the same model drawn in an isometric-style projection in a `Canvas`, turned by
/// dragging (`Room3DView`); nothing is edited there, so it shows no chips.
///
/// **The hint.** After a scan the speakers and seat are guesses (RoomPlan cannot see speakers), so the hint is the
/// Kit's `RoomText.layoutGuessHint`; the mockup's "I spotted the speakers from the scan" over-claims and is not
/// used. Otherwise a plain "Drag a speaker or your seat to correct it."
///
/// **Fix a wall** has no designed screen. A room entered by hand reopens manual entry (`onManualEntry`); a scanned
/// room offers to scan again (`onRescan`).
struct LayoutScreen: View {
    private let roomName: String
    private let isGuess: Bool
    private let onConfirm: (RoomModel) -> Void
    private let onRescan: () -> Void
    private let onManualEntry: (() -> Void)?
    private let onClose: () -> Void

    @State private var room: RoomModel
    @State private var selection: String?
    @State private var mode: ViewKind
    @State private var isAskingAboutWall = false

    private enum ViewKind: Hashable { case plan, threeD }

    /// - Parameters:
    ///   - room: The scanned or hand-entered room, with its guessed speakers and seat.
    ///   - isGuess: The speakers and seat were guessed (after a scan), so the hint says so.
    ///   - roomName: The room's name, for the header.
    ///   - onConfirm: "Looks right": the room as it now is, every item confirmed.
    ///   - onRescan: Scan again (the scanned room's "Fix a wall").
    ///   - startsIn3D: Open on the 3D side (previews and debug screens).
    ///   - onManualEntry: Reopen manual entry (a hand-entered room's "Fix a wall"). Without it that chip offers a scan.
    init(
        room: RoomModel,
        isGuess: Bool,
        roomName: String = StoreText.defaultRoomName,
        onConfirm: @escaping (RoomModel) -> Void,
        onRescan: @escaping () -> Void,
        onManualEntry: (() -> Void)? = nil,
        startsIn3D: Bool = false,
        onClose: @escaping () -> Void
    ) {
        _room = State(initialValue: room)
        _mode = State(initialValue: startsIn3D ? .threeD : .plan)
        self.isGuess = isGuess
        self.roomName = roomName
        self.onConfirm = onConfirm
        self.onRescan = onRescan
        self.onManualEntry = onManualEntry
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: ResoniqSpace.s4) {
            ScrollView {
                VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
                    header
                    Text(OptimizeText.layoutQuestion)
                        .resoniqTitle(.medium)
                        .accessibilityAddTraits(.isHeader)
                    viewPanel
                    if mode == .plan { chips }
                    hint
                    if let removal { removal.buttonStyle(ResoniqInlineLinkStyle(.quiet)) }
                }
                .padding(.horizontal, ResoniqSpace.screenInset)
            }
            .scrollIndicators(.hidden)

            Button(OptimizeText.confirmLayout) { onConfirm(RoomDisplay.confirmed(room)) }
                .buttonStyle(ResoniqPrimaryButtonStyle())
                .padding(.horizontal, ResoniqSpace.screenInset)
        }
        .padding(.top, ResoniqSpace.s3)
        .padding(.bottom, ResoniqSpace.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ResoniqColor.ink)
        .accessibilityAction(.escape, onClose)
        .confirmationDialog(OptimizeText.fixWallMessage, isPresented: $isAskingAboutWall, titleVisibility: .visible) {
            Button(OptimizeText.scanAgain, action: onRescan)
            Button(OptimizeText.cancel, role: .cancel) {}
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: ResoniqSpace.s3) {
            Button(action: onClose) {
                ResoniqIconView(.back)
            }
            .buttonStyle(ResoniqIconButtonStyle())
            .accessibilityLabel(OptimizeText.back)

            Text(RoomDisplay.title(of: room, name: roomName))
                .resoniqCapsLabel()
                .frame(maxWidth: .infinity, alignment: .leading)

            ResoniqSegmentedControl(
                [
                    ResoniqSegment(ViewKind.plan, title: OptimizeText.planSegment),
                    ResoniqSegment(ViewKind.threeD, title: OptimizeText.threeDSegment),
                ],
                selection: $mode, label: OptimizeText.viewLabel
            )
            .frame(width: Metrics.segmentedWidth)
        }
    }

    // MARK: Plan and 3D

    @ViewBuilder
    private var viewPanel: some View {
        switch mode {
        case .plan:
            RoomPlanEditor(
                RoomDisplay.content(of: room),
                selection: $selection,
                distance: RoomDisplay.wallDistance(of: selection, in: room),
                height: Metrics.planHeight,
                accessibilityLabel: RoomDisplay.layoutSummary(of: room),
                onMove: { id, proposed in
                    guard let moved = RoomDisplay.move(id, to: proposed, in: room) else { return proposed }
                    room = moved.room
                    return moved.position
                },
                onRotate: { id, degrees in
                    guard let turned = RoomDisplay.turn(id, toScreenDegrees: degrees, in: room) else { return degrees }
                    room = turned.room
                    return turned.degrees
                }
            )
        case .threeD:
            Room3DView(room: room, height: Metrics.planHeight)
        }
    }

    // MARK: Chips, hint, removal

    private var chips: some View {
        // Wraps under large text rather than clipping.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ResoniqSpace.s2) { chipButtons }
            VStack(alignment: .leading, spacing: ResoniqSpace.s2) { chipButtons }
        }
    }

    @ViewBuilder
    private var chipButtons: some View {
        ResoniqChip(OptimizeText.addSubwoofer) {
            if let added = RoomDisplay.addingSubwoofer(to: room) {
                room = added.room
                selection = added.id
            }
        }
        ResoniqChip(OptimizeText.addSeat) {
            if let added = RoomDisplay.addingSeat(to: room) {
                room = added.room
                selection = added.id
            }
        }
        ResoniqChip(OptimizeText.fixWall) {
            if room.source == .manual, let onManualEntry {
                onManualEntry()
            } else {
                isAskingAboutWall = true
            }
        }
    }

    private var hint: some View {
        Text(mode == .threeD ? OptimizeText.threeDHint : (isGuess ? RoomText.layoutGuessHint : OptimizeText.dragHint))
            .font(ResoniqFont.body)
            .foregroundStyle(ResoniqColor.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Remove this subwoofer" / "Remove this seat", for what the person added. The first seat and the speakers of
    /// the pair stay: the measurement needs them.
    private var removal: Button<Text>? {
        guard mode == .plan, let selection, let id = UUID(uuidString: selection) else { return nil }
        if room.speaker(id)?.role == .subwoofer {
            return Button(OptimizeText.removeSubwoofer) { remove(id) }
        }
        if room.seat(id) != nil, room.seats.count > 1, room.primarySeat?.id != id {
            return Button(OptimizeText.removeSeat) { remove(id) }
        }
        return nil
    }

    private func remove(_ id: UUID) {
        room = room.removing(id).room
        selection = nil
    }

    private enum Metrics {
        /// V3OLayout's plan panel is 340 pt tall.
        static let planHeight: CGFloat = 340
        /// The two segments, "Plan" and "3D".
        static let segmentedWidth: CGFloat = 132
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Scanned, guessed") {
    LayoutScreen(
        room: OptimizeFixtures.guessedRoom, isGuess: true, roomName: "Living room",
        onConfirm: { _ in }, onRescan: {}, onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Corrected by hand") {
    LayoutScreen(
        room: OptimizeFixtures.room, isGuess: false, roomName: "Living room",
        onConfirm: { _ in }, onRescan: {}, onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Largest text") {
    LayoutScreen(
        room: OptimizeFixtures.room, isGuess: true, roomName: "Living room",
        onConfirm: { _ in }, onRescan: {}, onClose: {}
    )
    .environment(\.dynamicTypeSize, .accessibility2)
    .preferredColorScheme(.dark)
}

#Preview("3D") {
    Room3DView(room: OptimizeFixtures.room, height: 340)
        .padding(ResoniqSpace.screenInset)
        .background(ResoniqColor.ink)
        .preferredColorScheme(.dark)
}
#endif
