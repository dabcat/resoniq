import SwiftUI

/// A 30 pt pill that names one step or one state (V3MRunning, V3Paused).
///
/// Each style has a cue besides colour: done has a check, active a pulsing dot (still while Reduce Motion
/// is on), upcoming is an outline in a quiet weight, and paused has its own word, which VoiceOver adds too.
public struct ResoniqStatusPill: View {
    public enum Style: Sendable {
        /// `lime` fill with a check.
        case done
        /// `lime` outline with a pulsing dot.
        case active
        /// `line` outline, `muted` label.
        case upcoming
        /// `signal` fill.
        case paused
    }

    private let title: String
    private let style: Style

    public init(_ title: String, style: Style) {
        self.title = title
        self.style = style
    }

    public var body: some View {
        HStack(spacing: Metrics.gap) {
            switch style {
            case .done:
                ResoniqIconView(.check)
            case .active:
                LoopingPhase(isRunning: true, animation: ResoniqMotion.waiting) { phase, isActive in
                    Circle()
                        .fill(ResoniqColor.lime)
                        .frame(width: Metrics.dot, height: Metrics.dot)
                        .opacity(isActive && !phase ? Metrics.dotLow : 1)
                }
            case .upcoming, .paused:
                EmptyView()
            }
            Text(title)
                .font(style == .upcoming ? Metrics.regularFont : Metrics.boldFont)
                .lineLimit(1)
                .minimumScaleFactor(Metrics.minimumScale)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, style == .paused ? Metrics.pausedPadding : Metrics.padding)
        .frame(minHeight: Metrics.height)
        .background { background }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spokenState)
    }

    private var foreground: Color {
        switch style {
        case .done, .paused: ResoniqColor.onAction
        case .active: ResoniqColor.ivory
        case .upcoming: ResoniqColor.muted
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .done:
            Capsule().fill(ResoniqColor.lime)
        case .active:
            Capsule().strokeBorder(ResoniqColor.lime, lineWidth: Metrics.outline)
        case .upcoming:
            Capsule().strokeBorder(ResoniqColor.line, lineWidth: Metrics.outline)
        case .paused:
            Capsule().fill(ResoniqColor.signal)
        }
    }

    private var spokenState: String {
        switch style {
        case .done: "Done"
        case .active: "In progress"
        case .upcoming: "Not started"
        case .paused: "Paused"
        }
    }

    private enum Metrics {
        static let height: CGFloat = 30
        static let padding: CGFloat = 10
        static let pausedPadding: CGFloat = 12
        static let gap: CGFloat = 6
        static let dot: CGFloat = 7
        static let dotLow: Double = 0.4
        static let outline: CGFloat = 1.5
        static let minimumScale: CGFloat = 0.7
        static let boldFont = ResoniqFont.font(.sansBold, size: 13, relativeTo: .caption)
        static let regularFont = ResoniqFont.font(.sansRegular, size: 13, relativeTo: .caption)
    }
}

#Preview("Styles") {
    HStack(spacing: ResoniqSpace.s2) {
        ResoniqStatusPill("Seat", style: .done)
        ResoniqStatusPill("Left", style: .active)
        ResoniqStatusPill("Right", style: .upcoming)
        ResoniqStatusPill("Paused", style: .paused)
    }
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
