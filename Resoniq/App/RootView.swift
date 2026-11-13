import ResoniqDesign
import SwiftUI

nonisolated enum AppTab: String, Hashable, CaseIterable {
    case diagnose
    case measure
    case optimize

    var item: ResoniqTabItem<AppTab> {
        switch self {
        case .diagnose: ResoniqTabItem(self, title: "Diagnose", icon: .diagnose)
        case .measure: ResoniqTabItem(self, title: "Measure", icon: .measure)
        case .optimize: ResoniqTabItem(self, title: "Optimize", icon: .optimize)
        }
    }
}

/// How a tab asks the shell to show another tab ("It's the room" leads to Optimize), without reaching into its state.
/// `RootView` sets it; where nothing sets it, calling it does nothing.
struct SwitchTabAction {
    private let action: (AppTab) -> Void

    init(_ action: @escaping (AppTab) -> Void) {
        self.action = action
    }

    func callAsFunction(_ tab: AppTab) { action(tab) }
}

extension EnvironmentValues {
    @Entry var switchTab = SwitchTabAction { _ in }
}

/// The tab shell. The system tab bar is hidden and replaced by the design system's, as in the mockups;
/// `TabView` still keeps each tab's state while another is shown.
struct RootView: View {
    @State private var selection: AppTab = launchTab
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appLifecycle) private var lifecycle

    /// Debug builds open on the tab named by `-initialTab measure`, so `make run TAB=…` can show any tab.
    private static var launchTab: AppTab {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "initialTab"), let tab = AppTab(rawValue: name) {
            return tab
        }
        #endif
        return .diagnose
    }

    var body: some View {
        #if DEBUG
        // `-gallery YES` shows every design component instead of the tabs.
        if UserDefaults.standard.bool(forKey: "gallery") {
            ComponentGallery()
        } else if let name = UserDefaults.standard.string(forKey: "screen"), let screen = DebugScreens.view(named: name) {
            // `-screen <name>` shows one screen in a fixed state (see DebugScreens).
            screen
        } else {
            shell
        }
        #else
        shell
        #endif
    }

    private var shell: some View {
        VStack(spacing: 0) {
            TabView(selection: $selection) {
                Tab(value: AppTab.diagnose) {
                    DiagnoseTab()
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
                Tab(value: AppTab.measure) {
                    MeasureTab()
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
                Tab(value: AppTab.optimize) {
                    // The Optimize flow (scan, confirm, measure, AR, verify) is wired by the next task; until then the
                    // home shows the right state and its buttons do nothing.
                    OptimizeHomeContainer(
                        onScan: {}, onManualEntry: {}, onEditLayout: {}, onMeasure: {}, onGuideInAR: { _ in },
                        onMoveMyself: { _ in }, onShowVerification: {}, onRescan: {}
                    )
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
            }
            ResoniqTabBar(AppTab.allCases.map(\.item), selection: $selection)
        }
        .background(ResoniqColor.ink)
        .environment(\.switchTab, SwitchTabAction { selection = $0 })
        // A call, the lock button or another app: stop whatever plays or listens.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { lifecycle?.sceneLeftForeground() }
        }
    }
}

#Preview {
    RootView()
        .appEnvironment(AppComposition.launch(inMemory: true)!)
        .preferredColorScheme(.dark)
}
