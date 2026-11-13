import SwiftUI

public struct ResoniqTabItem<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String
    public let icon: ResoniqIcon

    public var id: Value { value }

    public init(_ value: Value, title: String, icon: ResoniqIcon) {
        self.value = value
        self.title = title
        self.icon = icon
    }
}

/// The app's tab bar (V3Diagnose, V3Measure, V3Optimize): `panel` background with a hairline on top;
/// the active tab has an `ivory` bold label and a 3 pt `lime` bar on its top edge.
public struct ResoniqTabBar<Value: Hashable>: View {
    private let items: [ResoniqTabItem<Value>]
    @Binding private var selection: Value

    public init(_ items: [ResoniqTabItem<Value>], selection: Binding<Value>) {
        self.items = items
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let isSelected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    VStack(spacing: Metrics.iconLabelGap) {
                        ResoniqIconView(item.icon)
                        Text(item.title)
                            .font(isSelected ? ResoniqFont.tabSelected : ResoniqFont.tab)
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? ResoniqColor.ivory : ResoniqColor.muted)
                    .frame(maxWidth: .infinity, minHeight: ResoniqSize.tabItemHeight)
                    .overlay(alignment: .top) {
                        if isSelected {
                            Rectangle()
                                .fill(ResoniqColor.lime)
                                .frame(height: Metrics.indicatorHeight)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, ResoniqSpace.screenInset)
        .background {
            ResoniqColor.panel.ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ResoniqColor.line)
                .frame(height: ResoniqSize.strokeHairline)
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    private enum Metrics {
        static var iconLabelGap: CGFloat { 5 }
        static var indicatorHeight: CGFloat { 3 }
    }
}
