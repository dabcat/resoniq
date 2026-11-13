import ResoniqDesign
import SwiftUI

/// Shows the screen for the flow's step: Aim, Listening, Paused, the states with no mockup, and, when the test has
/// finished, the caller's own content. There is no tab bar inside the flow.
///
/// Leaving the view stops playback and the session.
struct DiagnoseFlowView<Result: View>: View {
    @Bindable var flow: DiagnoseFlow
    let onClose: () -> Void
    let result: (DiagnoseFlow.Completed) -> Result

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        flow: DiagnoseFlow,
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
    }

    @ViewBuilder
    private func screen(for step: DiagnoseFlow.Step) -> some View {
        switch step {
        case .aim:
            AimScreen(
                position: $flow.position, choices: flow.choices, singleName: flow.singleName, onStart: flow.start, onClose: onClose
            )
        case .listening:
            ListeningScreen(display: flow.runDisplay, onStop: flow.stop)
        case .paused:
            PausedScreen(display: flow.runDisplay, onStop: flow.stop)
        case .analysing:
            AnalysingScreen()
        case .finished(let completed):
            result(completed)
        case .failed(.permissionDenied):
            MicrophoneDeniedScreen(onOpenSettings: openSettings, onBack: flow.stop)
        case .failed(let failure):
            DiagnoseFailedScreen(failure: failure, onTryAgain: flow.tryAgain, onClose: onClose)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}
