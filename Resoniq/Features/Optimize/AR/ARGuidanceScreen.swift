import ResoniqDesign
import ResoniqRoom
import SwiftUI

/// AR guidance (design/screens/V3OAR.dc.html): the camera full bleed with the target footprint, the speaker's
/// footprint and the turn arc on the floor; the step pill and the "To go" card over it; and a sheet with the
/// instruction, the progress bar and its two lines, the haptics line, "Can't move it" and "It's in place".
///
/// States without a mockup, which follow design/DESIGN_SYSTEM.md (the frame and voice of the scan's states): the
/// camera permission needed or denied, AR not available, finding the floor, marking the speaker and then the second
/// point (the other speaker, or the seat) that lines the plan up with the room (each with its own instruction and
/// primary button in the same sheet), marks that do not agree with the plan ("Mark again" or "Fix the layout"),
/// tracking limited or interrupted (the sheet's instruction gives way to what to do), the follow control over the
/// camera, and "Mark again". Copy is in the Kit's `ARGuidanceText` and `RoomText`.
struct ARGuidanceScreen: View {
    @State private var readiness: ScanReadiness
    @State private var model: ARGuidanceModel
    private let onPlaced: (ARPlacement) -> Void
    private let onDeclined: () -> Void
    private let onFixLayout: () -> Void
    private let onClose: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// - Parameters:
    ///   - onPlaced: "It's in place": where the person last pointed at the speaker, in room-model coordinates, and
    ///     how far that is from the suggested spot; the facing is the suggestion's, as they confirmed the turn by eye.
    ///   - onDeclined: "Can't move it".
    ///   - onFixLayout: "Fix the layout", when the marks do not agree with the plan.
    init(suggestion: PlacementSuggestion, room: RoomModel, onPlaced: @escaping (ARPlacement) -> Void,
         onDeclined: @escaping () -> Void, onFixLayout: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.init(
            suggestion: suggestion, room: room, readiness: ARGuidanceCapability.readiness(),
            source: ARGuidanceCapability.makeSource(), haptics: ARGuidanceCapability.makeHaptics(),
            onPlaced: onPlaced, onDeclined: onDeclined, onFixLayout: onFixLayout, onClose: onClose)
    }

    /// For previews and debug screens: a fixed readiness and a source.
    init(suggestion: PlacementSuggestion, room: RoomModel, readiness: ScanReadiness, source: any ARGuidanceSource,
         haptics: any ARGuidanceHaptics = SilentARGuidanceHaptics(), onPlaced: @escaping (ARPlacement) -> Void,
         onDeclined: @escaping () -> Void, onFixLayout: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        _readiness = State(initialValue: readiness)
        _model = State(initialValue: ARGuidanceModel(suggestion: suggestion, room: room, source: source, haptics: haptics))
        self.onPlaced = onPlaced
        self.onDeclined = onDeclined
        self.onFixLayout = onFixLayout
        self.onClose = onClose
    }

    var body: some View {
        Group {
            switch readiness {
            case .ready:
                GuidingView(model: model, onFixLayout: fixLayout, onClose: close)
                    .onAppear { model.start() }
                    .onDisappear { model.stop() }
                    .onChange(of: model.state.phase) { _, phase in
                        switch phase {
                        case .placed(let placement): onPlaced(placement)
                        case .declined: onDeclined()
                        default: break
                        }
                    }
            case .needsPermission:
                ARMessageScreen(
                    headline: ARGuidanceText.permissionHeadline, message: ARGuidanceText.permissionBody,
                    primary: ARGuidanceText.allowCamera, onPrimary: askForCamera,
                    secondary: ARGuidanceText.notNow, onSecondary: onClose, onClose: onClose)
            case .denied:
                ARMessageScreen(
                    headline: ARGuidanceText.deniedHeadline, message: ARGuidanceText.deniedBody,
                    primary: ARGuidanceText.openSettings, onPrimary: openSettings,
                    secondary: ARGuidanceText.notNow, onSecondary: onClose, onClose: onClose)
            case .unsupported:
                ARMessageScreen(
                    headline: ARGuidanceText.unsupportedHeadline, message: ARGuidanceText.unsupportedBody,
                    primary: ARGuidanceText.notNow, onPrimary: onClose,
                    secondary: ARGuidanceText.cantMove, onSecondary: onDeclined, onClose: onClose)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings: the camera may have been turned on.
            if phase == .active, readiness == .denied { readiness = ARGuidanceCapability.readiness() }
        }
    }

    private func askForCamera() {
        Task {
            await ScanCapability.requestCamera()
            readiness = ARGuidanceCapability.readiness()
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func close() {
        model.stop()
        onClose()
    }

    private func fixLayout() {
        model.stop()
        onFixLayout()
    }
}

// MARK: - Guiding

/// The camera with its overlay and the sheet (the mockup).
private struct GuidingView: View {
    let model: ARGuidanceModel
    let onFixLayout: () -> Void
    let onClose: () -> Void

    var body: some View {
        let state = model.state
        let readout = state.readout
        VStack(spacing: 0) {
            ZStack {
                Color.clear
                VStack(alignment: .leading, spacing: ResoniqSpace.s5) {
                    HStack {
                        Button(action: onClose) {
                            CloseGlyph()
                                .stroke(style: StrokeStyle(lineWidth: Metrics.closeStroke, lineCap: .round))
                                .frame(width: Metrics.closeGlyph, height: Metrics.closeGlyph)
                        }
                        .buttonStyle(ResoniqIconButtonStyle(on: .overCamera))
                        .accessibilityLabel(ARGuidanceText.close)
                        Spacer(minLength: ResoniqSpace.s3)
                        ARStepPill(readout?.title ?? RoomText.title(state.suggestion.role))
                    }
                    if let readout, model.message == nil {
                        ARToGoCard(label: readout.toGoLabel, value: readout.value, unit: readout.unit)
                            .transition(.opacity)
                    }
                    Spacer()
                    if state.canFollow {
                        FollowControl(isOn: state.isFollowing, set: model.setFollowing)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, ResoniqSpace.s5)
                .padding(.top, ResoniqSpace.s2)
                .padding(.bottom, ResoniqSpace.s4 + ResoniqRadius.sheet)
            }
            .frame(maxHeight: .infinity)
            .overlay {
                if let point = model.arcLabelPoint, let text = state.arcLabel {
                    GeometryReader { _ in
                        ARTurnLabel(text: text).position(point)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            }

            GuidanceSheet(model: model, onFixLayout: onFixLayout)
                .padding(.top, -ResoniqRadius.sheet)
        }
        .background {
            model.source.makeCameraView(for: model)
        }
        .background(ResoniqColor.ink)
    }

    private enum Metrics {
        static let closeGlyph: CGFloat = 18
        static let closeStroke: CGFloat = 2
    }
}

/// Held while the reticle is on the speaker's front, the white outline follows it: the one way the phone learns
/// where the speaker has got to. A hold, not a toggle, so it cannot be left on while the phone looks elsewhere;
/// it sits over the camera where a thumb rests, so it works one-handed. VoiceOver toggles it instead.
private struct FollowControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Text(isOn ? ARGuidanceText.following : ARGuidanceText.followHold)
            .font(Metrics.font)
            .foregroundStyle(isOn ? ResoniqColor.ink : ResoniqColor.ivory)
            .multilineTextAlignment(.center)
            .padding(.horizontal, ResoniqSpace.s5)
            .frame(minHeight: ResoniqSize.buttonHeight)
            .background(isOn ? ResoniqColor.guide : ResoniqColor.ink, in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(isOn && !reduceMotion ? ResoniqMotion.pressedScale : 1)
            .animation(reduceMotion ? nil : ResoniqMotion.press, value: isOn)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: Metrics.slop, perform: {}, onPressingChanged: set)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ARGuidanceText.followLabel)
            .accessibilityValue(isOn ? ARGuidanceText.followOn : ARGuidanceText.followOff)
            .accessibilityHint(ARGuidanceText.followHint)
            .accessibilityAddTraits([.isButton, .isToggle])
            .accessibilityAction { set(!isOn) }
    }

    private enum Metrics {
        static let font = ResoniqFont.font(.sansMedium, size: 15, relativeTo: .body)
        /// How far a thumb may wander while holding, points.
        static let slop: CGFloat = 80
    }
}

/// The bottom of V3OAR: the instruction, the bar with its two lines, the haptics line and the two buttons; before
/// the target shows, the step's instruction and its mark button ("This is the speaker", then "This is the left
/// speaker" or "This is my seat"), or, when the marks do not agree, "Mark again" and "Fix the layout".
private struct GuidanceSheet: View {
    let model: ARGuidanceModel
    let onFixLayout: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: Metrics.gap) {
            if let message = model.message {
                instruction(message.headline, detail: message.detail)
            } else if let readout = state.readout {
                instruction(readout.instruction, detail: nil)
                progress(readout)
                if let hint = readout.hint {
                    HStack(spacing: Metrics.hintGap) {
                        Circle()
                            .fill(ResoniqColor.lime)
                            .frame(width: Metrics.dot, height: Metrics.dot)
                            .resoniqWaitingPulse(low: Metrics.dotLow)
                            .accessibilityHidden(true)
                        Text(hint)
                            .font(Metrics.hintFont)
                            .foregroundStyle(ResoniqColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            buttons(state)
        }
        .padding(.horizontal, ResoniqSpace.screenInset)
        .padding(.top, Metrics.topPadding)
        .padding(.bottom, ResoniqSpace.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            ResoniqColor.ink,
            in: UnevenRoundedRectangle(topLeadingRadius: ResoniqRadius.sheet, topTrailingRadius: ResoniqRadius.sheet)
        )
        .background(alignment: .bottom) {
            ResoniqColor.ink.frame(height: ResoniqRadius.sheet).ignoresSafeArea(edges: .bottom)
        }
    }

    private func instruction(_ headline: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
            Text(headline)
                .font(ResoniqFont.title3)
                .tracking(Metrics.headlineSize * ResoniqFont.Tracking.title)
                .foregroundStyle(ResoniqColor.ivory)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(ResoniqFont.body)
                    .foregroundStyle(ResoniqColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progress(_ readout: ARReadoutText) -> some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ResoniqColor.line)
                    Capsule()
                        .fill(ResoniqColor.lime)
                        .frame(width: proxy.size.width * min(max(readout.fraction, 0), 1))
                }
            }
            .frame(height: Metrics.barHeight)
            .animation(reduceMotion ? nil : ResoniqMotion.settle, value: readout.fraction)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(readout.progressLabel)
            .accessibilityValue(Text(readout.fraction, format: .percent.precision(.fractionLength(0))))
            .accessibilityAddTraits(.updatesFrequently)
            if readout.totalLine != nil || readout.turnLine != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) { lines(readout) }
                    VStack(alignment: .leading, spacing: ResoniqSpace.s1) { lines(readout) }
                }
                .font(ResoniqFont.axis)
                .foregroundStyle(ResoniqColor.muted)
            }
        }
    }

    @ViewBuilder
    private func lines(_ readout: ARReadoutText) -> some View {
        if let total = readout.totalLine { Text(total) }
        if readout.totalLine != nil, readout.turnLine != nil { Spacer(minLength: ResoniqSpace.s1) }
        if let turn = readout.turnLine { Text(turn) }
    }

    @ViewBuilder
    private func buttons(_ state: ARGuidanceState) -> some View {
        switch state.phase {
        case .findingFloor, .markingSpeaker:
            VStack(spacing: 0) {
                Button(ARGuidanceText.markButton, action: model.mark)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
                    .disabled(!state.canMark)
                    .opacity(state.canMark ? 1 : Metrics.disabledOpacity)
                Button(ARGuidanceText.cantMove, action: model.decline)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
            .padding(.top, ResoniqSpace.s2)
        case .markingReference:
            VStack(spacing: 0) {
                Button(state.reference.map { ARGuidanceText.markReferenceButton($0.kind) } ?? ARGuidanceText.markButton,
                       action: model.mark)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
                    .disabled(!state.canMark)
                    .opacity(state.canMark ? 1 : Metrics.disabledOpacity)
                Button(ARGuidanceText.markAgain, action: model.remark)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
            .padding(.top, ResoniqSpace.s2)
        case .cannotAlign(.marksDisagree):
            VStack(spacing: 0) {
                Button(ARGuidanceText.markAgain, action: model.remark)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
                Button(ARGuidanceText.fixLayout, action: onFixLayout)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
            .padding(.top, ResoniqSpace.s2)
        case .cannotAlign(.nothingElseToMark):
            VStack(spacing: 0) {
                Button(ARGuidanceText.fixLayout, action: onFixLayout)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
                Button(ARGuidanceText.cantMove, action: model.decline)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
            .padding(.top, ResoniqSpace.s2)
        case .sliding, .turning, .arrived:
            VStack(spacing: 0) {
                HStack(spacing: Metrics.buttonGap) {
                    Button(action: model.decline) {
                        Text(ARGuidanceText.cantMove).padding(.horizontal, Metrics.secondaryPadding)
                    }
                    .buttonStyle(ResoniqSecondaryButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
                    Button(ARGuidanceText.inPlace, action: model.confirm)
                        .buttonStyle(ResoniqPrimaryButtonStyle())
                        .disabled(!state.canConfirm)
                        .opacity(state.canConfirm ? 1 : Metrics.disabledOpacity)
                }
                Button(ARGuidanceText.markAgain, action: model.remark)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
            .padding(.top, ResoniqSpace.s2)
        case .placed, .declined:
            EmptyView()
        }
    }

    private enum Metrics {
        static let gap: CGFloat = 14
        static let topPadding: CGFloat = 22
        static let headlineSize: CGFloat = 26
        static let barHeight: CGFloat = 10
        static let hintGap: CGFloat = 10
        static let dot: CGFloat = 8
        static let dotLow = 0.45
        static let buttonGap: CGFloat = 10
        static let secondaryPadding: CGFloat = 22
        static let disabledOpacity = 0.4
        static let hintFont = ResoniqFont.font(.sansRegular, size: 14, relativeTo: .callout)
    }
}

// MARK: - States without a mockup

/// Permission needed or denied, AR not available: a caps caption and close button, a headline and a sentence,
/// one primary action and a quieter alternative (the frame of the scan's states).
private struct ARMessageScreen: View {
    let headline: String
    let message: String
    let primary: String
    let onPrimary: () -> Void
    let secondary: String
    let onSecondary: () -> Void
    let onClose: () -> Void

    var body: some View {
        FlowScaffold {
            HStack {
                Text(ARGuidanceText.screenTitle)
                    .resoniqCapsLabel()
                Spacer(minLength: ResoniqSpace.s2)
                Button(action: onClose) {
                    CloseGlyph()
                        .stroke(style: StrokeStyle(lineWidth: Metrics.closeStroke, lineCap: .round))
                        .frame(width: Metrics.closeGlyph, height: Metrics.closeGlyph)
                }
                .buttonStyle(ResoniqIconButtonStyle())
                .accessibilityLabel(ARGuidanceText.close)
            }
        } content: {
            VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
                Text(headline)
                    .font(ResoniqFont.display)
                    .tracking(Metrics.displaySize * ResoniqFont.Tracking.title)
                    .foregroundStyle(ResoniqColor.ivory)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(ResoniqFont.bodyLarge)
                    .foregroundStyle(ResoniqColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, ResoniqSpace.s6)
            .resoniqTitleRise()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } footer: {
            VStack(spacing: ResoniqSpace.s1) {
                Button(primary, action: onPrimary)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
                Button(secondary, action: onSecondary)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
        }
    }

    private enum Metrics {
        static let displaySize: CGFloat = 36
        static let closeGlyph: CGFloat = 18
        static let closeStroke: CGFloat = 2
    }
}

/// V3OAR's close glyph: two strokes corner to corner in an 18 pt square.
nonisolated private struct CloseGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 4 / 18
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
        return path
    }
}

#if DEBUG
#Preview("Guiding (scripted)") {
    let sample = ARGuidanceSample.rightSpeaker()
    ARGuidanceScreen(
        suggestion: sample.suggestion, room: sample.room, readiness: .ready,
        source: ScriptedARGuidanceSource(script: .whole), onPlaced: { _ in }, onDeclined: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Permission") {
    let sample = ARGuidanceSample.rightSpeaker()
    ARGuidanceScreen(
        suggestion: sample.suggestion, room: sample.room, readiness: .needsPermission,
        source: ScriptedARGuidanceSource(), onPlaced: { _ in }, onDeclined: {}, onClose: {})
        .preferredColorScheme(.dark)
}
#endif
