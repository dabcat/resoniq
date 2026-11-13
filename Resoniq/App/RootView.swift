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

/// The tab shell. The system tab bar is hidden and replaced by the design system's, as in the mockups;
/// `TabView` still keeps each tab's state while another is shown.
struct RootView: View {
    @State private var selection: AppTab = launchTab

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
                    SelectedListeningContext { MeasureHomeView(context: $0) }
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
    }
}

#Preview {
    RootView()
        .appEnvironment(AppComposition.launch(inMemory: true)!)
        .preferredColorScheme(.dark)
}
