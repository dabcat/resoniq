import ResoniqAudio
import ResoniqDesign
import SwiftUI

// States of the listening flows (a speaker test or the seat, when another device plays the test sound) that have no
// mockup. They follow design/DESIGN_SYSTEM.md like the other failure screens: the frame of the flow screens, a
// headline and a sentence, an evidence tag where the failure rests on something, "Try again" and "Not now". Every
// word is the Kit's (`ExternalSessionText`). Listed in the pull request as "no mockup".

/// A listening that ended without a result: nothing heard, the sound not recognised (a converted copy, other music or a
/// subwoofer on its own), the player's clock too far off, too noisy, interrupted, and the rest of
/// `ExternalMeasurementFailure`. The microphone being off has its own screen (`MicrophoneDeniedScreen`).
///
/// "Try again" listens again with the file the person already has; the failures that "could not decide" carry the
/// "Inconclusive" tag and the one that measured something (the player's clock) carries "Measured".
struct ExternalFailedScreen: View {
    let failure: ExternalMeasurementFailure
    /// The file listened for, for the file's name in the sentences.
    let file: TestSoundFile.Kind
    var onTryAgain: () -> Void
    var onClose: () -> Void

    var body: some View {
        let headline = ExternalSessionText.failureHeadline(failure)
        let body = ExternalSessionText.failureBody(failure, file: file)
        FlowScaffold {
            Text("Resoniq")
                .font(ResoniqFont.headline)
                .foregroundStyle(ResoniqColor.ivory)
        } content: {
            MeasureMessage(headline: headline, message: body) {
                if let basis = ExternalSessionText.failureBasis(failure) {
                    ResoniqEvidenceTag(Self.isMeasured(failure) ? .measured : .inconclusive, basis: basis)
                }
            }
            .padding(.top, ResoniqSpace.s6)
        } footer: {
            VStack(spacing: ResoniqSpace.s1) {
                Button("Try again", action: onTryAgain)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
                Button("Not now", action: onClose)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
        }
        // The screen takes over from the listening screen: VoiceOver reads what happened, not just "screen changed".
        .onAppear { AccessibilityNotification.Announcement("\(headline) \(body)").post() }
        .accessibilityAction(.escape, onClose)
    }

    /// The player's clock was measured; every other ending is one that could not decide.
    private static func isMeasured(_ failure: ExternalMeasurementFailure) -> Bool {
        if case .playerClockOff = failure { return true }
        return false
    }
}

#if DEBUG
#Preview("Nothing heard") {
    ExternalFailedScreen(failure: .nothingHeard, file: .speakerTest(.left), onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Not recognised") {
    ExternalFailedScreen(failure: .soundNotRecognised, file: .speakerTest(.right), onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Player's clock off") {
    ExternalFailedScreen(failure: .playerClockOff(ratio: 1.032), file: .speakerTest(.left), onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Time up") {
    ExternalFailedScreen(
        failure: .listeningTimeUp(lastProblem: .missedSweeps), file: .seat([.left, .right]), onTryAgain: {}, onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Too noisy") {
    ExternalFailedScreen(failure: .measurement(.tooNoisy), file: .speakerTest(.left), onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Interrupted, large type") {
    ExternalFailedScreen(failure: .measurement(.interrupted), file: .speakerTest(.left), onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
#endif
