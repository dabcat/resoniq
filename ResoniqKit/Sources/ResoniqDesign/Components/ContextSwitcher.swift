import SwiftUI

/// Room and system switcher, top-left of every tab: a caps label over a headline with a chevron.
public struct ResoniqContextSwitcher: View {
    public enum Order: Sendable {
        /// Diagnose and Measure: the system is the subject.
        case roomOverSystem
        /// Optimize: the room is the subject.
        case systemOverRoom
    }

    private let room: String
    private let system: String
    private let order: Order
    private let action: () -> Void

    public init(room: String, system: String, order: Order = .roomOverSystem, action: @escaping () -> Void) {
        self.room = room
        self.system = system
        self.order = order
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                Text(order == .roomOverSystem ? room : system)
                    .resoniqCapsLabel()
                HStack(spacing: Metrics.chevronGap) {
                    Text(order == .roomOverSystem ? system : room)
                        .font(ResoniqFont.headline)
                    ResoniqIconView(.chevronDown)
                }
                .foregroundStyle(ResoniqColor.ivory)
            }
            .frame(minHeight: Metrics.minHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(order == .roomOverSystem ? "\(room), \(system)" : "\(system), \(room)")
        .accessibilityHint("Switches room or system")
        .accessibilityAddTraits(.isButton)
    }

    private enum Metrics {
        static let lineGap: CGFloat = 1
        static let chevronGap: CGFloat = 6
        static let minHeight: CGFloat = 48
    }
}
