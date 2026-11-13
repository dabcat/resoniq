import SwiftUI

// MARK: - Geometry

/// The diagram's layout in the mockups' own coordinates (V3MGuide is 340 x 298, V3MRunning 340 x 130), kept apart
/// from drawing so it can be tested on the Mac.
enum SpotsGeometry {
    static func size(of variant: SpotsDiagram.Variant) -> CGSize {
        switch variant {
        case .guide: CGSize(width: 340, height: 298)
        case .running: CGSize(width: 340, height: 130)
        }
    }

    /// The three spots from left to right.
    static func spotCentres(of variant: SpotsDiagram.Variant) -> [CGPoint] {
        switch variant {
        case .guide: [CGPoint(x: 120, y: 204), CGPoint(x: 170, y: 204), CGPoint(x: 220, y: 204)]
        case .running: [CGPoint(x: 114, y: 56), CGPoint(x: 170, y: 56), CGPoint(x: 226, y: 56)]
        }
    }

    /// The order the spots are measured in, by position from the left: the seat, then 30 cm left, then right.
    static let numbers = [2, 1, 3]

    /// Centres of the two speakers in the guide variant, the middle of the sound arcs' flat side.
    static let speakerCentres = [CGPoint(x: 84, y: 36), CGPoint(x: 256, y: 36)]
    static let speakerSide: CGFloat = 28

    /// The arcs of one speaker: a half circle under it, each wider and a little lower than the last.
    static let arcs: [(offset: CGFloat, radius: CGFloat)] = [(26, 20), (30, 34), (34, 48)]

    /// The points of one lower half circle, left to right.
    static func arcPoints(centre: CGPoint, radius: CGFloat, segments: Int = 40) -> [CGPoint] {
        (0...segments).map { step in
            let angle = Double.pi * Double(step) / Double(segments)
            return CGPoint(x: centre.x - radius * CGFloat(cos(angle)), y: centre.y + radius * CGFloat(sin(angle)))
        }
    }

    /// The spot states padded or cut to three.
    static func normalised(_ spots: [SpotsDiagram.SpotState]) -> [SpotsDiagram.SpotState] {
        (0..<3).map { $0 < spots.count ? spots[$0] : .upcoming }
    }

    /// The spot the phone belongs at: the one given, else the active one, else the last done, else the first.
    static func phoneTarget(spots: [SpotsDiagram.SpotState], requested: Int?) -> Int {
        if let requested { return min(max(requested, 0), 2) }
        return spots.firstIndex(of: .active) ?? spots.lastIndex(of: .done) ?? 0
    }

    /// Where the phone is when the diagram appears, so that it slides to its target: the first spot that is done.
    static func phoneStart(spots: [SpotsDiagram.SpotState], target: Int) -> Int {
        spots.firstIndex(of: .done) ?? target
    }
}

// MARK: - View

/// The top-view illustration of the Measure flow. `.guide` (V3MGuide): both speakers play toward a sofa, with three
/// measuring spots in a row at head height. `.running` (V3MRunning, "Your head, from above"): your head and the
/// three spots, with the phone sliding from the spot that is done to the next.
///
/// Spots are `done` (filled `lime` with a check), `active` (`lime`, with the pulse ring) or `upcoming` (dashed
/// `guide`). Each state differs in shape, not only colour. Loops (sound arcs, pulse ring) run only while they are
/// true and stop with Reduce Motion, leaving the arcs drawn. Put it in a panel with no padding:
/// `resoniqPanel(insets: EdgeInsets())`. One element for VoiceOver: the sentence passed as `accessibilityLabel`.
public struct SpotsDiagram: View {
    public enum Variant: Sendable {
        case guide
        case running
    }

    public enum SpotState: Sendable {
        case done
        case active
        case upcoming
    }

    private let variant: Variant
    private let spots: [SpotState]
    private let phoneSpot: Int?
    private let isPlaying: Bool
    private let caption: String?
    private let accessibilityText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownPhoneSpot: Int

    /// - Parameters:
    ///   - spots: The state of the spots from left to right (three).
    ///   - phoneSpot: Where the phone glyph is (running variant). It defaults to the active spot, and on
    ///     appearing it slides there from the first spot that is done, with `ResoniqMotion.settle`.
    ///   - isPlaying: The speakers are playing, so their sound arcs pulse (guide variant).
    ///   - caption: The caps label inside the panel; "Both play" on the guide, "Your head, from above" while
    ///     running. Pass an empty string for none.
    ///   - accessibilityLabel: One sentence that states what the diagram shows.
    public init(
        _ variant: Variant,
        spots: [SpotState]? = nil,
        phoneSpot: Int? = nil,
        isPlaying: Bool = true,
        caption: String? = nil,
        accessibilityLabel: String
    ) {
        let spots = SpotsGeometry.normalised(spots ?? (variant == .guide ? [.upcoming, .active, .upcoming] : [.active, .done, .upcoming]))
        self.variant = variant
        self.spots = spots
        self.phoneSpot = phoneSpot
        self.isPlaying = isPlaying
        self.caption = caption
        self.accessibilityText = accessibilityLabel
        let target = SpotsGeometry.phoneTarget(spots: spots, requested: phoneSpot)
        _shownPhoneSpot = State(initialValue: SpotsGeometry.phoneStart(spots: spots, target: target))
    }

    private var natural: CGSize { SpotsGeometry.size(of: variant) }
    private var centres: [CGPoint] { SpotsGeometry.spotCentres(of: variant) }
    private var target: Int { SpotsGeometry.phoneTarget(spots: spots, requested: phoneSpot) }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(in: &context) }
                if variant == .guide { soundArcs }
                ForEach(spots.indices, id: \.self) { index in
                    if spots[index] == .active {
                        PulseRing(diameter: Metrics.spotDiameter, color: ResoniqColor.lime, lineWidth: Metrics.spotStroke)
                            .position(centres[index])
                    }
                }
                if variant == .running { phone }
            }
            .frame(width: natural.width, height: natural.height)
            .scaleEffect(proxy.size.width / natural.width, anchor: .topLeading)
        }
        .aspectRatio(natural.width / natural.height, contentMode: .fit)
        .overlay(alignment: variant == .guide ? .top : .bottomLeading) { captionView }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
        .onAppear { slidePhone() }
        .onChange(of: target) { slidePhone() }
    }

    private func slidePhone() {
        withAnimation(reduceMotion ? nil : ResoniqMotion.settle) { shownPhoneSpot = target }
    }

    // MARK: Pieces

    @ViewBuilder
    private var captionView: some View {
        let text = caption ?? (variant == .guide ? "Both play" : "Your head, from above")
        if !text.isEmpty {
            Text(text)
                .resoniqCapsLabel()
                .accessibilityHidden(true)
                .padding(variant == .guide ? EdgeInsets(top: Metrics.guideCaptionTop, leading: 0, bottom: 0, trailing: 0)
                    : EdgeInsets(top: 0, leading: Metrics.runningCaptionInset, bottom: Metrics.runningCaptionBottom, trailing: 0))
        }
    }

    /// Three arcs under each speaker, fading in turn: "Sound arcs" of the motion table.
    private var soundArcs: some View {
        ForEach(0..<2, id: \.self) { side in
            ForEach(SpotsGeometry.arcs.indices, id: \.self) { index in
                let arc = SpotsGeometry.arcs[index]
                let speaker = SpotsGeometry.speakerCentres[side]
                LoopingPhase(
                    isRunning: isPlaying,
                    animation: Metrics.soundWave.delay(Double(index) * Metrics.soundStagger)
                ) { phase, isActive in
                    ArcShape(centre: CGPoint(x: speaker.x, y: speaker.y + arc.offset), radius: arc.radius)
                        .stroke(ResoniqColor.teal, style: StrokeStyle(lineWidth: Metrics.arcStroke, lineCap: .round))
                        .opacity(isActive && !phase ? Metrics.arcLow : 1)
                }
            }
        }
    }

    private var phone: some View {
        RoundedRectangle(cornerRadius: Metrics.phoneRadius, style: .continuous)
            .fill(ResoniqColor.panel.opacity(Metrics.phoneFill))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.phoneRadius, style: .continuous)
                    .strokeBorder(ResoniqColor.ivory, lineWidth: Metrics.phoneStroke)
            }
            .frame(width: Metrics.phoneSize.width, height: Metrics.phoneSize.height)
            .position(x: centres[shownPhoneSpot].x, y: Metrics.phoneCentreY)
    }

    // MARK: Canvas

    private func draw(in context: inout GraphicsContext) {
        switch variant {
        case .guide: drawGuideScene(in: &context)
        case .running: drawRunningScene(in: &context)
        }
        for index in spots.indices {
            drawSpot(spots[index], at: centres[index], number: SpotsGeometry.numbers[index], in: &context)
        }
    }

    private func drawGuideScene(in context: inout GraphicsContext) {
        let side = SpotsGeometry.speakerSide
        for centre in SpotsGeometry.speakerCentres {
            context.fill(
                Path(roundedRect: CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side), cornerRadius: Metrics.speakerRadius),
                with: .color(ResoniqColor.ivory)
            )
        }
        // The sofa, with the seat's head circle on it.
        context.stroke(
            Path(roundedRect: CGRect(x: 76, y: 208, width: 188, height: 66), cornerRadius: Metrics.sofaRadius),
            with: .color(ResoniqColor.muted), lineWidth: Metrics.sceneStroke
        )
        context.stroke(
            Path(ellipseIn: CGRect(x: 150, y: 204, width: 40, height: 40)),
            with: .color(ResoniqColor.muted),
            style: StrokeStyle(lineWidth: Metrics.sceneStroke, lineCap: .round, dash: Metrics.headDash)
        )
        // The 30 cm bracket between the middle and right spots.
        var bracket = Path()
        bracket.move(to: CGPoint(x: 176, y: 190)); bracket.addLine(to: CGPoint(x: 220, y: 190))
        bracket.move(to: CGPoint(x: 176, y: 184)); bracket.addLine(to: CGPoint(x: 176, y: 196))
        bracket.move(to: CGPoint(x: 220, y: 184)); bracket.addLine(to: CGPoint(x: 220, y: 196))
        context.stroke(bracket, with: .color(ResoniqColor.muted), style: StrokeStyle(lineWidth: Metrics.bracketStroke, lineCap: .round))
        context.draw(
            Text("30 cm").font(Metrics.canvasFont).foregroundStyle(ResoniqColor.muted),
            at: CGPoint(x: 198, y: 176), anchor: .center
        )
    }

    private func drawRunningScene(in context: inout GraphicsContext) {
        // Your head, from above.
        context.stroke(
            Path(ellipseIn: CGRect(x: 144, y: 52, width: 52, height: 52)),
            with: .color(ResoniqColor.muted),
            style: StrokeStyle(lineWidth: Metrics.sceneStroke, lineCap: .round, dash: Metrics.headDash)
        )
        // The arrow from the spot that is done to the one that is next.
        guard let done = spots.firstIndex(of: .done), let next = spots.firstIndex(of: .active), done != next else { return }
        let direction: CGFloat = centres[next].x < centres[done].x ? -1 : 1
        let from = centres[done].x + direction * Metrics.arrowStart
        let to = centres[next].x - direction * Metrics.arrowEnd
        var arrow = Path()
        arrow.move(to: CGPoint(x: from, y: Metrics.arrowY)); arrow.addLine(to: CGPoint(x: to, y: Metrics.arrowY))
        arrow.move(to: CGPoint(x: to - direction * 6, y: Metrics.arrowY - 6))
        arrow.addLine(to: CGPoint(x: to, y: Metrics.arrowY))
        arrow.addLine(to: CGPoint(x: to - direction * 6, y: Metrics.arrowY + 6))
        context.stroke(arrow, with: .color(ResoniqColor.ivory), style: StrokeStyle(lineWidth: Metrics.spotStroke, lineCap: .round, lineJoin: .round))
    }

    private func drawSpot(_ state: SpotState, at centre: CGPoint, number: Int, in context: inout GraphicsContext) {
        let radius = Metrics.spotDiameter / 2
        let circle = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: Metrics.spotDiameter, height: Metrics.spotDiameter))
        let style = StrokeStyle(lineWidth: Metrics.spotStroke, lineCap: .round, lineJoin: .round)
        switch state {
        case .done:
            context.fill(circle, with: .color(ResoniqColor.lime))
            var check = Path()
            check.move(to: CGPoint(x: centre.x - 4.5, y: centre.y))
            check.addLine(to: CGPoint(x: centre.x - 1.5, y: centre.y + 3))
            check.addLine(to: CGPoint(x: centre.x + 4, y: centre.y - 3))
            context.stroke(check, with: .color(ResoniqColor.ink), style: style)
        case .active:
            if variant == .guide {
                // Where to start: a filled spot with its number.
                context.fill(circle, with: .color(ResoniqColor.lime))
                drawNumber(number, at: centre, color: ResoniqColor.ink, in: &context)
            } else {
                context.stroke(circle, with: .color(ResoniqColor.lime), style: style)
            }
        case .upcoming:
            context.stroke(circle, with: .color(ResoniqColor.guide), style: StrokeStyle(lineWidth: Metrics.spotStroke, lineCap: .round, dash: Metrics.upcomingDash))
            if variant == .guide { drawNumber(number, at: centre, color: ResoniqColor.guide, in: &context) }
        }
    }

    private func drawNumber(_ number: Int, at centre: CGPoint, color: Color, in context: inout GraphicsContext) {
        context.draw(
            Text("\(number)").font(Metrics.canvasFont).foregroundStyle(color),
            at: CGPoint(x: centre.x, y: centre.y + 1), anchor: .center
        )
    }

    private enum Metrics {
        static let spotDiameter: CGFloat = 18
        static let spotStroke: CGFloat = 2
        static let upcomingDash: [CGFloat] = [3, 4]
        static let sceneStroke: CGFloat = 1.5
        static let bracketStroke: CGFloat = 1.2
        static let headDash: [CGFloat] = [3, 5]
        static let speakerRadius: CGFloat = 4
        static let sofaRadius: CGFloat = 12
        static let arcStroke: CGFloat = 2.5
        static let arcLow: Double = 0.2
        /// loop.soundWave: a 1.8 s period (0.9 s each way) with 0.25 s between arcs.
        static let soundWave = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
        static let soundStagger: Double = 0.25
        static let phoneSize = CGSize(width: 24, height: 42)
        static let phoneCentreY: CGFloat = 59
        static let phoneRadius: CGFloat = 5
        static let phoneStroke: CGFloat = 2
        static let phoneFill: Double = 0.6
        static let arrowY: CGFloat = 30
        static let arrowStart: CGFloat = 20
        static let arrowEnd: CGFloat = 14
        static let guideCaptionTop: CGFloat = 26
        static let runningCaptionInset: CGFloat = 14
        static let runningCaptionBottom: CGFloat = 10
        /// Text inside the drawing is scaled with it, so it is a fixed size, not a Dynamic Type role.
        static let canvasFont = Font.custom(ResoniqFont.Face.monoRegular.postScriptName, fixedSize: 11)
    }
}

/// A half circle under its centre line, left to right.
private struct ArcShape: Shape {
    var centre: CGPoint
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = SpotsGeometry.arcPoints(centre: centre, radius: radius)
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

#Preview("Guide and running") {
    ScrollView {
        VStack(spacing: ResoniqSpace.s4) {
            SpotsDiagram(
                .guide,
                accessibilityLabel: "Seen from above: both speakers play toward a sofa. Three measuring spots sit in a row at head height, the middle one first."
            )
            .resoniqPanel(insets: EdgeInsets())
            SpotsDiagram(
                .guide, spots: [.upcoming, .upcoming, .upcoming], isPlaying: false,
                accessibilityLabel: "Both speakers are quiet. Three spots are waiting."
            )
            .resoniqPanel(insets: EdgeInsets())
            SpotsDiagram(
                .running, spots: [.active, .done, .upcoming],
                accessibilityLabel: "Three spots in a row. The middle one is done; the phone slides to the left one."
            )
            .resoniqPanel(insets: EdgeInsets())
            SpotsDiagram(
                .running, spots: [.done, .done, .active],
                accessibilityLabel: "Two spots are done; the phone is at the right one."
            )
            .resoniqPanel(insets: EdgeInsets())
        }
        .padding(ResoniqSpace.screenInset)
    }
    .background(ResoniqColor.ink)
}
