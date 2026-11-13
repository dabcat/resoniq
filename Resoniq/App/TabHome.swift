import ResoniqDesign
import SwiftUI

/// The room and system a tab is showing.
struct ListeningContext {
    var room: String
    var system: String

    /// The names in the mockups. Phase 2 replaces this with the selection stored in `ResoniqStore`.
    static let placeholder = ListeningContext(room: "Living room", system: "Stereo pair")
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
