import ResoniqDesign
import SwiftUI

/// Paused (design/screens/V3Paused.dc.html): noise stopped the run. The portrait dims where it stopped, the room's
/// noise is shown against the "quiet enough" mark, and the app carries on by itself. The one button is passive: it
/// says what is being waited for. "Stop and start over" is the way out.
struct PausedScreen: View {
    let display: RunDisplay
    var onStop: () -> Void

    var body: some View {
        FlowScaffold {
            HStack {
                Text(display.title)
                    .resoniqCapsLabel()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: ResoniqSpace.s2)
                ResoniqStatusPill("Paused", style: .paused)
            }
        } content: {
            HStack(alignment: .top, spacing: Metrics.columnGap) {
                PortraitPanel(display: display)
                    .frame(width: Metrics.portraitPanelWidth)
                    .frame(maxHeight: .infinity)
                    .frame(minHeight: Metrics.portraitMinHeight)
                VStack(alignment: .leading, spacing: Metrics.columnGap) {
                    VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
                        Text("It got noisy, so I stopped.")
                            .font(Metrics.headlineFont)
                            .tracking(Metrics.headlineSize * ResoniqFont.Tracking.title)
                            .foregroundStyle(ResoniqColor.ivory)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        if let note = display.interference {
                            // What the Kit's sound classifier heard in the pause, and how it knows.
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
                        Text(resumeSentence)
                            .font(Metrics.sentenceFont)
                            .foregroundStyle(ResoniqColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .resoniqTitleRise()
                    Spacer(minLength: 0)
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
                .frame(maxHeight: .infinity, alignment: .top)
            }
        } footer: {
            VStack(spacing: ResoniqSpace.s1) {
                WaitingForQuietLine()
                Button("Stop and start over", action: onStop)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
        }
        // The pause is a change VoiceOver must hear: the run stopped, and why.
        .onAppear { AccessibilityNotification.Announcement(Self.pausedAnnouncement).post() }
        .onChange(of: display.interference) { _, note in
            guard let note else { return }
            AccessibilityNotification.Announcement(note.sentence).post()
        }
    }

    static let pausedAnnouncement = "It got noisy, so I stopped."

    private var resumeSentence: String {
        let frequency = display.resumeFrequency ?? "where I stopped"
        return "A measurement taken now would be wrong. I'll pick up at \(frequency) once the room is quiet again."
    }

    private enum Metrics {
        static let columnGap: CGFloat = 14
        static let portraitPanelWidth: CGFloat = 180
        static let portraitMinHeight: CGFloat = 300
        static let headlineSize: CGFloat = 27
        static let headlineFont = ResoniqFont.font(.sansSemibold, size: headlineSize, relativeTo: .title)
        static let sentenceFont = ResoniqFont.font(.sansRegular, size: 14, relativeTo: .callout)
        static let noiseFont = ResoniqFont.font(.sansMedium, size: 15, relativeTo: .body)
    }
}

/// "Waiting for quiet, then I continue": the passive line of both Paused screens. Not a control, so it is not a
/// button: it has the outlined pill's shape and says what the app is waiting for.
struct WaitingForQuietLine: View {
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 8

    var body: some View {
        HStack(spacing: Metrics.gap) {
            Circle()
                .fill(ResoniqColor.ivory)
                .frame(width: dot, height: dot)
                .resoniqWaitingPulse(low: Metrics.dotLow)
                .accessibilityHidden(true)
            Text("Waiting for quiet, then I continue")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(ResoniqFont.button)
        .foregroundStyle(ResoniqColor.ivory)
        .padding(.vertical, ResoniqSpace.s2)
        .frame(maxWidth: .infinity, minHeight: ResoniqSize.buttonHeight)
        .background(Capsule().strokeBorder(ResoniqColor.line, lineWidth: ResoniqSize.strokeHairline))
        .accessibilityElement(children: .combine)
    }

    private enum Metrics {
        static let gap: CGFloat = 10
        static let dotLow = 0.35
    }
}

#if DEBUG
#Preview("Paused") {
    PausedScreen(display: .previewPaused, onStop: {})
        .preferredColorScheme(.dark)
}

#Preview("Paused, large type") {
    PausedScreen(display: .previewPaused, onStop: {})
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
#endif
