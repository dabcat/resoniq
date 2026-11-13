import SwiftUI

public struct ResoniqSegment<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String

    public var id: Value { value }

    public init(_ value: Value, title: String) {
        self.value = value
        self.title = title
    }
}

/// Picks one of a few values (V3Start "Left / Right / Only one"): a `panel` track of radius 14 with the
/// selected segment in `ivory` and its label in `ink`. Changing the selection plays a selection haptic.
public struct ResoniqSegmentedControl<Value: Hashable>: View {
    private let segments: [ResoniqSegment<Value>]
    @Binding private var selection: Value
    private let label: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter label: What is being chosen ("Which speaker"); VoiceOver reads it for the group.
    public init(_ segments: [ResoniqSegment<Value>], selection: Binding<Value>, label: String) {
        self.segments = segments
        _selection = selection
        self.label = label
    }

    public var body: some View {
        HStack(spacing: SegmentMetrics.gap) {
            ForEach(segments) { segment in
                let isSelected = segment.value == selection
                Button {
                    selection = segment.value
                } label: {
                    Text(segment.title)
                        .font(isSelected ? SegmentMetrics.selectedFont : SegmentMetrics.regularFont)
                        .foregroundStyle(isSelected ? ResoniqColor.onAction : ResoniqColor.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: ResoniqSize.segmentHeight)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: ResoniqRadius.segment, style: .continuous)
                                    .fill(ResoniqColor.ivory)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: ResoniqRadius.segment, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(SegmentMetrics.gap)
        .background(ResoniqColor.panel, in: RoundedRectangle(cornerRadius: ResoniqRadius.control, style: .continuous))
        .animation(reduceMotion ? nil : ResoniqMotion.press, value: selection)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

private enum SegmentMetrics {
    /// The track's padding and the gap between segments are both 4 in V3Start.
    static let gap: CGFloat = ResoniqSpace.s1
    static let selectedFont = ResoniqFont.font(.sansBold, size: 15, relativeTo: .body)
    static let regularFont = ResoniqFont.font(.sansMedium, size: 15, relativeTo: .body)
}

#Preview("Segmented") {
    @Previewable @State var choice = "left"
    ResoniqSegmentedControl(
        [
            ResoniqSegment("left", title: "Left"),
            ResoniqSegment("right", title: "Right"),
            ResoniqSegment("one", title: "Only one"),
        ],
        selection: $choice,
        label: "Which speaker"
    )
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
