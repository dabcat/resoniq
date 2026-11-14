import ResoniqDesign
import ResoniqDiagnostics
import SwiftUI

/// A kept seat measurement, as the comparison picks and shows it.
struct KeptSeat: Identifiable {
    let report: SeatReport
    let date: Date
    var id: Date { date }

    /// "Tuesday", "Yesterday", "3 March".
    var day: String { SeatDisplay.day(of: date) }
}

/// The words of the comparison of two measurements. Static labels only; every sentence about the result is the Kit's
/// (`ComparisonReport.verdict`, its rows, `SeatComparison.occasionsNote`).
enum CompareWords {
    static let link = "Compare with an earlier one"
    static let pickTitle = "Which one should I put next to your latest?"
    static let back = "Back"
    static let earlier = "Earlier"
    static let latest = "Latest"
    static let comparisonTitle = "Two measurements"
    static let intro = "Loudness at your seat, an earlier measurement and the latest one, at the same spots."

    /// "Earlier · Tuesday", "Latest · today".
    static func legend(_ name: String, day: String) -> String { "\(name) · \(day)" }

    static let pickSentence = "Pick an earlier measurement and I'll lay it over your latest one."
}

// MARK: - The list

/// The earlier kept measurements of the selected system, newest first: a row each with its day, how many spots it
/// has, and the Kit's verdict for it.
struct EarlierMeasurementsScreen: View {
    let earlier: [KeptSeat]
    let onPick: (KeptSeat) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: ResoniqSpace.s3) {
            HStack {
                Button(action: onClose) { ResoniqIconView(.back) }
                    .buttonStyle(ResoniqIconButtonStyle())
                    .accessibilityLabel(CompareWords.back)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ResoniqSpace.screenInset)

            ScrollView {
                VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
                    Text(CompareWords.pickTitle)
                        .resoniqTitle(.compact)
                        .accessibilityAddTraits(.isHeader)
                    Text(CompareWords.pickSentence)
                        .font(ResoniqFont.body)
                        .foregroundStyle(ResoniqColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(Array(earlier.enumerated()), id: \.element.id) { index, kept in
                            if index > 0 {
                                Rectangle().fill(ResoniqColor.line).frame(height: ResoniqSize.strokeHairline)
                            }
                            row(kept)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ResoniqSpace.screenInset)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.top, ResoniqSpace.s3)
        .padding(.bottom, ResoniqSpace.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ResoniqColor.ink)
        .accessibilityAction(.escape, onClose)
    }

    private func row(_ kept: KeptSeat) -> some View {
        let spots = SeatDisplay.spotsLine(of: kept.report)
        return Button { onPick(kept) } label: {
            HStack(alignment: .top, spacing: ResoniqSpace.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kept.day)
                        .font(ResoniqFont.bodySemibold)
                        .foregroundStyle(ResoniqColor.ivory)
                    Text(spots)
                        .font(ResoniqFont.caption)
                        .foregroundStyle(ResoniqColor.muted)
                    Text(kept.report.verdict)
                        .font(ResoniqFont.body)
                        .foregroundStyle(ResoniqColor.ivory)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ResoniqIconView(.arrowRight)
                    .foregroundStyle(ResoniqColor.guide)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, ResoniqSpace.s3)
            .frame(maxWidth: .infinity, minHeight: ResoniqSize.touchMin, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kept.day), \(spots). \(kept.report.verdict)")
        .accessibilityHint("Compares it with your latest")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - The comparison

/// Two kept measurements over each other: the earlier one dashed, the latest solid, the Kit's verdict and rows
/// (`SeatComparison.compare`), and the note that these are two measurements, not the before and after of a move.
struct ComparisonScreen: View {
    let comparison: ComparisonReport
    let earlier: KeptSeat
    let latest: KeptSeat
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: ResoniqSpace.s3) {
            HStack {
                Button(action: onClose) { ResoniqIconView(.back) }
                    .buttonStyle(ResoniqIconButtonStyle())
                    .accessibilityLabel(CompareWords.back)
                Text(CompareWords.comparisonTitle)
                    .resoniqCapsLabel()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, ResoniqSpace.screenInset)

            ScrollView {
                VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
                    Text(comparison.verdict)
                        .resoniqTitle(.medium)
                        .accessibilityAddTraits(.isHeader)
                    if comparison.isConclusive {
                        curve
                        rows
                    }
                    Text(SeatComparison.occasionsNote)
                        .font(ResoniqFont.caption)
                        .foregroundStyle(ResoniqColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    // One measured from another device and one by the phone: both valid, but taken differently.
                    SourceCaptions(lines: SourceWords.lines(
                        (CompareWords.earlier, earlier.report.source), (CompareWords.latest, latest.report.source)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ResoniqSpace.screenInset)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.top, ResoniqSpace.s3)
        .padding(.bottom, ResoniqSpace.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ResoniqColor.ink)
        .accessibilityAction(.escape, onClose)
    }

    private var curve: some View {
        ResponseCurve(
            levels: RoomDisplay.levels(of: latest.report), evenBand: Double(latest.report.evenBandDecibels),
            range: RoomDisplay.Scale.curveDecibelsEachWay, before: RoomDisplay.levels(of: earlier.report),
            legend: [
                ResoniqLegendEntry(CompareWords.legend(CompareWords.earlier, day: earlier.day), color: ResoniqColor.muted, isDashed: true),
                ResoniqLegendEntry(CompareWords.legend(CompareWords.latest, day: latest.day), color: ResoniqColor.teal),
            ],
            accessibilityLabel: summary
        )
        .resoniqPanel()
    }

    /// The chart for VoiceOver: what it shows, then each of the Kit's rows in words.
    private var summary: String {
        let rows = RoomDisplay.lines(of: comparison).map { line -> String in
            switch line.content {
            case .values(let before, let after, _): "\(line.label): \(before) earlier, \(after) latest."
            case .plain(let text): "\(line.label): \(text)."
            }
        }
        return ([CompareWords.intro] + rows).joined(separator: " ")
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(RoomDisplay.lines(of: comparison)) { line in
                switch line.content {
                case .values(let before, let after, let improved):
                    BeforeAfterRow(label: line.label, before: before, after: after, improved: improved, showsDivider: line.id > 0)
                case .plain(let detail):
                    BeforeAfterRow(label: line.label, unchanged: detail, showsDivider: line.id > 0)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Pick an earlier one") {
    EarlierMeasurementsScreen(
        earlier: [
            KeptSeat(report: MeasureFixtures.mockup, date: .now.addingTimeInterval(-3 * 86_400)),
            KeptSeat(report: MeasureFixtures.even, date: .now.addingTimeInterval(-12 * 86_400)),
        ],
        onPick: { _ in }, onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Two measurements") {
    let earlier = KeptSeat(report: MeasureFixtures.mockup, date: .now.addingTimeInterval(-3 * 86_400))
    let latest = KeptSeat(report: MeasureFixtures.even, date: .now)
    ComparisonScreen(
        comparison: SeatComparison.compare(before: earlier.report, after: latest.report, targeting: earlier.report.extremes),
        earlier: earlier, latest: latest, onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Two measurements, large type") {
    let earlier = KeptSeat(report: MeasureFixtures.mockup, date: .now.addingTimeInterval(-3 * 86_400))
    let latest = KeptSeat(report: MeasureFixtures.even, date: .now)
    ComparisonScreen(
        comparison: SeatComparison.compare(before: earlier.report, after: latest.report, targeting: earlier.report.extremes),
        earlier: earlier, latest: latest, onClose: {}
    )
    .dynamicTypeSize(.accessibility2)
    .preferredColorScheme(.dark)
}
#endif
