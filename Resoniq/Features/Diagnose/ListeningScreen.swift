import ResoniqDesign
import SwiftUI

/// Listening (design/screens/V3Listening.dc.html): the portrait fills upward as the tone rises, "Playing now" names
/// the pitch and its driver, three readings say whether the room, the level and the phone are fine, and the run
/// can be stopped.
///
/// A run being played again shows its reason in place of the line of guidance (`RunNoticePanel`, no mockup).
struct ListeningScreen: View {
    let display: RunDisplay
    var onStop: () -> Void

    var body: some View {
        FlowScaffold {
            HStack {
                Text(display.title)
                    .resoniqCapsLabel()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: ResoniqSpace.s2)
                Button(action: onStop) {
                    RoundedRectangle(cornerRadius: Metrics.stopRadius, style: .continuous)
                        .frame(width: Metrics.stopSide, height: Metrics.stopSide)
                }
                .buttonStyle(ResoniqIconButtonStyle())
                .accessibilityLabel("Stop the test")
            }
        } content: {
            HStack(alignment: .top, spacing: Metrics.columnGap) {
                PortraitPanel(display: display)
                    .frame(width: Metrics.portraitPanelWidth)
                    .frame(maxHeight: .infinity)
                    .frame(minHeight: Metrics.portraitMinHeight)
                VStack(spacing: Metrics.columnGap) {
                    ResoniqReadout(
                        label: "Playing now",
                        value: display.frequency.value,
                        unit: display.frequency.unit,
                        detail: display.frequency.detail
                    )
                    .resoniqPanel()
                    ReadingsPanel(readings: [display.room, display.level, display.phone])
                    if let note = display.note {
                        RunNoticePanel(note: note)
                    } else {
                        Text("The shape fills in from the deepest bass up as the tone rises.")
                            .font(Metrics.guidanceFont)
                            .foregroundStyle(ResoniqColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        } footer: {
            Text("Hold still.")
                .font(ResoniqFont.title3)
                .tracking(Metrics.holdStillSize * Metrics.holdStillTracking)
                .foregroundStyle(ResoniqColor.ivory)
                .resoniqWaitingPulse()
                .frame(maxWidth: .infinity, minHeight: Metrics.footerHeight, alignment: .leading)
        }
        // Said once when it changes, not on every reading: a level to fix, and the phone starting to move.
        .onChange(of: display.level.hint) { _, hint in
            if let hint { AccessibilityNotification.Announcement("\(display.level.value). \(hint)").post() }
        }
        .onChange(of: display.phone.value) { _, value in
            if value == DiagnoseText.phone(isSteady: false) { AccessibilityNotification.Announcement(display.phone.spoken).post() }
        }
    }

    private enum Metrics {
        static let stopSide: CGFloat = 14
        static let stopRadius: CGFloat = 2
        static let columnGap: CGFloat = 14
        /// The portrait panel: 8 pt, the 40 pt ruler, the 120 pt portrait and 12 pt, as in the mockup's 166 x 430 SVG.
        static let portraitPanelWidth: CGFloat = 180
        static let portraitMinHeight: CGFloat = 300
        static let guidanceFont = ResoniqFont.font(.sansRegular, size: 14, relativeTo: .callout)
        static let holdStillSize: CGFloat = 26
        static let holdStillTracking: CGFloat = -0.02
        static let footerHeight: CGFloat = 52
    }
}

/// The portrait with its ruler, in the panel of V3Listening and V3Paused.
struct PortraitPanel: View {
    let display: RunDisplay

    var body: some View {
        HStack(spacing: 0) {
            FrequencyRuler(.beside)
            SpeakerPortrait(
                widths: display.widths.isEmpty ? SpeakerPortrait.unknownSpeakerWidths : display.widths,
                state: display.portrait,
                accessibilityLabel: display.portraitLabel
            )
            .frame(width: Metrics.portraitWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .resoniqPanel(insets: EdgeInsets(
            top: Metrics.insetVertical,
            leading: Metrics.insetLeading,
            bottom: Metrics.insetVertical,
            trailing: Metrics.insetTrailing
        ))
    }

    private enum Metrics {
        static let portraitWidth: CGFloat = 120
        static let insetVertical: CGFloat = 16
        static let insetLeading: CGFloat = 8
        static let insetTrailing: CGFloat = 12
    }
}

/// Room, Level and Phone: a caps label over a sentence, three rows with hairlines between. Each row is read as one
/// sentence ("Room: quiet, about 34 decibels."). The words carry the state, not the colour.
private struct ReadingsPanel: View {
    let readings: [RunDisplay.Reading]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(readings.enumerated()), id: \.offset) { index, reading in
                if index > 0 {
                    Rectangle()
                        .fill(ResoniqColor.line)
                        .frame(height: ResoniqSize.strokeHairline)
                }
                VStack(alignment: .leading, spacing: Metrics.gap) {
                    Text(reading.title)
                        .resoniqCapsLabel()
                    Text(reading.value)
                        .font(Metrics.valueFont)
                        .foregroundStyle(ResoniqColor.ivory)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hint = reading.hint {
                        Text(hint)
                            .font(ResoniqFont.caption)
                            .foregroundStyle(ResoniqColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, Metrics.rowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(reading.spoken)
            }
        }
        .resoniqPanel(insets: EdgeInsets(
            top: Metrics.panelVertical,
            leading: ResoniqSpace.panelPadding,
            bottom: Metrics.panelVertical,
            trailing: ResoniqSpace.panelPadding
        ))
    }

    private enum Metrics {
        static let gap: CGFloat = 2
        static let rowPadding: CGFloat = 10
        static let panelVertical: CGFloat = 4
        static let valueFont = ResoniqFont.font(.sansMedium, size: 15, relativeTo: .body)
    }
}

#if DEBUG
#Preview("Listening") {
    ListeningScreen(display: .previewListening, onStop: {})
        .preferredColorScheme(.dark)
}

#Preview("Listening, waiting for the room") {
    ListeningScreen(display: .previewFloor, onStop: {})
        .preferredColorScheme(.dark)
}

#Preview("Repeating a run") {
    ListeningScreen(display: .previewRepeating, onStop: {})
        .preferredColorScheme(.dark)
}

#Preview("Listening, large type") {
    ListeningScreen(display: .previewListening, onStop: {})
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
#endif
