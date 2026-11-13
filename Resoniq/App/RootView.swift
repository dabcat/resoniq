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
        VStack(spacing: 0) {
            TabView(selection: $selection) {
                Tab(value: AppTab.diagnose) {
                    DiagnoseHomeView()
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
                Tab(value: AppTab.measure) {
                    MeasureHomeView()
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
                Tab(value: AppTab.optimize) {
                    OptimizeHomeView()
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
        .preferredColorScheme(.dark)
}
