#if DEBUG
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqRoom
import SwiftUI

/// The Optimize home, Confirm layout, manual room and Before and after screens with fixture data, for
/// `make run SCREEN=<name>` and screenshots. Debug builds only.
///
/// `optimize` is the mockup (measured, with a suggestion); `optimize-empty`, `optimize-room`, `optimize-nothing` and
/// `optimize-moved` are its other states; `layout` is a corrected layout, `layout-guess` the first guess after a scan
/// and `layout-3d` the 3D side; `manual-room` is entry by hand; `verify` is the mockup and `verify-worse` and
/// `verify-unchanged` the outcomes with no mockup.
enum OptimizeDebugScreens {
    static let names = [
        "optimize", "optimize-empty", "optimize-room", "optimize-nothing", "optimize-moved", "layout", "layout-guess",
        "layout-3d", "manual-room", "verify", "verify-worse", "verify-unchanged",
    ]

    @MainActor
    static func view(named name: String) -> AnyView? {
        switch name {
        case "optimize": AnyView(Home(state: OptimizeFixtures.homeSuggestion))
        case "optimize-empty": AnyView(Home(state: OptimizeFixtures.homeNoRoom))
        case "optimize-room": AnyView(Home(state: OptimizeFixtures.homeNotMeasured))
        case "optimize-nothing": AnyView(Home(state: OptimizeFixtures.homeNothing))
        case "optimize-moved": AnyView(Home(state: OptimizeFixtures.homeMoved))
        case "layout": AnyView(layout(OptimizeFixtures.room, isGuess: false))
        case "layout-guess": AnyView(layout(OptimizeFixtures.guessedRoom, isGuess: true))
        case "layout-3d": AnyView(layout(OptimizeFixtures.room, isGuess: false, startsIn3D: true))
        case "manual-room": AnyView(ManualRoomScreen(onDone: { _ in }, onClose: {}).preferredColorScheme(.dark))
        case "verify": AnyView(verify(OptimizeFixtures.improved, after: OptimizeFixtures.after))
        case "verify-worse": AnyView(verify(OptimizeFixtures.worse, after: OptimizeFixtures.worseAfter))
        case "verify-unchanged": AnyView(verify(OptimizeFixtures.unchanged, after: OptimizeFixtures.before))
        default: nil
        }
    }

    @MainActor
    private static func layout(_ room: RoomModel, isGuess: Bool, startsIn3D: Bool = false) -> some View {
        LayoutScreen(
            room: room, isGuess: isGuess, roomName: "Living room",
            onConfirm: { _ in }, onRescan: {}, startsIn3D: startsIn3D, onClose: {}
        )
        .preferredColorScheme(.dark)
    }

    @MainActor
    private static func verify(_ comparison: ComparisonReport, after: SeatReport) -> some View {
        VerifyScreen(
            comparison: comparison, before: OptimizeFixtures.before, after: after,
            onKeep: {}, onNextSuggestion: {}, onPutBack: {}, onClose: {}
        )
        .preferredColorScheme(.dark)
    }

    /// The home in the app's frame, with the tab bar, as it appears inside `RootView`.
    private struct Home: View {
        let state: OptimizeHomeState
        @State private var tab = AppTab.optimize

        var body: some View {
            VStack(spacing: 0) {
                OptimizeHomeView(
                    state: state, onScan: {}, onManualEntry: {}, onEditLayout: {}, onMeasure: {}, onGuideInAR: {},
                    onMoveMyself: {}, onShowVerification: {}, onRescan: {}
                )
                ResoniqTabBar(AppTab.allCases.map(\.item), selection: $tab)
            }
            .background(ResoniqColor.ink)
            .preferredColorScheme(.dark)
        }
    }
}
#endif
