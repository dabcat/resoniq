#if DEBUG
import ResoniqDesign
import ResoniqStore
import SwiftData
import SwiftUI

/// The intro, Settings and the rooms and systems sheet, for `make run SCREEN=<name>` and screenshots. Debug builds
/// only. `rooms` is an in-memory store with two rooms and three systems, `rooms-empty` has just the default.
enum FinishDebugScreens {
    static let names = ["intro", "intro-2", "intro-3", "settings", "rooms", "rooms-empty", "app-first-launch"]

    @MainActor
    static func view(named name: String) -> AnyView? {
        switch name {
        case "intro": AnyView(IntroView { _ in })
        case "intro-2": AnyView(IntroView(startingAtPage: 1) { _ in })
        case "intro-3": AnyView(IntroView(startingAtPage: 2) { _ in })
        case "settings": AnyView(SettingsHost())
        case "rooms": AnyView(RoomsHost(seeded: true))
        case "rooms-empty": AnyView(RoomsHost(seeded: false))
        case "app-first-launch": AnyView(FirstLaunchHost())
        default: nil
        }
    }

    /// The real app on an in-memory store with the intro shown. Its flag lives in memory, so nothing is written to the
    /// defaults.
    private struct FirstLaunchHost: View {
        @State private var composition = AppComposition.launch(inMemory: true)

        var body: some View {
            if let composition {
                AppShell(introGate: IntroGate(flag: MemoryFlag()))
                    .appEnvironment(composition)
            } else {
                StoreUnavailableScreen()
            }
        }
    }

    private final class MemoryFlag: IntroFlagStore {
        var isFinished = false
    }

    /// Settings on a store with some data in it.
    private struct SettingsHost: View {
        @State private var store = roomsPreviewStore(seeded: true)

        var body: some View {
            SettingsScreen(onClose: {})
                .environment(\.resoniqStore, store)
                .modelContainer(store.container)
        }
    }

    /// The sheet over an empty screen, as it appears over a tab.
    private struct RoomsHost: View {
        @State private var store: ResoniqStore
        @State private var isPresented = true

        init(seeded: Bool) {
            _store = State(initialValue: roomsPreviewStore(seeded: seeded))
        }

        var body: some View {
            ResoniqColor.ink
                .ignoresSafeArea()
                .sheet(isPresented: $isPresented) {
                    RoomsSheet(onClose: { isPresented = false })
                        .environment(\.resoniqStore, store)
                        .modelContainer(store.container)
                }
        }
    }
}
#endif
