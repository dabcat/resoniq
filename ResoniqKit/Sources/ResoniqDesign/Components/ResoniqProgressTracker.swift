import SwiftUI

/// The state of a step, and what each says aloud. Kept apart from the view so it can be tested.
enum TrackerStepState: Sendable, Equatable {
    case done
    case current
    case upcoming

    /// Steps before `current` are done; `current` itself is current; a `current` at or past the end means all done.
    static func state(ofStep index: Int, current: Int) -> TrackerStepState {
        if index < current { return .done }
        return index == current ? .current : .upcoming
    }

    /// The rule that leads into a step takes that step's state: lime into a done step, `guide` (pulsing) into the
    /// current one, `line` into an upcoming one.
    static func state(ofRuleBefore index: Int, current: Int) -> TrackerStepState {
        state(ofStep: index, current: current)
    }

    var spoken: String {
        switch self {
        case .done: "done"
        case .current: "current"
        case .upcoming: "upcoming"
        }
    }

    /// "Step 3 of 4, Move, current".
    static func spokenLabel(title: String, index: Int, count: Int, current: Int) -> String {
        "Step \(index + 1) of \(count), \(title), \(state(ofStep: index, current: current).spoken)"
    }
}

/// The steps of the Optimize flow joined by 2 pt rules (V3Optimize, V3OVerify): "Scanned, Measured, Move, Verify".
///
/// A done step is `lime` with a check, the current step `guide` with a dot that pulses (and stays when Reduce Motion
/// is on), an upcoming one `muted` with `line` rules. The marks differ as well as the colours. VoiceOver reads each
/// step as "Step 3 of 4, Move, current". At accessibility text sizes the steps stack in a column.
///
/// `current` is the index of the current step; pass `steps.count` when every step is done (V3OVerify).
public struct ResoniqProgressTracker: View {
    private let steps: [String]
    private let current: Int

    @Environment(\.dynamicTypeSize) private var typeSize

    public init(steps: [String], current: Int) {
        self.steps = steps
        self.current = current
    }

    public var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(steps.indices, id: \.self) { index in
                        if index > 0 { rule(before: index, vertical: true) }
                        step(index)
                    }
                }
            } else {
                HStack(spacing: Metrics.gap) {
                    ForEach(steps.indices, id: \.self) { index in
                        if index > 0 { rule(before: index, vertical: false) }
                        step(index)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func color(_ state: TrackerStepState) -> Color {
        switch state {
        case .done: ResoniqColor.lime
        case .current: ResoniqColor.guide
        case .upcoming: ResoniqColor.muted
        }
    }

    private func step(_ index: Int) -> some View {
        let state = TrackerStepState.state(ofStep: index, current: current)
        return HStack(spacing: Metrics.markGap) {
            switch state {
            case .done:
                ResoniqIconView(.check)
            case .current:
                LoopingPhase(isRunning: true, animation: ResoniqMotion.waiting) { phase, isActive in
                    Circle()
                        .fill(ResoniqColor.guide)
                        .frame(width: Metrics.dot, height: Metrics.dot)
                        .opacity(isActive && !phase ? Metrics.dotLow : 1)
                }
            case .upcoming:
                EmptyView()
            }
            Text(steps[index])
                .font(ResoniqFont.capsLabel)
                .tracking(ResoniqFont.capsLabelSize * Metrics.tracking)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(Metrics.minimumScale)
        }
        .foregroundStyle(color(state))
        .frame(minHeight: Metrics.stepHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TrackerStepState.spokenLabel(title: steps[index], index: index, count: steps.count, current: current))
    }

    @ViewBuilder
    private func rule(before index: Int, vertical: Bool) -> some View {
        let state = TrackerStepState.state(ofRuleBefore: index, current: current)
        let colour: Color = switch state {
        case .done: ResoniqColor.lime
        case .current: ResoniqColor.guide
        case .upcoming: ResoniqColor.line
        }
        LoopingPhase(isRunning: state == .current, animation: Metrics.rulePulse) { phase, isActive in
            Rectangle()
                .fill(colour)
                .frame(width: vertical ? Metrics.rule : nil, height: vertical ? Metrics.verticalRule : Metrics.rule)
                .frame(maxWidth: vertical ? nil : .infinity, alignment: .leading)
                .opacity(isActive && !phase ? Metrics.ruleLow : 1)
        }
        .padding(.leading, vertical ? Metrics.verticalRuleInset : 0)
        .accessibilityHidden(true)
    }

    private enum Metrics {
        /// V3Optimize sets the labels with 0.06 em, a little tighter than the caps labels of panels.
        static let tracking: CGFloat = 0.06
        static let gap: CGFloat = 6
        static let markGap: CGFloat = 4
        static let dot: CGFloat = 7
        static let dotLow: Double = 0.4
        static let rule: CGFloat = 2
        static let verticalRule: CGFloat = 14
        static let verticalRuleInset: CGFloat = 5
        static let ruleLow: Double = 0.4
        /// V3Optimize: the current rule pulses over 1.6 s.
        static let rulePulse = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)
        static let minimumScale: CGFloat = 0.7
        static let stepHeight: CGFloat = 20
    }
}

#if DEBUG
#Preview("Progress tracker") {
    VStack(alignment: .leading, spacing: ResoniqSpace.s6) {
        ResoniqProgressTracker(steps: ["Scanned", "Measured", "Move", "Verify"], current: 2)
        ResoniqProgressTracker(steps: ["Scanned", "Measured", "Move", "Verify"], current: 0)
        ResoniqProgressTracker(steps: ["Scanned", "Measured", "Moved", "Verified"], current: 4)
        ResoniqProgressTracker(steps: ["Scanned", "Measured", "Move", "Verify"], current: 3)
            .environment(\.dynamicTypeSize, .accessibility2)
    }
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
#endif
