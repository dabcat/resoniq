import ResoniqDesign
import ResoniqDiagnostics
import SwiftUI

/// Shows the screen for the flow's step: Sit and aim, Three spots, Paused, the states with no mockup, and, when the
/// measurement has finished, the caller's own content. There is no tab bar inside the flow.
///
/// Leaving the view stops playback and the session.
struct SeatFlowView<Finished: View>: View {
    @Bindable var flow: SeatFlow
    /// The room's name, for Sit and aim.
    let room: String
    let onClose: () -> Void
    /// "My speakers can't play from this iPhone": carries on as a measurement whose sound another device plays.
    let onExternal: (() -> Void)?
    let finished: (SeatReport) -> Finished

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        flow: SeatFlow,
        room: String,
        onClose: @escaping () -> Void,
        onExternal: (() -> Void)? = nil,
        @ViewBuilder finished: @escaping (SeatReport) -> Finished
    ) {
        self.flow = flow
        self.room = room
        self.onClose = onClose
        self.onExternal = onExternal
        self.finished = finished
    }

    var body: some View {
        let step = flow.step
        ZStack {
            ResoniqColor.ink.ignoresSafeArea()
            screen(for: step)
                .id(step.screen)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : ResoniqMotion.enter, value: step.screen)
        .keepsScreenAwake(while: step.needsScreenAwake)
        .onDisappear { flow.cancel() }
    }

    @ViewBuilder
    private func screen(for step: SeatFlow.Step) -> some View {
        switch step {
        case .guide:
            SitAndAimScreen(room: room, onStart: flow.start, onBack: onClose, onExternal: onExternal)
        case .running:
            ThreeSpotsScreen(display: flow.display, onStop: flow.stop, onSkip: flow.skipToResult)
        case .paused:
            SeatPausedScreen(display: flow.display, onStop: flow.stop)
        case .analysing:
            SeatAnalysingScreen()
        case .finished(let report):
            finished(report)
        case .stopped:
            StoppedInBackgroundScreen(onStartAgain: flow.start, onClose: onClose)
        case .failed(.permissionDenied):
            MicrophoneDeniedScreen(onOpenSettings: openSettings, onBack: flow.stop)
        case .failed(let failure):
            SeatFailedScreen(failure: failure, onTryAgain: flow.tryAgain, onClose: onClose, onExternal: onExternal)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
