import ResoniqAudio
import ResoniqDesign
import SwiftUI

// States of the Diagnose flow that have no mockup. They follow design/DESIGN_SYSTEM.md: the frame of the other
// flow screens (header row, headline, body, one primary action, a quiet alternative), the voice (first person,
// calm, specific) and its motion (title rise, waiting dot). Listed in the pull request as "no mockup".

/// The frame every flow screen shares: a header row, content that takes the room left, and a footer. When the
/// content does not fit (large Dynamic Type, a small phone) it scrolls instead of clipping; the footer stays.
struct FlowScaffold<Header: View, Content: View, Footer: View>: View {
    private let header: Header
    private let content: Content
    private let footer: Footer

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: ScaffoldMetrics.gap) {
            header
                .frame(maxWidth: .infinity, minHeight: ResoniqSize.touchMin, alignment: .leading)
            ViewThatFits(in: .vertical) {
                content
                ScrollView {
                    content
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
            footer
        }
        .padding(.horizontal, ResoniqSpace.screenInset)
        .padding(.top, ResoniqSpace.s2)
        .padding(.bottom, ResoniqSpace.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ResoniqColor.ink)
    }
}

/// The gap between the header, the content and the footer in the mockups.
private enum ScaffoldMetrics {
    static let gap: CGFloat = 18
}

/// A headline, a sentence under it, and optionally an evidence tag above: the body of a state with nothing to draw.
private struct MessageBlock<Accessory: View>: View {
    let headline: String
    let message: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            accessory
            Text(headline)
                .font(ResoniqFont.display)
                .tracking(MessageMetrics.displaySize * ResoniqFont.Tracking.title)
                .foregroundStyle(ResoniqColor.ivory)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(ResoniqFont.bodyLarge)
                .foregroundStyle(ResoniqColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .resoniqTitleRise()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private enum MessageMetrics {
    static let displaySize: CGFloat = 36
}

// MARK: - Microphone denied

/// The microphone is off for Resoniq. Says what happened, why it is needed, and opens Settings.
struct MicrophoneDeniedScreen: View {
    /// What it says: a normal test's words by default; a listening test passes the Kit's own (`ExternalSessionText`).
    var headline = DiagnoseText.failureHeadline(.permissionDenied)
    var message = DiagnoseText.failureBody(.permissionDenied)
    var onOpenSettings: () -> Void
    var onBack: () -> Void

    var body: some View {
        FlowScaffold {
            Text("Resoniq")
                .font(ResoniqFont.headline)
                .foregroundStyle(ResoniqColor.ivory)
        } content: {
            MessageBlock(headline: headline, message: message) {
                EmptyView()
            }
            .padding(.top, ResoniqSpace.s6)
        } footer: {
            VStack(spacing: ResoniqSpace.s1) {
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
                Button("Not now", action: onBack)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
        }
    }
}

// MARK: - Test failed

/// A test that ended without a result: a run failed twice, the room never got quiet enough, the sound would have come
/// from the phone itself, or the audio was interrupted, switched route or could not start. Says why in a sentence and
/// offers another try. A run that failed twice, and a room that stayed too loud, are "Inconclusive", as the design
/// system names a test that could not decide. A test with the speakers not connected is not inconclusive: nothing
/// was played, so there was nothing to decide.
///
/// When the sound would have come from the phone, "Play the test sound from another device" sits beside "Try again"
/// (`onExternal`): for a system that cannot take sound from the iPhone, that is the way on.
struct DiagnoseFailedScreen: View {
    var failure: DiagnoseFlow.Failure
    var onTryAgain: () -> Void
    var onClose: () -> Void
    var onExternal: (() -> Void)?

    var body: some View {
        FlowScaffold {
            Text("Resoniq")
                .font(ResoniqFont.headline)
                .foregroundStyle(ResoniqColor.ivory)
        } content: {
            MessageBlock(
                headline: DiagnoseText.failureHeadline(failure),
                message: DiagnoseText.failureBody(failure)
            ) {
                if let basis = DiagnoseText.failureBasis(failure) {
                    ResoniqEvidenceTag(.inconclusive, basis: basis)
                }
            }
            .padding(.top, ResoniqSpace.s6)
        } footer: {
            VStack(spacing: ResoniqSpace.s1) {
                Button("Try again", action: onTryAgain)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
                if case .speakersNotConnected = failure, let onExternal {
                    Button(TestSoundText.entryButton, action: onExternal)
                        .buttonStyle(ResoniqSecondaryButtonStyle(.outlined))
                }
                Button("Not now", action: onClose)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
        }
        // The screen takes over from the listening screen: VoiceOver reads what happened, not just "screen changed".
        .onAppear { AccessibilityNotification.Announcement(DiagnoseText.failureAnnouncement(failure)).post() }
    }
}

// MARK: - Analysing

/// The moment between the last run and the result: the runs are being compared.
struct AnalysingScreen: View {
    var body: some View {
        FlowScaffold {
            Text("Almost there")
                .resoniqCapsLabel()
        } content: {
            MessageBlock(
                headline: "Putting the three runs together.",
                message: "I compare them to see what repeats. This takes a moment."
            ) {
                EmptyView()
            }
            .padding(.top, ResoniqSpace.s6)
        } footer: {
            HStack(spacing: ResoniqSpace.s2) {
                Circle()
                    .fill(ResoniqColor.ivory)
                    .frame(width: Metrics.dot, height: Metrics.dot)
                    .resoniqWaitingPulse(low: Metrics.pulseLow)
                    .accessibilityHidden(true)
                Text("Reading your speaker")
                    .font(ResoniqFont.button)
                    .foregroundStyle(ResoniqColor.ivory)
            }
            .frame(maxWidth: .infinity, minHeight: ResoniqSize.buttonHeight)
            .accessibilityElement(children: .combine)
        }
    }

    private enum Metrics {
        static let dot: CGFloat = 8
        static let pulseLow = 0.35
    }
}

// MARK: - A run being repeated

/// The notice on the Listening screen when the session plays a run again: why, in a sentence.
struct RunNoticePanel: View {
    let note: RunNote

    var body: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
            Text(DiagnoseText.noticeTitle(note))
                .resoniqCapsLabel()
            Text(DiagnoseText.noticeText(note))
                .font(ResoniqFont.body)
                .foregroundStyle(ResoniqColor.ivory)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .resoniqPanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DiagnoseText.noticeTitle(note))
        .accessibilityValue(DiagnoseText.noticeText(note))
    }
}

#if DEBUG
#Preview("Microphone denied") {
    MicrophoneDeniedScreen(onOpenSettings: {}, onBack: {})
        .preferredColorScheme(.dark)
}

#Preview("Failed after two bad runs") {
    DiagnoseFailedScreen(failure: .unusable(.didNotArrive), onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Interrupted") {
    DiagnoseFailedScreen(failure: .interrupted, onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Route changed") {
    DiagnoseFailedScreen(failure: .routeChanged, onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Too noisy") {
    DiagnoseFailedScreen(failure: .tooNoisy, onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Speakers not connected") {
    DiagnoseFailedScreen(
        failure: .speakersNotConnected(AudioOutputRoute(kind: .builtInSpeaker, name: "iPhone Speaker")),
        onTryAgain: {}, onClose: {}, onExternal: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Speakers not connected, largest text") {
    DiagnoseFailedScreen(
        failure: .speakersNotConnected(AudioOutputRoute(kind: .builtInReceiver, name: "iPhone Receiver")),
        onTryAgain: {}, onClose: {}, onExternal: {}
    )
    .dynamicTypeSize(.accessibility3)
    .preferredColorScheme(.dark)
}

#Preview("Analysing") {
    AnalysingScreen()
        .preferredColorScheme(.dark)
}
#endif
