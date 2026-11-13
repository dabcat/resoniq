import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import SwiftUI

/// Three spots (design/screens/V3MRunning.dc.html): the Seat / Left / Right pills, the instruction for this moment as
/// the headline, the top view with the phone sliding to the spot, the average building as the spots come in, the
/// Room and Level readings, and the line that says the app starts by itself, with "Skip to result".
///
/// A rigid haptic marks each spot captured. A spot being measured again shows its reason in place of the two
/// readings (`SpotNoticePanel`, no mockup).
struct ThreeSpotsScreen: View {
    let display: SeatRunDisplay
    var onStop: () -> Void
    var onSkip: () -> Void

    var body: some View {
        FlowScaffold {
            HStack(spacing: ResoniqSpace.s2) {
                HStack(spacing: Metrics.pillGap) {
                    ForEach(Array(display.pills.enumerated()), id: \.offset) { _, pill in
                        ResoniqStatusPill(pill.title, style: Self.style(of: pill.state))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(pill.spoken)
                    }
                }
                Spacer(minLength: ResoniqSpace.s2)
                Button(action: onStop) {
                    RoundedRectangle(cornerRadius: Metrics.stopRadius, style: .continuous)
                        .frame(width: Metrics.stopSide, height: Metrics.stopSide)
                }
                .buttonStyle(ResoniqIconButtonStyle())
                .accessibilityLabel("Stop measuring")
            }
        } content: {
            VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
                Text(display.instruction)
                    .resoniqTitle(.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                SpotsDiagram(
                    .running, spots: display.spots, phoneSpot: display.phoneSpot, accessibilityLabel: display.diagramLabel
                )
                .resoniqPanel(insets: EdgeInsets())

                AverageBuildingCurve(
                    traces: display.traces,
                    average: display.average,
                    evenBand: Double(SeatThresholds.standard.evenBandDecibels),
                    range: SeatScale.decibelsEachWay,
                    isBuilding: !display.average.isEmpty,
                    title: "Building the average",
                    detail: display.progressLabel,
                    accessibilityLabel: display.curveLabel
                )
                .resoniqPanel(insets: EdgeInsets(
                    top: Metrics.curveTop,
                    leading: ResoniqSpace.panelPadding,
                    bottom: Metrics.curveBottom,
                    trailing: ResoniqSpace.panelPadding
                ))

                if let note = display.note {
                    SpotNoticePanel(note: note)
                } else {
                    HStack(alignment: .top, spacing: Metrics.readingGap) {
                        ReadingTile(reading: display.room)
                        ReadingTile(reading: display.level)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            StartsByItselfLine(text: display.footerLine, onSkip: onSkip)
        }
        // The instruction changes with the moment; VoiceOver says it without the user hunting for it.
        .onChange(of: display.instruction) { _, instruction in
            guard !instruction.isEmpty else { return }
            AccessibilityNotification.Announcement(instruction).post()
        }
        .onChange(of: display.level.hint) { _, hint in
            if let hint { AccessibilityNotification.Announcement("\(display.level.value). \(hint)").post() }
        }
        // The haptic marks a spot captured; the headline changes to "Got the seat spot." and is announced above.
        .sensoryFeedback(.impact(flexibility: .rigid), trigger: display.capturedCount) { old, new in new > old }
    }

    private static func style(of state: SpotsDiagram.SpotState) -> ResoniqStatusPill.Style {
        switch state {
        case .done: .done
        case .active: .active
        case .upcoming: .upcoming
        }
    }

    private enum Metrics {
        static let pillGap: CGFloat = 8
        static let stopSide: CGFloat = 14
        static let stopRadius: CGFloat = 2
        /// V3MRunning: the curve panel is 14 pt around, 12 pt at the bottom.
        static let curveTop: CGFloat = 14
        static let curveBottom: CGFloat = 12
        static let readingGap: CGFloat = 10
    }
}

// MARK: - Pieces

/// Room or Level: a caps label over a sentence, in the small panel of V3MRunning.
private struct ReadingTile: View {
    let reading: RunDisplay.Reading

    var body: some View {
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
        .padding(.vertical, Metrics.vertical)
        .padding(.horizontal, ResoniqSpace.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ResoniqColor.panel, in: RoundedRectangle(cornerRadius: ResoniqRadius.control, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.spoken)
    }

    private enum Metrics {
        static let gap: CGFloat = 2
        static let vertical: CGFloat = 10
        static let valueFont = ResoniqFont.font(.sansMedium, size: 15, relativeTo: .body)
    }
}

/// "I'll start by myself once the phone is still. Skip to result": a waiting dot, the sentence, and the link inside it,
/// under a hairline (V3MRunning).
private struct StartsByItselfLine: View {
    let text: String
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(ResoniqColor.line).frame(height: ResoniqSize.strokeHairline)
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gap) {
                Circle()
                    .fill(ResoniqColor.lime)
                    .frame(width: Metrics.dot, height: Metrics.dot)
                    .resoniqWaitingPulse()
                    .accessibilityHidden(true)
                Text(text)
                    .font(Metrics.font)
                    .foregroundStyle(ResoniqColor.ivory)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, Metrics.textTop)
            // Its own row, a real button with the full touch height, under the sentence it belongs to.
            Button("Skip to result", action: onSkip)
                .buttonStyle(ResoniqTextLinkStyle())
                .padding(.leading, Metrics.dot + Metrics.gap)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private enum Metrics {
        static let gap: CGFloat = 12
        static let dot: CGFloat = 8
        static let textTop: CGFloat = 8
        static let font = ResoniqFont.font(.sansRegular, size: 16, relativeTo: .body)
    }
}

/// Why a spot is being measured again, in place of the two readings.
struct SpotNoticePanel: View {
    let note: RunNote

    var body: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
            Text(MeasureText.noticeTitle(note))
                .resoniqCapsLabel()
            Text(MeasureText.noticeText(note))
                .font(ResoniqFont.body)
                .foregroundStyle(ResoniqColor.ivory)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .resoniqPanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MeasureText.noticeTitle(note))
        .accessibilityValue(MeasureText.noticeText(note))
    }
}

#if DEBUG
#Preview("Left spot next") {
    ThreeSpotsScreen(display: .previewMoving, onStop: {}, onSkip: {})
        .preferredColorScheme(.dark)
}

#Preview("Playing") {
    ThreeSpotsScreen(display: .previewPlaying, onStop: {}, onSkip: {})
        .preferredColorScheme(.dark)
}

#Preview("A spot again") {
    ThreeSpotsScreen(display: .previewRepeating, onStop: {}, onSkip: {})
        .preferredColorScheme(.dark)
}

#Preview("Three spots, large type") {
    ThreeSpotsScreen(display: .previewMoving, onStop: {}, onSkip: {})
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
#endif
