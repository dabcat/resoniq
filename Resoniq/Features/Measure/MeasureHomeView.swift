import ResoniqDesign
import ResoniqDiagnostics
import ResoniqStore
import SwiftData
import SwiftUI

/// Measure home (design/screens/V3Measure.dc.html): the day and the spots at the top right, the verdict as the
/// headline, the seat's response curve against the even band, up to three findings each with how it is known, the
/// primary button and the two links.
///
/// The screen decides nothing: every sentence comes from the report (`SeatDisplay` maps it), and what the buttons do
/// is the caller's. Without a measurement it shows the empty state, which has no mockup: the same curve panel
/// empty, with its even band and axis, and one sentence about what measuring from the seat will tell.
struct MeasureHomeView: View {
    var context: ListeningContext = .placeholder
    private let measurement: MeasureSummary?
    private let couldNotOpenSaved: Bool
    private let primaryTitle: String
    private let onPrimary: () -> Void
    private let onShowNumbers: () -> Void
    private let onWatchLive: () -> Void
    private let onOpenOptimize: () -> Void

    /// - Parameters:
    ///   - measurement: The latest seat measurement; nil for the empty state.
    ///   - couldNotOpenSaved: A stored measurement exists but cannot be read, so it is treated as none and the
    ///     screen says so.
    ///   - primaryTitle: "Measure again from my seat", or "Measure from my seat" with nothing measured.
    ///   - onOpenOptimize: The inferred "It's the room, not the speakers" finding was tapped.
    init(
        context: ListeningContext = .placeholder,
        measurement: MeasureSummary?,
        couldNotOpenSaved: Bool = false,
        primaryTitle: String,
        onPrimary: @escaping () -> Void,
        onShowNumbers: @escaping () -> Void,
        onWatchLive: @escaping () -> Void,
        onOpenOptimize: @escaping () -> Void
    ) {
        self.context = context
        self.measurement = measurement
        self.couldNotOpenSaved = couldNotOpenSaved
        self.primaryTitle = primaryTitle
        self.onPrimary = onPrimary
        self.onShowNumbers = onShowNumbers
        self.onWatchLive = onWatchLive
        self.onOpenOptimize = onOpenOptimize
    }

    var body: some View {
        TabHome(context: context) {
            if let measurement {
                dayLine(measurement)
            }
        } content: {
            VStack(spacing: ResoniqSpace.panelPadding) {
                ScrollView {
                    VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
                        if let measurement {
                            result(measurement)
                        } else {
                            empty
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)

                actions
            }
        }
    }

    // MARK: Day line

    private func dayLine(_ measurement: MeasureSummary) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(measurement.day)
            Text(measurement.spots)
        }
        .font(ResoniqFont.caption)
        .foregroundStyle(ResoniqColor.muted)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(measurement.dayAccessibilityLabel)
    }

    // MARK: With a measurement

    @ViewBuilder
    private func result(_ measurement: MeasureSummary) -> some View {
        let report = measurement.report
        Text(report.verdict)
            .resoniqTitle(.compact)
            .accessibilityAddTraits(.isHeader)
            .resoniqTitleRise()

        curvePanel(report)

        let findings = report.displayedFindings
        if !findings.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                    if index > 0 {
                        Rectangle().fill(ResoniqColor.line).frame(height: ResoniqSize.strokeHairline)
                    }
                    FindingRow(finding: finding, opensOptimize: finding.kind == .roomCause, onOpen: onOpenOptimize)
                }
            }
        }
    }

    private func curvePanel(_ report: SeatReport) -> some View {
        ResponseCurve(
            levels: report.curveLevels ?? [],
            evenBand: Double(report.evenBandDecibels),
            range: SeatScale.decibelsEachWay,
            extremes: report.curveExtremes,
            drawsOnAppear: true,
            title: SeatWords.curveTitle,
            detail: SeatDisplay.evenBandLabel(report.evenBandDecibels),
            accessibilityLabel: report.curveAccessibilityLabel
        )
        .resoniqPanel()
    }

    // MARK: Empty

    @ViewBuilder
    private var empty: some View {
        Text(SeatWords.emptyHeadline)
            .resoniqTitle(.compact)
            .accessibilityAddTraits(.isHeader)
            .resoniqTitleRise()

        ResponseCurve(
            levels: [],
            evenBand: Double(SeatThresholds.standard.evenBandDecibels),
            range: SeatScale.decibelsEachWay,
            title: SeatWords.curveTitle,
            detail: SeatDisplay.evenBandLabel(SeatThresholds.standard.evenBandDecibels),
            accessibilityLabel: SeatWords.emptyCurveLabel
        )
        .resoniqPanel()

        if couldNotOpenSaved {
            Text(SeatWords.unreadable)
                .font(ResoniqFont.body)
                .foregroundStyle(ResoniqColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 0) {
            Button(primaryTitle, action: onPrimary)
                .buttonStyle(ResoniqPrimaryButtonStyle())
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Metrics.linkGap) { links }
                VStack(spacing: 0) { links }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var links: some View {
        // A measurement that could not conclude has no numbers to show.
        if measurement?.report.isConclusive == true {
            Button(SeatWords.showNumbers, action: onShowNumbers)
                .buttonStyle(ResoniqTextLinkStyle())
        }
        Button(SeatWords.watchLive, action: onWatchLive)
            .buttonStyle(ResoniqTextLinkStyle())
    }

    private enum Metrics {
        /// V3Measure puts 28 pt between the two links.
        static let linkGap: CGFloat = 28
    }
}

// MARK: - A finding

/// One finding as V3Measure draws it: its dot, the headline, and how it is known. The inferred cause leads to
/// Optimize and says so with a chevron.
private struct FindingRow: View {
    let finding: SeatFinding
    let opensOptimize: Bool
    let onOpen: () -> Void

    var body: some View {
        if opensOptimize {
            Button(action: onOpen) { content }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(SeatWords.cause)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: ResoniqSpace.s3) {
            ResoniqEvidenceMark(finding.evidenceKind, isDeviation: finding.isDeviation)
                .padding(.top, Metrics.markTop)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.headline)
                    .font(ResoniqFont.bodySemibold)
                    .foregroundStyle(ResoniqColor.ivory)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.tagLine)
                    .font(ResoniqFont.caption)
                    .foregroundStyle(ResoniqColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if opensOptimize {
                ResoniqIconView(.arrowRight)
                    .foregroundStyle(ResoniqColor.guide)
                    .padding(.top, Metrics.chevronTop)
            }
        }
        .padding(.vertical, Metrics.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(finding.spokenSummary)
    }

    private enum Metrics {
        /// V3Measure: 9 pt above and below a row, the dot 5 pt down, the chevron 2 pt down.
        static let rowPadding: CGFloat = 9
        static let markTop: CGFloat = 5
        static let chevronTop: CGFloat = 2
    }
}

// MARK: - From the store

/// Measure home for the selected sound system, read from the store.
///
/// The latest seat measurement comes from the model container in the environment, so the screen updates when one
/// is kept. A stored measurement that cannot be read counts as none, and the screen says so.
struct MeasureHomeContainer: View {
    /// Starts a seat measurement: the primary button, with or without a result.
    let onMeasure: () -> Void
    /// "Show the numbers", with the report and when it was measured.
    let onShowNumbers: (SeatReport, Date) -> Void
    let onWatchLive: () -> Void
    /// The inferred room finding was tapped.
    let onOpenOptimize: () -> Void

    @Query private var states: [StoreState]
    @Query(sort: \Room.createdAt) private var rooms: [Room]
    @Query(sort: \SeatMeasurement.date, order: .reverse) private var measurements: [SeatMeasurement]

    /// The selected system, else the first one of the oldest room that has one; nil before anything exists.
    private var system: SoundSystem? {
        states.first?.selectedSystem ?? rooms.lazy.compactMap { $0.orderedSystems.first }.first
    }

    var body: some View {
        let system = system
        let context = system.map { ListeningContext(room: $0.room?.name ?? StoreText.defaultRoomName, system: $0.name) }
            ?? ListeningContext(room: StoreText.defaultRoomName, system: StoreText.defaultSystemName)
        // `measurements` is newest first: the newest of this system, readable or not.
        let latest = system.flatMap { system in measurements.first { $0.system === system } }
        let report = latest?.report
        let summary = latest.flatMap { measurement in report.map { MeasureSummary(report: $0, date: measurement.date) } }

        MeasureHomeView(
            context: context,
            measurement: summary,
            couldNotOpenSaved: latest != nil && report == nil,
            primaryTitle: summary == nil ? SeatWords.measureTitle : SeatWords.measureAgainTitle,
            onPrimary: onMeasure,
            onShowNumbers: { if let summary { onShowNumbers(summary.report, summary.date) } },
            onWatchLive: onWatchLive,
            onOpenOptimize: onOpenOptimize
        )
    }
}

// MARK: - Previews

#Preview("The mockup's room") {
    MeasureHomeView(
        measurement: MeasureSummary(report: MeasureFixtures.mockup, date: .now.addingTimeInterval(-3 * 86_400)),
        primaryTitle: SeatWords.measureAgainTitle,
        onPrimary: {}, onShowNumbers: {}, onWatchLive: {}, onOpenOptimize: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Even room") {
    MeasureHomeView(
        measurement: MeasureSummary(report: MeasureFixtures.even, date: .now),
        primaryTitle: SeatWords.measureAgainTitle,
        onPrimary: {}, onShowNumbers: {}, onWatchLive: {}, onOpenOptimize: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Empty") {
    MeasureHomeView(
        measurement: nil,
        primaryTitle: SeatWords.measureTitle,
        onPrimary: {}, onShowNumbers: {}, onWatchLive: {}, onOpenOptimize: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Inconclusive") {
    MeasureHomeView(
        measurement: MeasureSummary(report: MeasureFixtures.inconclusive, date: .now),
        primaryTitle: SeatWords.measureAgainTitle,
        onPrimary: {}, onShowNumbers: {}, onWatchLive: {}, onOpenOptimize: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Largest text") {
    MeasureHomeView(
        measurement: MeasureSummary(report: MeasureFixtures.mockup, date: .now),
        primaryTitle: SeatWords.measureAgainTitle,
        onPrimary: {}, onShowNumbers: {}, onWatchLive: {}, onOpenOptimize: {}
    )
    .dynamicTypeSize(.accessibility2)
    .preferredColorScheme(.dark)
}
