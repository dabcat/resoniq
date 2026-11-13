#if DEBUG
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqRoom
import ResoniqStore
import SwiftUI

/// The Optimize home, Confirm layout, manual room and Before and after screens with fixture data, for
/// `make run SCREEN=<name>` and screenshots. Debug builds only.
///
/// `optimize` is the mockup (measured, with a suggestion); `optimize-empty`, `optimize-room`, `optimize-nothing` and
/// `optimize-moved` are its other states; `optimize-flow` is the real Optimize tab (with the Measure tab behind it) on an
/// in-memory store, simulated audio and the scripted scan and AR sources, seeded so it opens on "measured, with a
/// suggestion", and `optimize-flow-empty` the same with nothing stored. With `-autostart YES`, `optimize-flow` presses
/// "I'll move it myself, then re-measure" a second after the home appears, and the Measure flow's own autostart carries
/// the measurement through, so an unattended launch ends on Before and after; `layout` is a corrected layout, `layout-guess` the first guess after a scan
/// and `layout-3d` the 3D side; `manual-room` is entry by hand; `verify` is the mockup and `verify-worse` and
/// `verify-unchanged` the outcomes with no mockup.
enum OptimizeDebugScreens {
    static let names = [
        "optimize", "optimize-empty", "optimize-room", "optimize-nothing", "optimize-moved", "layout", "layout-guess",
        "layout-3d", "manual-room", "verify", "verify-worse", "verify-unchanged", "optimize-flow", "optimize-flow-empty",
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
        case "optimize-flow": AnyView(FlowHost(seeded: true))
        case "optimize-flow-empty": AnyView(FlowHost(seeded: false))
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

    /// The real tabs on an in-memory store: Optimize, and Measure for the seat measurement it hands over to.
    private struct FlowHost: View {
        let seeded: Bool
        @State private var composition: AppComposition?
        @State private var tab = AppTab.optimize

        var body: some View {
            Group {
                if let composition {
                    VStack(spacing: 0) {
                        TabView(selection: $tab) {
                            Tab(value: AppTab.diagnose) { ResoniqColor.ink.toolbarVisibility(.hidden, for: .tabBar) }
                            Tab(value: AppTab.measure) { MeasureTab().toolbarVisibility(.hidden, for: .tabBar) }
                            Tab(value: AppTab.optimize) { OptimizeTab().toolbarVisibility(.hidden, for: .tabBar) }
                        }
                        ResoniqTabBar(AppTab.allCases.map(\.item), selection: $tab)
                    }
                    .background(ResoniqColor.ink)
                    .environment(\.switchTab, SwitchTabAction { tab = $0 })
                    .appEnvironment(composition)
                    .task {
                        composition.optimize.showTab = { tab = $0 }
                        await autostartIfAsked(composition.optimize)
                    }
                } else {
                    StoreUnavailableScreen()
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                guard composition == nil else { return }
                let made = AppComposition.launch(
                    inMemory: true, audio: .simulated(noise: UserDefaults.standard.bool(forKey: "simulatedNoise")),
                    optimizeSources: .scripted)
                if seeded, let made { seed(made.store) }
                composition = made
            }
        }

        /// A manual 4.20 x 5.60 m room, confirmed, and the mockup's seat measurement kept in it.
        private func seed(_ store: ResoniqStore) {
            guard let (room, system) = try? store.defaultContext() else { return }
            try? store.setLayout(OptimizeFixtures.room, for: room)
            _ = try? store.keep(OptimizeFixtures.before, in: system)
        }

        /// `-autostart YES`: the home has been on screen for a second, so press "I'll move it myself, then re-measure".
        private func autostartIfAsked(_ coordinator: OptimizeCoordinator) async {
            guard seeded, UserDefaults.standard.bool(forKey: "autostart") else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let suggestion = coordinator.currentSuggestion() else { return }
            coordinator.moveMyself(suggestion)
        }
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

extension OptimizeSources {
    /// The simulator's stand-ins for RoomPlan and ARKit: a scripted scan and a scripted whole move.
    static let scripted = OptimizeSources(
        scanReadiness: { .ready },
        makeScanSource: { ScriptedRoomScanSource() },
        arReadiness: { .ready },
        makeARSource: { ScriptedARGuidanceSource(script: .whole) },
        makeARHaptics: { SilentARGuidanceHaptics() })
}
#endif
