import SwiftUI

// MARK: - Canvas shared by the view and the editor

/// The plan's canvas plus the speaker that slides toward its suggested outline. The editor puts its gestures and
/// accessibility elements in `overlay`, which gets the fit so it can map touches to metres.
struct RoomPlanCanvas<Overlay: View>: View {
    var scene: RoomPlanScene
    var isSuggestionAnimating: Bool
    @ViewBuilder var overlay: (PlanFit, CGSize) -> Overlay

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasSlid = false

    /// The loops run only while the app is guiding, and never under Reduce Motion; the plan is complete without them.
    private var animates: Bool { isSuggestionAnimating && !reduceMotion && movingSpeaker != nil }

    private var movingSpeaker: (speaker: RoomPlanContent.Speaker, suggestion: RoomPlanContent.Suggestion)? {
        for suggestion in scene.content.suggestions where RoomPlanGeometry.isFinite(suggestion.target) {
            if let speaker = scene.content.speakers.first(where: { $0.id == suggestion.speakerID }) {
                return (speaker, suggestion)
            }
        }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let fit = scene.fit(in: proxy.size)
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(paused: !animates)) { timeline in
                    let phase = animates
                        ? MarchingOutline.dashPhase(at: timeline.date.timeIntervalSinceReferenceDate, pattern: RoomPlanDrawing.Metrics.outlineDash)
                        : 0
                    Canvas { context, size in
                        var drawn = scene
                        drawn.dashPhase = phase
                        drawn.hiddenSpeakerID = animates ? movingSpeaker?.speaker.id : nil
                        RoomPlanDrawing.draw(drawn, fit: fit, size: size, in: &context)
                    }
                }
                if animates, let moving = movingSpeaker { slidingSpeaker(moving.speaker, moving.suggestion, fit: fit) }
                overlay(fit, proxy.size)
            }
        }
        .task(id: animates) { await slideLoop() }
    }

    /// The speaker glyph on its way to the outline: "Settle", a spring with a little overshoot.
    private func slidingSpeaker(_ speaker: RoomPlanContent.Speaker, _ suggestion: RoomPlanContent.Suggestion, fit: PlanFit) -> some View {
        let side = RoomPlanDrawing.glyphSide(of: speaker, fit: fit)
        let from = fit.point(scene.position(of: speaker))
        let to = fit.point(suggestion.target)
        let facing = scene.facing(of: speaker)
        let turn = RoomPlanGeometry.normalised(degrees: (suggestion.targetFacing ?? facing) - facing)
        let box = side + 2 * RoomPlanDrawing.Metrics.ringGap
        return SpeakerGlyphView(kind: speaker.kind, side: side, facing: facing + (hasSlid ? turn : 0))
            .frame(width: box, height: box)
            .position(hasSlid ? to : from)
            .animation(ResoniqMotion.settle, value: hasSlid)
            .allowsHitTesting(false)
    }

    private func slideLoop() async {
        var reset = Transaction()
        reset.disablesAnimations = true
        guard animates else {
            withTransaction(reset) { hasSlid = false }
            return
        }
        while !Task.isCancelled {
            withTransaction(reset) { hasSlid = false }
            try? await Task.sleep(for: Timing.rest)
            if Task.isCancelled { break }
            withAnimation(ResoniqMotion.settle) { hasSlid = true }
            try? await Task.sleep(for: Timing.hold)
        }
    }

}

/// The mockup's 4 s loop: still, then the move, then a hold at the outline.
private enum Timing {
    static let rest = Duration.milliseconds(1000)
    static let hold = Duration.milliseconds(3000)
}

/// A speaker glyph as a view, for the one that slides.
struct SpeakerGlyphView: View {
    var kind: RoomPlanContent.Speaker.Kind
    var side: CGFloat
    var facing: Double

    var body: some View {
        Canvas { context, size in
            RoomPlanDrawing.drawSpeaker(kind, at: CGPoint(x: size.width / 2, y: size.height / 2), side: side, facing: facing, selected: false, in: &context)
        }
    }
}

// MARK: - Legend

/// "Measured here" and "Suggested, not yet tested": a solid dot against a dashed outline, so the two differ by
/// fill and dash as well as colour.
public struct RoomPlanLegend: View {
    private let measured: String
    private let suggested: String

    public init(measured: String = "Measured here", suggested: String = "Suggested, not yet tested") {
        self.measured = measured
        self.suggested = suggested
    }

    public var body: some View {
        HStack(spacing: Metrics.gap) {
            HStack(spacing: Metrics.itemGap) {
                Circle().fill(ResoniqColor.ivory).frame(width: Metrics.dot, height: Metrics.dot)
                Text(measured)
            }
            HStack(spacing: Metrics.itemGap) {
                RoundedRectangle(cornerRadius: Metrics.swatchRadius)
                    .strokeBorder(ResoniqColor.guide, style: StrokeStyle(lineWidth: Metrics.swatchStroke, dash: Metrics.swatchDash))
                    .frame(width: Metrics.swatch, height: Metrics.swatch)
                Text(suggested)
            }
        }
        .font(Metrics.font)
        .foregroundStyle(ResoniqColor.muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(measured). \(suggested).")
    }

    private enum Metrics {
        static let gap: CGFloat = 18
        static let itemGap: CGFloat = 6
        static let dot: CGFloat = 10
        static let swatch: CGFloat = 12
        static let swatchRadius: CGFloat = 2
        static let swatchStroke: CGFloat = 1.5
        static let swatchDash: [CGFloat] = [2, 2.5]
        static let font = ResoniqFont.font(.sansRegular, size: 12, relativeTo: .caption)
    }
}

// MARK: - View

/// The top-down room plan of the Optimize flow (V3Optimize, V3Onb3): walls, windows, doors, furniture, speakers,
/// the seat, measured spots, problem areas and a suggested move, fitted into the frame at one scale.
///
/// Measured and suggested differ by fill and dash as well as colour: a measured spot is a solid `ivory` dot, a
/// suggestion a dashed `guide` outline. The speaker slides toward its outline (with `ResoniqMotion.settle`) and
/// the outline marches only while `isSuggestionAnimating` is true and Reduce Motion is off; otherwise the plan is
/// still and complete. One element for VoiceOver: the sentence passed as `accessibilityLabel`.
public struct RoomPlanView: View {
    private let content: RoomPlanContent
    private let isSuggestionAnimating: Bool
    private let showsLegend: Bool
    private let measuredLegend: String
    private let suggestedLegend: String
    private let height: CGFloat?
    private let accessibilityText: String

    /// - Parameters:
    ///   - isSuggestionAnimating: The speaker slides toward the outline and the outline marches.
    ///   - showsLegend: The legend under the panel.
    ///   - height: The panel's height; V3Optimize's is 322. Pass nil to fill the height offered.
    ///   - accessibilityLabel: One sentence that states what the plan shows and what is suggested.
    public init(
        _ content: RoomPlanContent,
        isSuggestionAnimating: Bool = false,
        showsLegend: Bool = true,
        measuredLegend: String = "Measured here",
        suggestedLegend: String = "Suggested, not yet tested",
        height: CGFloat? = 322,
        accessibilityLabel: String
    ) {
        self.content = content
        self.isSuggestionAnimating = isSuggestionAnimating
        self.showsLegend = showsLegend
        self.measuredLegend = measuredLegend
        self.suggestedLegend = suggestedLegend
        self.height = height
        self.accessibilityText = accessibilityLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.legendGap) {
            RoomPlanCanvas(scene: RoomPlanScene(content: content), isSuggestionAnimating: isSuggestionAnimating) { _, _ in EmptyView() }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(ResoniqColor.panel, in: RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous)
                        .strokeBorder(ResoniqColor.line, lineWidth: ResoniqSize.strokeHairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(.isImage)
            if showsLegend {
                RoomPlanLegend(measured: measuredLegend, suggested: suggestedLegend)
            }
        }
    }

    private enum Metrics {
        static let legendGap: CGFloat = 12
    }
}

#if DEBUG
public extension RoomPlanContent {
    /// `sample` with no suggestion: the room as measured.
    static var sampleMeasured: RoomPlanContent {
        var content = sample
        content.suggestions = []
        return content
    }
}

#Preview("Room plan") {
    ScrollView {
        VStack(spacing: ResoniqSpace.s6) {
            RoomPlanView(.sample, accessibilityLabel: RoomPlanContent.sampleSummary)
            RoomPlanView(.sample, isSuggestionAnimating: true, accessibilityLabel: RoomPlanContent.sampleSummary)
            RoomPlanView(.sampleMeasured, showsLegend: false, height: 240, accessibilityLabel: "The room with three measured spots and a bass dip around the seat.")
            RoomPlanView(RoomPlanContent(walls: [.init(x1: 0, y1: 0, x2: 3, y2: 0)]), height: 160, accessibilityLabel: "One wall.")
            RoomPlanView(RoomPlanContent(), height: 120, accessibilityLabel: "Nothing scanned yet.")
        }
        .padding(ResoniqSpace.screenInset)
    }
    .background(ResoniqColor.ink)
}
#endif
