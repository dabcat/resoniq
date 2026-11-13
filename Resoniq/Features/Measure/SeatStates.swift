import ResoniqAudio
import ResoniqDesign
import SwiftUI

// States of the measuring flow that have no mockup. They follow design/DESIGN_SYSTEM.md: the frame of the other flow
// screens (`FlowScaffold`: a header row, the content, a footer), the voice (first person, calm, specific) and its
// motion (title rise, waiting dot). The noisy interruption reuses the pattern of Diagnose's Paused screen. All are
// listed in the pull request as "no mockup".

/// A headline and a sentence under it, with an optional accessory above (an evidence tag). The body of a state with
/// nothing to draw. Diagnose has the same block privately; this one is the Measure copy of it.
struct MeasureMessage<Accessory: View>: View {
    let headline: String
    let message: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            accessory
            Text(headline)
                .font(ResoniqFont.display)
                .tracking(messageDisplaySize * ResoniqFont.Tracking.title)
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

/// The headline size of `ResoniqFont.display`, for its tracking.
private let messageDisplaySize: CGFloat = 36

// MARK: - Paused

/// Paused: noise stopped a sweep. The room's noise is shown against the "quiet enough" mark and the app carries on by
/// itself. The one button is passive: it says what is being waited for. "Stop and start over" is the way out. The
/// Measure variant of Diagnose's Paused screen: the same pieces, with the spot in place of the portrait.
struct SeatPausedScreen: View {
    let display: SeatRunDisplay
    var onStop: () -> Void

    var body: some View {
        FlowScaffold {
            HStack {
                Text(display.pausedTitle)
                    .resoniqCapsLabel()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: ResoniqSpace.s2)
                ResoniqStatusPill("Paused", style: .paused)
            }
        } content: {
            VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
                VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
                    Text(MeasureText.pausedHeadline)
                        .font(Metrics.headlineFont)
                        .tracking(Metrics.headlineSize * ResoniqFont.Tracking.title)
                        .foregroundStyle(ResoniqColor.ivory)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let note = display.interference {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.sentence)
                                .font(Metrics.noiseFont)
                                .foregroundStyle(ResoniqColor.ivory)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(note.tagLine)
                                .font(ResoniqFont.caption)
                                .foregroundStyle(ResoniqColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(note.sentence) \(note.tagLine).")
                    }
                    Text(MeasureText.pausedSentence(resumeFrequency: display.resumeFrequency))
                        .font(Metrics.sentenceFont)
                        .foregroundStyle(ResoniqColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .resoniqTitleRise()

                SpotsDiagram(
                    .running, spots: display.spots, phoneSpot: display.phoneSpot, accessibilityLabel: display.diagramLabel
                )
                .resoniqPanel(insets: EdgeInsets())

                ResoniqReadout(
                    label: "Room noise",
                    value: display.roomNoise.value,
                    size: .medium,
                    isOutOfRange: !display.roomNoise.isQuiet,
                    level: ResoniqLevelBar(
                        level: display.roomNoise.level,
                        mark: display.roomNoise.mark,
                        caption: "Quiet enough left of the mark"
                    )
                )
                .resoniqPanel()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            VStack(spacing: ResoniqSpace.s1) {
                WaitingForQuietLine()
                Button("Stop and start over", action: onStop)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
        }
        .onAppear { AccessibilityNotification.Announcement(MeasureText.pausedHeadline).post() }
        .onChange(of: display.interference) { _, note in
            guard let note else { return }
            AccessibilityNotification.Announcement(note.sentence).post()
        }
    }

    private enum Metrics {
        static let headlineSize: CGFloat = 27
        static let headlineFont = ResoniqFont.font(.sansSemibold, size: headlineSize, relativeTo: .title)
        static let sentenceFont = ResoniqFont.font(.sansRegular, size: 14, relativeTo: .callout)
        static let noiseFont = ResoniqFont.font(.sansMedium, size: 15, relativeTo: .body)
    }
}

// MARK: - Ended without a result

/// A measurement that ended without a report: a spot failed twice, the room stayed too noisy, the speakers are not
/// connected, or the audio was interrupted, switched route or could not start. Says why in a sentence and offers
/// another try. A spot that failed twice and a room that stayed too noisy are "Inconclusive", as the design system
/// names a measurement that could not decide.
struct SeatFailedScreen: View {
    var failure: SeatFlow.Failure
    var onTryAgain: () -> Void
    var onClose: () -> Void

    var body: some View {
        FlowScaffold {
            Text("Resoniq")
                .font(ResoniqFont.headline)
                .foregroundStyle(ResoniqColor.ivory)
        } content: {
            MeasureMessage(headline: MeasureText.failureHeadline(failure), message: MeasureText.failureBody(failure)) {
                if let basis = MeasureText.inconclusiveBasis(failure) {
                    ResoniqEvidenceTag(.inconclusive, basis: basis)
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
        .accessibilityAction(.escape, onClose)
    }
}

// MARK: - Analysing

/// The moment between the last spot and the result: the spots are being put together.
struct SeatAnalysingScreen: View {
    var body: some View {
        FlowScaffold {
            Text(MeasureText.analysingKicker)
                .resoniqCapsLabel()
        } content: {
            MeasureMessage(headline: MeasureText.analysingHeadline, message: MeasureText.analysingBody) {
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
                Text(MeasureText.analysingWaiting)
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

#if DEBUG
#Preview("Paused") {
    SeatPausedScreen(display: .previewPaused, onStop: {})
        .preferredColorScheme(.dark)
}

#Preview("Paused, large type") {
    SeatPausedScreen(display: .previewPaused, onStop: {})
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}

#Preview("Failed after two bad recordings") {
    SeatFailedScreen(failure: .unusable(.didNotArrive), onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Too noisy") {
    SeatFailedScreen(failure: .tooNoisy, onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Speakers not connected") {
    SeatFailedScreen(
        failure: .speakersNotConnected(AudioOutputRoute(kind: .builtInSpeaker, name: "iPhone Speaker")),
        onTryAgain: {}, onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Interrupted") {
    SeatFailedScreen(failure: .interrupted, onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Route changed") {
    SeatFailedScreen(failure: .routeChanged, onTryAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Analysing") {
    SeatAnalysingScreen()
        .preferredColorScheme(.dark)
}
#endif
