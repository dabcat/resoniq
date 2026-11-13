import ResoniqDesign
import ResoniqRoom
import SwiftUI

/// Scan (design/screens/V3OScan.dc.html): the camera full bleed with RoomPlan's outlines and the app's labels, a
/// close button and the wall count on top, the floor-plan inset in a corner, and a sheet with one instruction,
/// "Finish scan" and the way to enter the room by hand. The camera permission is asked here, the first time.
///
/// States without a mockup (permission needed, denied, no LiDAR, processing, failed) follow design/DESIGN_SYSTEM.md:
/// the frame of the other flow screens and its voice. Their copy is in `ScanText`.
struct ScanScreen: View {
    @State private var readiness: ScanReadiness
    @State private var model: RoomScanModel
    private let makeSource: () -> any RoomScanSource
    private let onScanned: (RoomScanResult) -> Void
    private let onManualEntry: () -> Void
    private let onClose: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// The scan's room, speakers and seat guessed (`isConfirmed == false`).
    init(onFinished: @escaping (RoomModel) -> Void, onManualEntry: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.init(onScanned: { onFinished($0.room) }, onManualEntry: onManualEntry, onClose: onClose)
    }

    /// The whole result: the room, what RoomPlan was unsure of, and the USDZ in a temporary file when there is one.
    init(onScanned: @escaping (RoomScanResult) -> Void, onManualEntry: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.init(
            readiness: ScanCapability.readiness(), makeSource: ScanCapability.makeSource,
            onScanned: onScanned, onManualEntry: onManualEntry, onClose: onClose)
    }

    /// For previews and debug screens: a fixed readiness, a source, and a phase to start in.
    init(
        readiness: ScanReadiness,
        makeSource: @escaping () -> any RoomScanSource,
        phase: ScanPhase = .preparing,
        onScanned: @escaping (RoomScanResult) -> Void,
        onManualEntry: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        _readiness = State(initialValue: readiness)
        _model = State(initialValue: RoomScanModel(source: makeSource(), phase: phase))
        self.makeSource = makeSource
        self.onScanned = onScanned
        self.onManualEntry = onManualEntry
        self.onClose = onClose
    }

    var body: some View {
        Group {
            switch readiness {
            case .ready:
                scan
            case .needsPermission:
                ScanMessageScreen(
                    caption: ScanText.screenTitle, headline: ScanText.permissionHeadline, message: ScanText.permissionBody,
                    primary: ScanText.allowCamera, onPrimary: askForCamera,
                    secondary: ScanText.manualEntry, onSecondary: onManualEntry, onClose: onClose)
            case .denied:
                ScanMessageScreen(
                    caption: ScanText.screenTitle, headline: ScanText.deniedHeadline, message: ScanText.deniedBody,
                    primary: ScanText.openSettings, onPrimary: openSettings,
                    secondary: ScanText.manualEntry, onSecondary: onManualEntry, onClose: onClose)
            case .unsupported:
                ScanMessageScreen(
                    caption: ScanText.screenTitle, headline: ScanText.unsupportedHeadline,
                    message: ScanText.unsupportedBody,
                    primary: ScanText.manualEntry, onPrimary: onManualEntry,
                    secondary: ScanText.notNow, onSecondary: onClose, onClose: onClose)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings: the camera may have been turned on.
            if phase == .active, readiness == .denied { readiness = ScanCapability.readiness() }
        }
    }

    @ViewBuilder
    private var scan: some View {
        switch model.phase {
        case .failed(let failure):
            ScanMessageScreen(
                caption: ScanText.failedCaption, headline: ScanText.failureHeadline(failure),
                message: ScanText.failureBody(failure),
                primary: failure == .deviceNotSupported ? ScanText.manualEntry : ScanText.tryAgain,
                onPrimary: failure == .deviceNotSupported ? onManualEntry : scanAgain,
                secondary: failure == .deviceNotSupported ? ScanText.notNow : ScanText.manualEntry,
                onSecondary: failure == .deviceNotSupported ? onClose : onManualEntry,
                onClose: onClose)
        default:
            ScanningView(model: model, onManualEntry: onManualEntry, onClose: close)
                // A new scan gets a new camera view (and with it a new RoomPlan session).
                .id(ObjectIdentifier(model))
                .onAppear { model.start() }
                .onChange(of: model.phase) { _, phase in
                    if case .finished(let result) = phase { onScanned(result) }
                }
        }
    }

    private func askForCamera() {
        Task {
            await ScanCapability.requestCamera()
            readiness = ScanCapability.readiness()
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func scanAgain() {
        model = RoomScanModel(source: makeSource())
    }

    private func close() {
        model.cancel()
        onClose()
    }
}

// MARK: - Scanning

/// The camera with its overlay and the instruction sheet (the mockup).
private struct ScanningView: View {
    let model: RoomScanModel
    let onManualEntry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.clear
                LabelLayer(labels: model.labels)
                VStack {
                    HStack {
                        Button(action: onClose) {
                            CloseGlyph()
                                .stroke(style: StrokeStyle(lineWidth: Metrics.closeStroke, lineCap: .round))
                                .frame(width: Metrics.closeGlyph, height: Metrics.closeGlyph)
                        }
                        .buttonStyle(ResoniqIconButtonStyle(on: .overCamera))
                        .accessibilityLabel(ScanText.close)
                        Spacer(minLength: ResoniqSpace.s3)
                        ARStepPill(ScanText.wallCount(model.coverage))
                            .accessibilityLabel(ScanText.insetSummary(model.coverage))
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        FloorPlanInset(
                            walls: insetWalls, camera: insetCamera,
                            cameraFacing: model.camera.map { ScanProgress.insetFacing(planAngle: $0.heading) } ?? 0,
                            caption: ScanText.insetCaption, accessibilityLabel: ScanText.insetSummary(model.coverage))
                    }
                }
                .padding(.horizontal, ResoniqSpace.s5)
                .padding(.top, ResoniqSpace.s2)
                .padding(.bottom, ResoniqSpace.s4 + ResoniqRadius.sheet)
            }
            .frame(maxHeight: .infinity)

            ScanSheet(model: model, onManualEntry: onManualEntry)
                .padding(.top, -ResoniqRadius.sheet)
        }
        .background {
            model.source.makeCameraView(for: model)
        }
        .background(ResoniqColor.ink)
        .onChange(of: model.guidance.headline) { _, headline in
            AccessibilityNotification.Announcement(headline).post()
        }
    }

    /// Captured walls solid, the probable missing ones dashed, in plan metres (x right, z down the inset).
    private var insetWalls: [FloorPlanInset.Wall] {
        func segment(_ wall: Wall) -> RoomPlanContent.Segment {
            RoomPlanContent.Segment(x1: wall.start.x, y1: wall.start.z, x2: wall.end.x, y2: wall.end.z)
        }
        return model.room.walls.map { FloorPlanInset.Wall(segment($0), isCaptured: true) }
            + model.missingWalls.map { FloorPlanInset.Wall(segment($0), isCaptured: false) }
    }

    private var insetCamera: CGPoint {
        if let position = model.camera?.position { return CGPoint(x: position.x, y: position.z) }
        let centre = RoomGeometry.bounds(of: model.room)?.centre ?? .zero
        return CGPoint(x: centre.x, y: centre.z)
    }

    private enum Metrics {
        static let closeGlyph: CGFloat = 18
        static let closeStroke: CGFloat = 2
    }
}

/// The labels RoomPlan's view does not draw: what each thing is and each wall's length, where it is on screen.
private struct LabelLayer: View {
    let labels: [ScanLabel]

    var body: some View {
        GeometryReader { proxy in
            ForEach(labels) { label in
                ResoniqChip(label.text, style: label.isMeasurement ? .measurement : .detected)
                    .fixedSize()
                    .position(x: label.position.x * proxy.size.width, y: label.position.y * proxy.size.height)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(labels.map(\.text).joined(separator: ", "))
        .accessibilityHidden(labels.isEmpty)
    }
}

/// The bottom of V3OScan: the instruction with its arrow, the line under it, and the two actions. While RoomPlan
/// builds the room (no mockup) the actions give way to a waiting line.
private struct ScanSheet: View {
    let model: RoomScanModel
    let onManualEntry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
            switch model.phase {
            case .processing, .finished:
                instruction(ScanGuidance(headline: ScanText.processingHeadline, detail: ScanText.processingBody))
                HStack(spacing: ResoniqSpace.s2) {
                    Circle()
                        .fill(ResoniqColor.ivory)
                        .frame(width: Metrics.dot, height: Metrics.dot)
                        .resoniqWaitingPulse(low: Metrics.pulseLow)
                        .accessibilityHidden(true)
                    Text(ScanText.processingStatus)
                        .font(ResoniqFont.button)
                        .foregroundStyle(ResoniqColor.ivory)
                }
                .frame(maxWidth: .infinity, minHeight: ResoniqSize.buttonHeight + ResoniqSize.touchMin)
                .accessibilityElement(children: .combine)
            default:
                instruction(model.phase == .preparing ? ScanGuidance(headline: ScanText.preparing, detail: ScanText.walkSlowly) : model.guidance)
                VStack(spacing: 0) {
                    Button(ScanText.finish, action: model.finish)
                        .buttonStyle(ResoniqPrimaryButtonStyle())
                        .disabled(!model.canFinish)
                        .opacity(model.canFinish ? 1 : Metrics.disabledOpacity)
                    Button(ScanText.manualEntryLink) {
                        model.cancel()
                        onManualEntry()
                    }
                    .buttonStyle(ResoniqTextLinkStyle())
                }
                .padding(.top, ResoniqSpace.s3)
            }
        }
        .padding(.horizontal, ResoniqSpace.screenInset)
        .padding(.top, Metrics.topPadding)
        .padding(.bottom, ResoniqSpace.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ResoniqColor.ink,
            in: UnevenRoundedRectangle(topLeadingRadius: ResoniqRadius.sheet, topTrailingRadius: ResoniqRadius.sheet)
        )
        .background(alignment: .bottom) {
            // Continues the sheet under the home indicator.
            ResoniqColor.ink.frame(height: ResoniqRadius.sheet).ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private func instruction(_ guidance: ScanGuidance) -> some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
            if let direction = guidance.direction {
                DirectionArrowInstruction(direction.arrow, text: guidance.headline)
            } else {
                Text(guidance.headline)
                    .font(ResoniqFont.title3)
                    .tracking(Metrics.headlineSize * ResoniqFont.Tracking.title)
                    .foregroundStyle(ResoniqColor.ivory)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(guidance.detail)
                .font(ResoniqFont.body)
                .foregroundStyle(ResoniqColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Metrics {
        static let topPadding: CGFloat = 22
        static let headlineSize: CGFloat = 26
        static let dot: CGFloat = 8
        static let pulseLow = 0.35
        static let disabledOpacity = 0.4
    }
}

private extension ScanDirection {
    var arrow: DirectionArrowInstruction.Direction {
        switch self {
        case .forward: .forward
        case .back: .back
        case .left: .left
        case .right: .right
        }
    }
}

/// V3OScan's close glyph: two strokes corner to corner in an 18 pt square.
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

// MARK: - States without a mockup

/// A state with nothing to draw: a caps caption and close button, a headline and a sentence, one primary action and
/// a quieter alternative (the frame of the Diagnose flow's states).
struct ScanMessageScreen: View {
    let caption: String
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
                Text(caption)
                    .resoniqCapsLabel()
                Spacer(minLength: ResoniqSpace.s2)
                Button(action: onClose) {
                    CloseGlyph()
                        .stroke(style: StrokeStyle(lineWidth: Metrics.closeStroke, lineCap: .round))
                        .frame(width: Metrics.closeGlyph, height: Metrics.closeGlyph)
                }
                .buttonStyle(ResoniqIconButtonStyle())
                .accessibilityLabel(ScanText.close)
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

#if DEBUG
#Preview("Scanning (scripted)") {
    ScanScreen(
        readiness: .ready, makeSource: { ScriptedRoomScanSource(autoFinish: false) },
        onScanned: { _ in }, onManualEntry: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Permission") {
    ScanScreen(
        readiness: .needsPermission, makeSource: { ScriptedRoomScanSource() },
        onScanned: { _ in }, onManualEntry: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Failed") {
    ScanScreen(
        readiness: .ready, makeSource: { ScriptedRoomScanSource() }, phase: .failed(.worldTrackingFailure),
        onScanned: { _ in }, onManualEntry: {}, onClose: {})
        .preferredColorScheme(.dark)
}
#endif
