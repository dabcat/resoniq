import ResoniqDesign
import ResoniqStore
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

/// The app's root: in debug builds `-gallery` and `-screen <name>` show something else; otherwise the shell.
struct RootView: View {
    var body: some View {
        #if DEBUG
        // `-gallery YES` shows every design component instead of the tabs.
        if UserDefaults.standard.bool(forKey: "gallery") {
            ComponentGallery()
        } else if let name = UserDefaults.standard.string(forKey: "screen"), let screen = DebugScreens.view(named: name) {
            // `-screen <name>` shows one screen in a fixed state (see DebugScreens).
            screen
        } else {
            AppShell(introGate: Self.introGate)
        }
        #else
        AppShell(introGate: Self.introGate)
        #endif
    }

    /// The gate for a real launch. Debug launches with `-screen` (the flows run unattended) never see the intro and
    /// never write its flag.
    private static var introGate: IntroGate? {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "screen") != nil { return nil }
        #endif
        return .standard()
    }
}

/// The intro on first launch, then the tab shell. The system tab bar is hidden and replaced by the design system's,
/// as in the mockups; `TabView` still keeps each tab's state while another is shown.
struct AppShell: View {
    /// Nil: no intro.
    private let introGate: IntroGate?
    @State private var showsIntro: Bool
    @State private var selection: AppTab = launchTab
    @State private var showsRooms = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appLifecycle) private var lifecycle
    @Environment(DiagnoseCoordinator.self) private var diagnose
    @Environment(MeasureCoordinator.self) private var measure
    @Environment(OptimizeCoordinator.self) private var optimize

    init(introGate: IntroGate? = nil) {
        self.introGate = introGate
        _showsIntro = State(initialValue: introGate?.isShown ?? false)
    }

    /// Debug builds open on the tab named by `-initialTab measure`, so `make run TAB=...` can show any tab.
    private static var launchTab: AppTab {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "initialTab"), let tab = AppTab(rawValue: name) {
            return tab
        }
        #endif
        return .diagnose
    }

    var body: some View {
        Group {
            if showsIntro {
                IntroView(onFinished: introFinished)
                    .transition(.opacity)
            } else {
                shell
            }
        }
        .background(ResoniqColor.ink)
        // A call, the lock button or another app: stop whatever plays or listens.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { lifecycle?.sceneLeftForeground() }
        }
    }

    private func introFinished(_ outcome: IntroOutcome) {
        introGate?.finish()
        selection = .diagnose
        withAnimation(ResoniqMotion.sheet) { showsIntro = false }
        // "Try it on a speaker" opens the Aim flow for the first test, as the home's primary button does.
        if outcome == .tryOnSpeaker { diagnose.startFirstTest() }
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
                    OptimizeTab()
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
            }
            ResoniqTabBar(AppTab.allCases.map(\.item), selection: $selection)
        }
        .background(ResoniqColor.ink)
        .environment(\.switchTab, SwitchTabAction { selection = $0 })
        .environment(\.openRooms, OpenRoomsAction { showsRooms = true })
        .environment(\.systemsChanged, SystemsChangedAction(systemsMayHaveChanged))
        // Every tab's switcher opens the rooms and systems sheet; choosing a system there changes every tab.
        .sheet(isPresented: $showsRooms, onDismiss: systemsMayHaveChanged) {
            RoomsSheet(onClose: { showsRooms = false })
        }
        // Optimize hands over to Measure and comes back (the seat measurement), and shows Before and after.
        .onAppear { optimize.showTab = { selection = $0 } }
    }

    /// The tabs read the selected system from the store, so they follow it by themselves; what the coordinators
    /// hold for the system before is dropped here.
    private func systemsMayHaveChanged() {
        diagnose.selectionMayHaveChanged()
        measure.selectionMayHaveChanged()
    }
}

#Preview {
    RootView()
        .appEnvironment(AppComposition.launch(inMemory: true)!)
        .preferredColorScheme(.dark)
}
