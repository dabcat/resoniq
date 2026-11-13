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

/// The frame every tab's home screen shares: the switcher at the top left, an optional control at the
/// top right, and the tab's content below.
struct TabHome<Trailing: View, Content: View>: View {
    var context: ListeningContext = .placeholder
    var switcherOrder: ResoniqContextSwitcher.Order = .roomOverSystem
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: ResoniqSpace.panelPadding) {
            HStack {
                // No target yet: the room and system list is designed in phase 2.
                ResoniqContextSwitcher(room: context.room, system: context.system, order: switcherOrder) {}
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
