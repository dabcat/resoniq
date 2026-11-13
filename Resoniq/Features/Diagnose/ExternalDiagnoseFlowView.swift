import ResoniqAudio
import ResoniqDesign
import SwiftUI

/// Shows the screen for the external flow's step: the files, listening, the failure states, and, when the test has
/// finished, the caller's own content. There is no tab bar inside the flow. The counterpart of `DiagnoseFlowView`.
///
/// Leaving the view stops listening.
struct ExternalDiagnoseFlowView<Result: View>: View {
    @Bindable var flow: ExternalDiagnoseFlow
    let onClose: () -> Void
    let result: (DiagnoseFlow.Completed) -> Result

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        flow: ExternalDiagnoseFlow,
        onClose: @escaping () -> Void,
        @ViewBuilder result: @escaping (DiagnoseFlow.Completed) -> Result
    ) {
        self.flow = flow
        self.onClose = onClose
        self.result = result
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
        .onDisappear { flow.cancel() }
        #if DEBUG
        .simulatedPlayer(
            state: flow.sessionState, isListening: step == .listening, isAvailable: flow.canSimulatePlay, play: flow.simulatePlay
        ) { state in
            switch state {
            case .waitingForSound, .needsAnotherPlay: true
            default: false
            }
        }
        #endif
    }

    @ViewBuilder
    private func screen(for step: ExternalDiagnoseFlow.Step) -> some View {
        switch step {
        case .files:
            TestSoundScreen(context: flow.filesContext, onContinue: flow.start, onClose: onClose)
        case .listening:
            ExternalListeningScreen(display: flow.display, onStop: flow.stop)
        case .analysing:
            AnalysingScreen()
        case .finished(let completed):
            result(completed)
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
