import ResoniqDesign
import SwiftUI

/// Listening to a test sound another device plays (no mockup; built from the Listening screen, V3Listening, and
/// design/DESIGN_SYSTEM.md): the same instrument, so it reads as the same test. The header names the speaker and, while
/// a run is heard, "run 2 of 3"; the portrait fills upward from the frequency the session hears; "Hearing now" names
/// it; Room, Level and Phone say whether the room, the level and the phone are fine; and the instruction for this
/// moment is the footer, in the place "Hold still." has.
///
/// What is heard that is not the test sound, and why the file must be played again, are calm notices
/// (`ExternalNoticePanel`), not errors. There is no Paused screen in this mode: the app cannot pause someone else's
/// player, so a run spoiled by noise leads to "Play the file once more" and its reason, in place.
struct ExternalListeningScreen: View {
    let display: ExternalRunDisplay
    var onStop: () -> Void

    var body: some View {
        FlowScaffold {
            HStack {
                Text(display.run.title)
                    .resoniqCapsLabel()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: ResoniqSpace.s2)
                Button(action: onStop) {
                    RoundedRectangle(cornerRadius: Metrics.stopRadius, style: .continuous)
                        .frame(width: Metrics.stopSide, height: Metrics.stopSide)
                }
                .buttonStyle(ResoniqIconButtonStyle())
                .accessibilityLabel(TestSoundText.stopListening)
            }
        } content: {
            HStack(alignment: .top, spacing: Metrics.columnGap) {
                PortraitPanel(display: display.run)
                    .frame(width: Metrics.portraitPanelWidth)
                    .frame(maxHeight: .infinity)
                    .frame(minHeight: Metrics.portraitMinHeight)
                VStack(spacing: Metrics.columnGap) {
                    ResoniqReadout(
                        label: TestSoundText.hearingNow,
                        value: display.run.frequency.value,
                        unit: display.run.frequency.unit,
                        detail: display.run.frequency.detail
                    )
                    .resoniqPanel()
                    ReadingsPanel(readings: [display.run.room, display.run.level, display.run.phone])
                    if let notice = display.notice {
                        ExternalNoticePanel(notice: notice)
                    } else if let detail = display.detail {
                        Text(detail)
                            .font(Metrics.guidanceFont)
                            .foregroundStyle(ResoniqColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        } footer: {
            Text(display.headline)
                .font(ResoniqFont.title3)
                .tracking(Metrics.headlineSize * Metrics.headlineTracking)
                .foregroundStyle(ResoniqColor.ivory)
                .fixedSize(horizontal: false, vertical: true)
                .resoniqWaitingPulse()
                .frame(maxWidth: .infinity, minHeight: Metrics.footerHeight, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
        // Said when the moment changes ("Press play now.", the run being heard, the file to play again and why), not on
        // every reading: the same rule as Listening's.
        .onChange(of: display.announcement) { _, announcement in
            if let announcement { AccessibilityNotification.Announcement(announcement).post() }
        }
        .onChange(of: display.notice) { _, notice in
            guard let notice, !(display.announcement ?? "").contains(notice.text) else { return }
            AccessibilityNotification.Announcement(notice.text).post()
        }
        .onChange(of: display.run.level.hint) { _, hint in
            if let hint { AccessibilityNotification.Announcement("\(display.run.level.value). \(hint)").post() }
        }
        .onChange(of: display.run.phone.value) { _, value in
            if value == DiagnoseText.phone(isSteady: false) { AccessibilityNotification.Announcement(display.run.phone.spoken).post() }
        }
    }

    private enum Metrics {
        static let stopSide: CGFloat = 14
        static let stopRadius: CGFloat = 2
        static let columnGap: CGFloat = 14
        /// As Listening's: 8 pt, the 40 pt ruler, the 120 pt portrait and 12 pt.
        static let portraitPanelWidth: CGFloat = 180
        static let portraitMinHeight: CGFloat = 300
        static let guidanceFont = ResoniqFont.font(.sansRegular, size: 14, relativeTo: .callout)
        static let headlineSize: CGFloat = 26
        static let headlineTracking: CGFloat = -0.02
        static let footerHeight: CGFloat = 52
    }
}

/// A calm notice in the place of the line of guidance: a caps label over one sentence from the Kit.
struct ExternalNoticePanel: View {
    let notice: ExternalNotice

    var body: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
            Text(notice.title)
                .resoniqCapsLabel()
            Text(notice.text)
                .font(ResoniqFont.body)
                .foregroundStyle(ResoniqColor.ivory)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .resoniqPanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice.title)
        .accessibilityValue(notice.text)
    }
}

#if DEBUG
#Preview("Waiting for the play") {
    ExternalListeningScreen(display: .previewWaiting, onStop: {})
        .preferredColorScheme(.dark)
}

#Preview("Hearing a run") {
    ExternalListeningScreen(display: .previewHearing, onStop: {})
        .preferredColorScheme(.dark)
}

#Preview("Play it again") {
    ExternalListeningScreen(display: .previewAgain, onStop: {})
        .preferredColorScheme(.dark)
}

#Preview("Not the test sound") {
    ExternalListeningScreen(display: .previewNotTheTestSound, onStop: {})
        .preferredColorScheme(.dark)
}

#Preview("Play it again, large type") {
    ExternalListeningScreen(display: .previewAgain, onStop: {})
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
#endif
