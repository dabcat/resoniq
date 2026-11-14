import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import SwiftUI

/// Shows the screen for the external seat flow's step: the file, Three spots, the failure states, and, when the
/// measurement has finished, the caller's own content. There is no tab bar inside the flow. The counterpart of
/// `SeatFlowView`.
///
/// Leaving the view stops listening.
struct ExternalSeatFlowView<Finished: View>: View {
    @Bindable var flow: ExternalSeatFlow
    let onClose: () -> Void
    let finished: (SeatReport) -> Finished

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        flow: ExternalSeatFlow,
        onClose: @escaping () -> Void,
        @ViewBuilder finished: @escaping (SeatReport) -> Finished
    ) {
        self.flow = flow
        self.onClose = onClose
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
        #if DEBUG
        .simulatedPlayer(
            state: flow.sessionState, isListening: step == .running, isAvailable: flow.canSimulatePlay, play: flow.simulatePlay
        ) { state in
            switch state {
            case .waitingForSound, .needsAnotherPlay: true
            default: false
            }
        }
        #endif
    }

    @ViewBuilder
    private func screen(for step: ExternalSeatFlow.Step) -> some View {
        switch step {
        case .files:
            TestSoundScreen(context: flow.filesContext, onContinue: flow.start, onClose: onClose)
        case .running:
            ThreeSpotsScreen(display: flow.display, onStop: flow.stop, onSkip: flow.skipToResult)
        case .analysing:
            SeatAnalysingScreen()
        case .finished(let report):
            finished(report)
        case .stopped:
            StoppedInBackgroundScreen(onStartAgain: flow.start, onClose: onClose)
        case .failed(.measurement(.permissionDenied)):
            MicrophoneDeniedScreen(
                headline: ExternalSessionText.failureHeadline(.measurement(.permissionDenied)),
                message: ExternalSessionText.failureBody(.measurement(.permissionDenied), file: flow.file.kind),
                onOpenSettings: openSettings, onBack: flow.stop
            )
        case .failed(let failure):
            ExternalFailedScreen(failure: failure, file: flow.file.kind, onTryAgain: flow.tryAgain, onClose: onClose)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
