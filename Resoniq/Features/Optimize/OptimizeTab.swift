import ResoniqDesign
import ResoniqRoom
import SwiftUI

/// The Optimize tab: home, and over it, without the tab bar, the full-screen cover that holds the scan, manual entry,
/// Confirm layout, the AR guide or Before and after. `OptimizeCoordinator` decides what is shown and what is stored;
/// this only lays it out.
struct OptimizeTab: View {
    @Environment(OptimizeCoordinator.self) private var coordinator

    var body: some View {
        OptimizeHomeContainer(
            onScan: coordinator.scan,
            onManualEntry: coordinator.enterByHand,
            onEditLayout: coordinator.editLayout,
            onMeasure: coordinator.measureFromSeat,
            onGuideInAR: coordinator.guideInAR,
            onMoveMyself: coordinator.moveMyself,
            onShowVerification: coordinator.showVerification,
            onRescan: coordinator.scan
        )
        .fullScreenCover(
            isPresented: Binding(
                get: { coordinator.cover != nil },
                set: { if !$0 { coordinator.closeCover() } }
            ),
            onDismiss: coordinator.coverDismissed
        ) {
            OptimizeCover()
        }
        // An alert with no cover up is shown here; with a cover up, on the cover.
        .optimizeAlert(coordinator, whenCoverIsUp: false)
    }
}

// MARK: - The cover

private struct OptimizeCover: View {
    @Environment(OptimizeCoordinator.self) private var coordinator

    var body: some View {
        Group {
            switch coordinator.cover {
            case .scan:
                ScanScreen(
                    readiness: coordinator.sources.scanReadiness(), makeSource: coordinator.sources.makeScanSource,
                    onScanned: coordinator.scanned, onManualEntry: { coordinator.showManualEntry() },
                    onClose: { coordinator.closeCover() })
            case .manualRoom(let initial):
                ManualRoomScreen(
                    initial: initial, onDone: coordinator.manualRoomMade, onClose: { coordinator.closeCover() })
            case .layout(let draft):
                LayoutScreen(
                    room: draft.room, isGuess: draft.isGuess, roomName: roomName,
                    onConfirm: coordinator.confirmLayout, onRescan: coordinator.scanAgain,
                    // A hand-entered room reopens manual entry; a scanned one offers a new scan.
                    onManualEntry: draft.room.source == .manual
                        ? { coordinator.showManualEntry(starting: coordinator.manualRoom(of: draft.room)) } : nil,
                    onClose: { coordinator.closeCover() })
            case .guide(let request):
                ARGuidanceScreen(
                    suggestion: request.suggestion, room: request.room, readiness: coordinator.sources.arReadiness(),
                    source: coordinator.sources.makeARSource(), haptics: coordinator.sources.makeARHaptics(),
                    onPlaced: { coordinator.placed($0, in: request) }, onDeclined: { coordinator.declined(request) },
                    onClose: { coordinator.closeCover() })
            case .verification(let verification):
                VerifyScreen(
                    comparison: verification.comparison, before: verification.before, after: verification.after,
                    onKeep: { coordinator.keep(verification) }, onNextSuggestion: { coordinator.keep(verification) },
                    onPutBack: { coordinator.putBack(verification) }, onClose: { coordinator.closeCover() })
            case nil:
                // The cover is on its way out.
                ResoniqColor.ink.ignoresSafeArea()
            }
        }
        .id(coordinator.coverID)
        .background(ResoniqColor.ink)
        .preferredColorScheme(.dark)
        // VoiceOver starts at the top of each new screen.
        .onChange(of: coordinator.coverID) {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
        .optimizeAlert(coordinator, whenCoverIsUp: true)
    }

    /// The room's name for Confirm layout's header.
    private var roomName: String { coordinator.roomName }
}

// MARK: - Alerts

private extension View {
    /// The coordinator's alert, shown by whichever of the tab and its cover is on top.
    func optimizeAlert(_ coordinator: OptimizeCoordinator, whenCoverIsUp: Bool) -> some View {
        let shown = Binding(
            get: { coordinator.alert != nil && (coordinator.cover != nil) == whenCoverIsUp },
            set: { if !$0 { coordinator.alert = nil } }
        )
        return alert(coordinator.alert?.title ?? "", isPresented: shown) {
            Button(OptimizeText.alertOK, role: .cancel) { coordinator.alert = nil }
        } message: {
            Text(coordinator.alert?.message ?? "")
        }
    }
}
