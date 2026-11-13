import ResoniqDesign
import SwiftUI

/// The three live illustrations of the intro, built from the real components. Each animates only while its
/// page is visible; under Reduce Motion, or when the page is not visible, it shows its finished picture.

private enum IllustrationMetrics {
    /// The mockups' illustration panel is 340 pt tall.
    static let panelHeight: CGFloat = 340
    static let loop: Duration = .seconds(5)
}

private func capsText(_ text: String, size: CGFloat = 11, colour: Color) -> some View {
    Text(text)
        .font(ResoniqFont.font(.monoRegular, size: size, relativeTo: .caption2))
        .tracking(size * ResoniqFont.Tracking.capsLabel)
        .textCase(.uppercase)
        .foregroundStyle(colour)
}

// MARK: - 1. Diagnose

/// V3Onb1: the portrait draws itself from bass to treble beside Play, Listen, Read; one band trembles.
struct DiagnoseIllustration: View {
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var progress = 0.0

    private var animates: Bool { isVisible && !reduceMotion }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Metrics.columnGap) {
                    portrait
                    steps
                }
            } else {
                HStack(alignment: .top, spacing: Metrics.columnGap) {
                    portrait
                    steps.padding(.top, Metrics.stepsTop)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: IllustrationMetrics.panelHeight - 2 * Metrics.insetV, alignment: .topLeading)
        .resoniqPanel(
            insets: EdgeInsets(top: Metrics.insetV, leading: Metrics.insetH, bottom: Metrics.insetV, trailing: Metrics.insetH)
        )
        .task(id: animates) { await run() }
    }

    private var portrait: some View {
        HStack(spacing: 0) {
            FrequencyRuler(.beside)
            SpeakerPortrait(
                state: animates ? .drawing(progress: progress) : .finished,
                deviations: [Metrics.rough],
                accessibilityLabel: IntroText.portraitSummary
            )
        }
        .frame(width: Metrics.portrait.width, height: Metrics.portrait.height)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Metrics.stepGap) {
            ForEach(Array(IntroText.steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: Metrics.labelGap) {
                    capsText(step.label, colour: index == 2 ? ResoniqColor.signalText : ResoniqColor.muted)
                    Text(step.sentence)
                        .font(ResoniqFont.body)
                        .foregroundStyle(ResoniqColor.ivory)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The mockup's reveal: draws over 65% of the 5 s loop, then holds.
    private func run() async {
        guard animates else {
            progress = 0
            return
        }
        while !Task.isCancelled {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { progress = 0 }
            withAnimation(.easeInOut(duration: Metrics.drawSeconds)) { progress = 1 }
            try? await Task.sleep(for: IllustrationMetrics.loop)
        }
    }

    private enum Metrics {
        static let insetV: CGFloat = 20
        static let insetH: CGFloat = 16
        static let columnGap: CGFloat = 18
        static let stepsTop: CGFloat = 6
        static let stepGap: CGFloat = 22
        static let labelGap: CGFloat = 4
        static let portrait = CGSize(width: 116, height: 300)
        static let drawSeconds = 3.25
        /// The rough orange patch low in the bass, as fractions of the height from the bottom.
        static let rough: ClosedRange<Double> = 0.19...0.27
    }
}

// MARK: - 2. Measure

/// V3Onb2: the curve draws across the even band, the bass swinging outside it; below, three spots around the head.
struct MeasureIllustration: View {
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            ResponseCurve(
                levels: PreviewCurves.seat,
                evenBand: 3,
                range: 12,
                extremes: [
                    .init(frequency: 41, level: 9, label: IntroText.tooLoud),
                    .init(frequency: 61, level: -11, label: IntroText.nearlyGone),
                ],
                progress: progress,
                title: IntroText.curveTitle,
                detail: IntroText.curveDetail,
                accessibilityLabel: IntroText.curveSummary
            )
            Spacer(minLength: 0)
            HStack(spacing: Metrics.spotsGap) {
                ThreeSpots(isAnimating: isVisible && !reduceMotion)
                Text(IntroText.threeSpots)
                    .font(ResoniqFont.bodySmall)
                    .foregroundStyle(ResoniqColor.ivory)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Metrics.footerTop)
            .overlay(alignment: .top) {
                Rectangle().fill(ResoniqColor.line).frame(height: ResoniqSize.strokeHairline)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, minHeight: IllustrationMetrics.panelHeight - 2 * Metrics.inset, alignment: .topLeading)
        .resoniqPanel(insets: EdgeInsets(top: Metrics.inset, leading: Metrics.inset, bottom: Metrics.inset, trailing: Metrics.inset))
        .onChange(of: isVisible, initial: true) { _, visible in
            drawCurve(visible: visible)
        }
    }

    /// Draws once each time the page comes into view; Reduce Motion shows the whole curve.
    private func drawCurve(visible: Bool) {
        var reset = Transaction()
        reset.disablesAnimations = true
        if reduceMotion {
            withTransaction(reset) { progress = 1 }
        } else if visible {
            withTransaction(reset) { progress = 0 }
            withAnimation(ResoniqMotion.traceDraw) { progress = 1 }
        } else {
            withTransaction(reset) { progress = 0 }
        }
    }

    private enum Metrics {
        static let inset: CGFloat = 18
        static let gap: CGFloat = 10
        static let spotsGap: CGFloat = 14
        static let footerTop: CGFloat = 12
    }
}

/// Three dots in a row, the middle one sending out a ring: the three spots around the head.
private struct ThreeSpots: View {
    let isAnimating: Bool
    @State private var expanded = false

    var body: some View {
        HStack(spacing: Metrics.gap) {
            Circle().fill(ResoniqColor.ivory).frame(width: Metrics.dot, height: Metrics.dot)
            ZStack {
                Circle()
                    .strokeBorder(ResoniqColor.ivory, lineWidth: Metrics.ringStroke)
                    .frame(width: Metrics.dot, height: Metrics.dot)
                    .scaleEffect(expanded ? Metrics.ringScale : 1)
                    .opacity(expanded ? 0 : Metrics.ringOpacity)
                Circle().fill(ResoniqColor.ivory).frame(width: Metrics.dot, height: Metrics.dot)
            }
            Circle().fill(ResoniqColor.ivory).frame(width: Metrics.dot, height: Metrics.dot)
        }
        .frame(width: Metrics.width, height: Metrics.height)
        .accessibilityHidden(true)
        .onChange(of: isAnimating, initial: true) { _, animating in
            if animating {
                withAnimation(ResoniqMotion.pulseRing) { expanded = true }
            } else {
                // A plain animation replaces the repeating one, which stops it.
                withAnimation(.linear(duration: 0)) { expanded = false }
            }
        }
    }

    private enum Metrics {
        static let dot: CGFloat = 10
        static let gap: CGFloat = 12
        static let width: CGFloat = 62
        static let height: CGFloat = 22
        static let ringStroke: CGFloat = 1.5
        static let ringScale: CGFloat = 2.4
        static let ringOpacity: Double = 0.6
    }
}

// MARK: - 3. Optimize

/// V3Onb3: a room from above. The right speaker slides into the blue outline and the problem area fades.
///
/// Two plans of the same room lie on each other. The lower one is still: the speaker where it stands, the outline,
/// the problem area. The upper one is the room after the move, with the speaker sliding (the component's own loop,
/// four seconds), and it fades in as the speaker moves and out before the loop starts again. Reduce Motion, or a
/// page out of view, shows the lower plan alone.
struct OptimizeIllustration: View {
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moved = false

    private var animates: Bool { isVisible && !reduceMotion }

    var body: some View {
        ZStack {
            plan(Self.before, animating: false)
            if animates {
                plan(Self.after, animating: true)
                    .opacity(moved ? 1 : 0)
            }
        }
        .frame(height: IllustrationMetrics.panelHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(IntroText.roomSummary)
        .accessibilityAddTraits(.isImage)
        .task(id: animates) { await run() }
    }

    private func plan(_ content: RoomPlanContent, animating: Bool) -> some View {
        RoomPlanView(
            content, isSuggestionAnimating: animating, showsLegend: false, height: IllustrationMetrics.panelHeight,
            accessibilityLabel: IntroText.roomSummary
        )
    }

    /// The component's loop is a second of rest, the slide, then a hold to four seconds; the fade follows it.
    private func run() async {
        guard animates else {
            moved = false
            return
        }
        while !Task.isCancelled {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { moved = false }
            try? await Task.sleep(for: Timing.rest)
            withAnimation(.easeInOut(duration: Timing.fadeIn)) { moved = true }
            try? await Task.sleep(for: Timing.hold)
            withAnimation(.easeInOut(duration: Timing.fadeOut)) { moved = false }
            try? await Task.sleep(for: Timing.tail)
        }
    }

    private enum Timing {
        static let rest = Duration.milliseconds(1000)
        static let fadeIn = 0.9
        static let hold = Duration.milliseconds(2400)
        static let fadeOut = 0.5
        static let tail = Duration.milliseconds(600)
    }

    // MARK: The room, in the mockup's drawing units (1 unit = 1 cm)

    private static func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x / 100, y: y / 100) }

    private static let walls: [RoomPlanContent.Segment] = [
        .init(point(40, 8), point(260, 8)),
        .init(point(260, 8), point(260, 292)),
        .init(point(260, 292), point(40, 292)),
        .init(point(40, 292), point(40, 262)),
        .init(point(40, 222), point(40, 8)),
    ]
    private static let window = RoomPlanContent.Segment(point(112, 8), point(188, 8))
    private static let sofa = RoomPlanContent.Furniture(
        id: "sofa", centre: point(150, 225), size: CGSize(width: 1.04, height: 0.42)
    )
    private static let seat = RoomPlanContent.Seat(id: "seat", position: point(150, 196))
    private static let left = RoomPlanContent.Speaker(
        id: "left", position: point(82, 40), facing: 180, label: "Left", size: CGSize(width: 0.28, height: 0.28)
    )
    private static let right = RoomPlanContent.Speaker(
        id: "right", position: point(218, 70), facing: 180, label: "Right", size: CGSize(width: 0.28, height: 0.28)
    )
    private static let problem = RoomPlanContent.ProblemArea(
        id: "problem", shape: .ellipse(centre: point(150, 196), radii: CGSize(width: 0.44, height: 0.44))
    )
    private static let move = RoomPlanContent.Suggestion(
        speakerID: "right", target: point(218, 40), distanceLabel: IntroText.moveHere
    )

    private static func room(problems: [RoomPlanContent.ProblemArea]) -> RoomPlanContent {
        RoomPlanContent(
            walls: walls, windows: [window], furniture: [sofa], speakers: [left, right], seats: [seat],
            problemAreas: problems, suggestions: [move]
        )
    }

    static let before = room(problems: [problem])
    static let after = room(problems: [])
}

#Preview("Illustrations") {
    ScrollView {
        VStack(spacing: ResoniqSpace.s5) {
            DiagnoseIllustration(isVisible: true)
            MeasureIllustration(isVisible: true)
            OptimizeIllustration(isVisible: true)
        }
        .padding(ResoniqSpace.screenInset)
    }
    .background(ResoniqColor.ink)
}
