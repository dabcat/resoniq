import ResoniqDesign
import ResoniqStore
import SwiftData
import SwiftUI

/// The room and system a tab is showing.
struct ListeningContext {
    var room: String
    var system: String

    /// The names in the mockups, for previews. The app shows the selected system (`SelectedListeningContext`).
    static let placeholder = ListeningContext(room: "Living room", system: "Stereo pair")
}

/// Reads the selected system's room and system names from the store and hands them to `content`, so every tab's
/// switcher shows the same ones. The selected system, else the first one of the oldest room that has one; the
/// default names before anything exists.
struct SelectedListeningContext<Content: View>: View {
    @Query private var states: [StoreState]
    @Query(sort: \Room.createdAt) private var rooms: [Room]
    @ViewBuilder var content: (ListeningContext) -> Content

    var body: some View {
        let system = states.first?.selectedSystem ?? rooms.lazy.compactMap { $0.orderedSystems.first }.first
        content(
            ListeningContext(
                room: system?.room?.name ?? StoreText.defaultRoomName,
                system: system?.name ?? StoreText.defaultSystemName
            )
        )
    }
}

/// How a tab's switcher opens the rooms and systems sheet. `RootView` sets it once; where nothing sets it, calling it
/// does nothing.
struct OpenRoomsAction {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func callAsFunction() { action() }
}

/// Tells the shell that the selected system may have changed (the rooms sheet or Settings closed), so state that
/// belongs to the system before it is dropped.
struct SystemsChangedAction {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func callAsFunction() { action() }
}

extension EnvironmentValues {
    @Entry var openRooms = OpenRoomsAction {}
    @Entry var systemsChanged = SystemsChangedAction {}
}

/// The frame every tab's home screen shares: the switcher at the top left, an optional control at the
/// top right, and the tab's content below.
struct TabHome<Trailing: View, Content: View>: View {
    var context: ListeningContext = .placeholder
    var switcherOrder: ResoniqContextSwitcher.Order = .roomOverSystem
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    @Environment(\.openRooms) private var openRooms

    var body: some View {
        VStack(spacing: ResoniqSpace.panelPadding) {
            HStack {
                ResoniqContextSwitcher(room: context.room, system: context.system, order: switcherOrder) { openRooms() }
                Spacer()
                trailing
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, ResoniqSpace.screenInset)
        .padding(.bottom, ResoniqSpace.s3)
        .background(ResoniqColor.ink)
    }
}
