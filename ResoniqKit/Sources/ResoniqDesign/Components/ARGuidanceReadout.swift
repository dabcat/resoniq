import SwiftUI

// The furniture around a camera view in the Optimize flow: the readout of V3OAR and the instruction of V3OScan.
// There is no camera or AR code here; the caller puts these over its own view.

/// How far along a move is, as a fraction held to 0...1; anything not finite is 0.
enum ARProgress {
    static func fraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    static func percent(_ value: Double) -> Int { Int((fraction(value) * 100).rounded()) }
}

// MARK: - Pieces

/// The caps label, the large `lime` mono value and the unit (V3OAR "To go 18 cm").
struct ARToGoValue: View {
    var label: String
    var value: String
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Text(label).resoniqCapsLabel()
            HStack(alignment: .firstTextBaseline, spacing: Metrics.unitGap) {
                Text(value)
                    .font(ResoniqFont.readoutLarge)
                    .tracking(Metrics.size * ResoniqFont.Tracking.readout)
                    .foregroundStyle(ResoniqColor.lime)
                    .lineLimit(1)
                    .minimumScaleFactor(Metrics.minimumScale)
                Text(unit)
                    .font(Metrics.unitFont)
                    .foregroundStyle(ResoniqColor.ivory)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value) \(unit)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private enum Metrics {
        static let gap: CGFloat = 2
        static let unitGap: CGFloat = 6
        static let size: CGFloat = 46
        static let minimumScale: CGFloat = 0.6
        static let unitFont = ResoniqFont.font(.sansSemibold, size: 17, relativeTo: .headline)
    }
}

/// The `lime` bar on a `line` track: 10 pt tall, filling from the left.
struct ARProgressBar: View {
    var progress: Double
    var label: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(ResoniqColor.line)
                Capsule()
                    .fill(ResoniqColor.lime)
                    .frame(width: proxy.size.width * ARProgress.fraction(progress))
            }
        }
        .frame(height: Metrics.height)
        .animation(reduceMotion ? nil : ResoniqMotion.settle, value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(ARProgress.percent(progress)) percent")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private enum Metrics {
        static let height: CGFloat = 10
    }
}

/// The floating "To go" card over the camera (V3OAR): an `ink` card, radius 18.
public struct ARToGoCard: View {
    private let label: String
    private let value: String
    private let unit: String

    public init(label: String = "To go", value: String, unit: String) {
        self.label = label
        self.value = value
        self.unit = unit
    }

    public var body: some View {
        ARToGoValue(label: label, value: value, unit: unit)
            .padding(.horizontal, Metrics.horizontal)
            .padding(.vertical, Metrics.vertical)
            .background(ResoniqColor.ink, in: RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous))
    }

    private enum Metrics {
        static let horizontal: CGFloat = 16
        static let vertical: CGFloat = 12
    }
}

/// The step line over the camera (V3OAR "Right speaker · step 1 of 2"): a 44 pt `ink` pill.
public struct ARStepPill: View {
    private let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(Metrics.font)
            .foregroundStyle(ResoniqColor.ivory)
            .lineLimit(2)
            .padding(.horizontal, Metrics.padding)
            .frame(minHeight: ResoniqSize.touchMin)
            .background(ResoniqColor.ink, in: Capsule())
    }

    private enum Metrics {
        static let font = ResoniqFont.font(.sansMedium, size: 14, relativeTo: .callout)
        static let padding: CGFloat = 16
    }
}

// MARK: - Readout

/// The bottom of the AR guide (V3OAR) on an `ink` scrim: the step title, the large `lime` "to go" value with its
/// unit, the instruction sentence, a `lime` progress bar with two secondary lines under it, and the line that
/// says what the haptics are doing.
///
/// The value, the bar and the lines are all text for VoiceOver, so the guide works without sight, colour or
/// haptics. The value and the bar are marked as frequently updating. `progress` is 0...1.
public struct ARGuidanceReadout: View {
    private let title: String
    private let toGoLabel: String
    private let toGoValue: String
    private let unit: String
    private let progress: Double
    private let instruction: String
    private let progressLabel: String
    private let leadingLine: String?
    private let trailingLine: String?
    private let hint: String?

    /// - Parameters:
    ///   - title: "Right speaker · step 1 of 2".
    ///   - toGoValue: The distance left, already formatted ("18"), with `unit` ("cm").
    ///   - progress: How much of the move is done, 0...1.
    ///   - instruction: "Slide it toward you until it fills the blue outline."
    ///   - progressLabel: What the bar measures, for VoiceOver.
    ///   - leadingLine, trailingLine: The two mono lines under the bar ("35 cm in total", "then turn 12° toward your seat").
    ///   - hint: The line with the pulsing dot ("Taps in your hand speed up as you get closer.").
    public init(
        title: String,
        toGoLabel: String = "To go",
        toGoValue: String,
        unit: String,
        progress: Double,
        instruction: String,
        progressLabel: String = "Progress",
        leadingLine: String? = nil,
        trailingLine: String? = nil,
        hint: String? = nil
    ) {
        self.title = title
        self.toGoLabel = toGoLabel
        self.toGoValue = toGoValue
        self.unit = unit
        self.progress = progress
        self.instruction = instruction
        self.progressLabel = progressLabel
        self.leadingLine = leadingLine
        self.trailingLine = trailingLine
        self.hint = hint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Text(title)
                .font(Metrics.titleFont)
                .foregroundStyle(ResoniqColor.muted)
            ARToGoValue(label: toGoLabel, value: toGoValue, unit: unit)
            Text(instruction)
                .font(ResoniqFont.title3)
                .tracking(Metrics.instructionSize * ResoniqFont.Tracking.title)
                .foregroundStyle(ResoniqColor.ivory)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Metrics.barGap) {
                ARProgressBar(progress: progress, label: progressLabel)
                if leadingLine != nil || trailingLine != nil {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            lines
                        }
                        VStack(alignment: .leading, spacing: Metrics.lineGap) {
                            lines
                        }
                    }
                    .font(ResoniqFont.axis)
                    .foregroundStyle(ResoniqColor.muted)
                }
            }
            if let hint {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.hintGap) {
                    // The dot is a still mark under Reduce Motion; the sentence says the same.
                    LoopingPhase(isRunning: true, animation: Metrics.hintPulse) { phase, isActive in
                        Circle()
                            .fill(ResoniqColor.lime)
                            .frame(width: Metrics.dot, height: Metrics.dot)
                            .opacity(isActive && !phase ? Metrics.dotLow : 1)
                    }
                    Text(hint)
                        .font(Metrics.hintFont)
                        .foregroundStyle(ResoniqColor.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ResoniqSpace.screenInset)
        .padding(.top, Metrics.top)
        .padding(.bottom, Metrics.bottom)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: ResoniqRadius.sheet, topTrailingRadius: ResoniqRadius.sheet, style: .continuous)
                .fill(ResoniqColor.ink.opacity(Metrics.scrim))
        )
    }

    @ViewBuilder
    private var lines: some View {
        if let leadingLine { Text(leadingLine) }
        if leadingLine != nil && trailingLine != nil { Spacer(minLength: Metrics.lineGap) }
        if let trailingLine { Text(trailingLine) }
    }

    private enum Metrics {
        static let gap: CGFloat = 14
        static let barGap: CGFloat = 8
        static let lineGap: CGFloat = 4
        static let hintGap: CGFloat = 10
        static let top: CGFloat = 22
        static let bottom: CGFloat = 24
        static let instructionSize: CGFloat = 26
        static let scrim: Double = 0.92
        static let dot: CGFloat = 8
        static let dotLow: Double = 0.45
        /// V3OAR: the dot pulses at 0.5 s, the pace of the taps it describes.
        static let hintPulse = Animation.easeInOut(duration: 0.25).repeatForever(autoreverses: true)
        static let titleFont = ResoniqFont.font(.sansMedium, size: 14, relativeTo: .callout)
        static let hintFont = ResoniqFont.font(.sansRegular, size: 14, relativeTo: .callout)
    }
}

// MARK: - Direction

/// An arrow with one sentence (V3OScan "Turn right to catch the last wall."): the arrow points the way, nudging
/// 8 pt along it on the waiting loop, and holds still under Reduce Motion. The sentence must say the direction
/// in words; the arrow is for sighted users and VoiceOver skips it.
public struct DirectionArrowInstruction: View {
    public enum Direction: Sendable, CaseIterable {
        case left, right, forward, back

        /// Degrees to turn the right-pointing arrow.
        var rotation: Double {
            switch self {
            case .right: 0
            case .back: 90
            case .left: 180
            case .forward: 270
            }
        }

        /// The unit vector of the arrow on screen.
        var vector: CGVector {
            switch self {
            case .right: CGVector(dx: 1, dy: 0)
            case .back: CGVector(dx: 0, dy: 1)
            case .left: CGVector(dx: -1, dy: 0)
            case .forward: CGVector(dx: 0, dy: -1)
            }
        }
    }

    private let direction: Direction
    private let text: String

    public init(_ direction: Direction, text: String) {
        self.direction = direction
        self.text = text
    }

    public var body: some View {
        HStack(spacing: Metrics.gap) {
            LoopingPhase(isRunning: true, animation: ResoniqMotion.waiting) { phase, isActive in
                ResoniqIconView(.directionArrow)
                    .foregroundStyle(ResoniqColor.lime)
                    .rotationEffect(.degrees(direction.rotation))
                    .offset(
                        x: direction.vector.dx * (isActive && phase ? Metrics.nudge : 0),
                        y: direction.vector.dy * (isActive && phase ? Metrics.nudge : 0)
                    )
            }
            Text(text)
                .font(ResoniqFont.title3)
                .tracking(Metrics.size * ResoniqFont.Tracking.title)
                .foregroundStyle(ResoniqColor.ivory)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private enum Metrics {
        static let gap: CGFloat = 14
        static let nudge: CGFloat = 8
        static let size: CGFloat = 26
    }
}

#if DEBUG
#Preview("AR guidance") {
    ScrollView {
        VStack(spacing: ResoniqSpace.s6) {
            ZStack(alignment: .topLeading) {
                ResoniqColor.panelRaised
                VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
                    ARStepPill("Right speaker \u{00B7} step 1 of 2")
                    ARToGoCard(value: "18", unit: "cm")
                }
                .padding(ResoniqSpace.s5)
            }
            .frame(height: 200)
            ARGuidanceReadout(
                title: "Right speaker \u{00B7} step 1 of 2", toGoValue: "18", unit: "cm", progress: 0.62,
                instruction: "Slide it toward you until it fills the blue outline.", progressLabel: "Distance moved",
                leadingLine: "35 cm in total", trailingLine: "then turn 12\u{00B0} toward your seat",
                hint: "Taps in your hand speed up as you get closer."
            )
            ARGuidanceReadout(
                title: "Right speaker \u{00B7} step 2 of 2", toGoValue: "12", unit: "\u{00B0}", progress: 1,
                instruction: "Turn it toward your seat."
            )
            DirectionArrowInstruction(.right, text: "Turn right to catch the last wall.")
            DirectionArrowInstruction(.left, text: "Turn left.")
            DirectionArrowInstruction(.forward, text: "Walk forward.")
            DirectionArrowInstruction(.back, text: "Step back.")
        }
        .padding(ResoniqSpace.screenInset)
    }
    .background(ResoniqColor.ink)
}
#endif
