import ResoniqDesign
import ResoniqDiagnostics
import SwiftUI

/// The numbers behind the seat result (design/screens/V3MDetail.dc.html): Response, Distortion and Decay. Response
/// is the left and right traces on a decibel grid, then the rows of the values table; Distortion and Decay are their
/// rows alone. Then the note about the uncalibrated microphone.
///
/// The screen decides nothing: the rows, their words and tags, the verdict and the footnote are the report's, and
/// `SeatDisplay` maps them onto the components. A single speaker shows one trace and no left and right row.
struct NumbersScreen: View {
    let report: SeatReport
    /// When the seat was measured; read aloud with the title so the numbers have a day.
    let date: Date
    let onClose: () -> Void

    @State private var segment: NumbersSegment

    init(report: SeatReport, date: Date, onClose: @escaping () -> Void, segment: NumbersSegment = .response) {
        self.report = report
        self.date = date
        self.onClose = onClose
        _segment = State(initialValue: segment)
    }

    var body: some View {
        VStack(spacing: ResoniqSpace.s3) {
            topBar
                .padding(.horizontal, ResoniqSpace.screenInset)
            ResoniqSegmentedControl(
                NumbersSegment.allCases.map { ResoniqSegment($0, title: $0.title) },
                selection: $segment,
                label: SeatWords.segmentsLabel
            )
            .padding(.horizontal, ResoniqSpace.screenInset)

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.gap) {
                    switch segment {
                    case .response: response
                    case .distortion: distortion
                    case .decay: decay
                    }
                    Text(report.footnote)
                        .font(ResoniqFont.caption)
                        .foregroundStyle(ResoniqColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: ResoniqSpace.s3) {
            Button(action: onClose) {
                ResoniqIconView(.back)
            }
            .buttonStyle(ResoniqIconButtonStyle())
            .accessibilityLabel(SeatWords.numbersBack)
            Text(SeatWords.numbersTitle)
                .font(ResoniqFont.headline)
                .foregroundStyle(ResoniqColor.ivory)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(SeatWords.numbersTitle), \(SeatDisplay.day(of: date))")
                .accessibilityAddTraits(.isHeader)
            Text(SeatWords.numbersAdvanced)
                .resoniqCapsLabel()
        }
    }

    // MARK: Response

    @ViewBuilder
    private var response: some View {
        if let chart = channelsChart {
            chart.resoniqPanel()
        }
        let rows = report.tableRows(for: .response)
        if rows.isEmpty {
            // Nothing outside the even band and no left and right to compare: the Kit's own sentence says so.
            if let rest = report.findings.first(where: { $0.kind == .rest }) {
                Text(rest.detail)
                    .font(ResoniqFont.body)
                    .foregroundStyle(ResoniqColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ResoniqValuesTable(rows: rows)
        }
    }

    /// Left and right on the decibel grid; one trace for a single speaker; nothing before a curve exists.
    private var channelsChart: ChannelComparisonChart? {
        guard let left = report.leftLevels else { return nil }
        if let right = report.rightLevels {
            return ChannelComparisonChart(
                left: left, right: right,
                range: SeatScale.decibelsEachWay, gridStep: SeatScale.gridStepDecibels,
                evenBand: Double(report.evenBandDecibels),
                caption: report.smoothingCaption, drawsOnAppear: true,
                accessibilityLabel: report.channelsAccessibilityLabel
            )
        }
        return ChannelComparisonChart(
            single: left, name: SeatWords.singleSpeaker,
            range: SeatScale.decibelsEachWay, gridStep: SeatScale.gridStepDecibels,
            evenBand: Double(report.evenBandDecibels),
            caption: report.smoothingCaption, drawsOnAppear: true,
            accessibilityLabel: report.channelsAccessibilityLabel
        )
    }

    // MARK: Distortion and decay

    @ViewBuilder
    private var distortion: some View {
        rowsOrSentence(report.tableRows(for: .distortion), none: SeatWords.noDistortion)
    }

    /// The decay row is always an estimate (the Kit tags it so and writes it with "≈").
    @ViewBuilder
    private var decay: some View {
        rowsOrSentence(report.tableRows(for: .decay), none: SeatWords.noDecay)
    }

    @ViewBuilder
    private func rowsOrSentence(_ rows: [ResoniqValuesTable.Row], none: String) -> some View {
        if rows.isEmpty {
            Text(none)
                .font(ResoniqFont.body)
                .foregroundStyle(ResoniqColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ResoniqValuesTable(rows: rows)
        }
    }

    private enum Metrics {
        /// V3MDetail puts 14 pt between its parts.
        static let gap: CGFloat = ResoniqSpace.panelPadding
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Response") {
    NumbersScreen(report: MeasureFixtures.mockup, date: .now, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Distortion") {
    NumbersScreen(report: MeasureFixtures.mockup, date: .now, onClose: {}, segment: .distortion)
        .preferredColorScheme(.dark)
}

#Preview("Decay") {
    NumbersScreen(report: MeasureFixtures.mockup, date: .now, onClose: {}, segment: .decay)
        .preferredColorScheme(.dark)
}

#Preview("Single speaker") {
    NumbersScreen(report: MeasureFixtures.single, date: .now, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Inconclusive") {
    NumbersScreen(report: MeasureFixtures.inconclusive, date: .now, onClose: {}, segment: .distortion)
        .preferredColorScheme(.dark)
}

#Preview("Largest text") {
    NumbersScreen(report: MeasureFixtures.mockup, date: .now, onClose: {})
        .dynamicTypeSize(.accessibility2)
        .preferredColorScheme(.dark)
}
#endif
