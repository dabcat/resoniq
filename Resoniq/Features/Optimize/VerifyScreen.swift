import ResoniqDesign
import ResoniqDiagnostics
import ResoniqStore
import SwiftUI

/// Before and after (design/screens/V3OVerify.dc.html): the completed tracker, the verdict, the two traces at the
/// same spots (the first dashed), the value rows, the honest note, and the way on.
///
/// Improvement is claimed here and nowhere else, and only from the comparison of two measurements: the verdict, the
/// rows and the note are the report's own words, every row measured. The screen decides nothing.
///
/// The three actions follow the mockup when something got better ("Keep this setup" primary, "Next suggestion" beside
/// it only when the report names a next target, "Put the speaker back where it was" as the link). Outcomes with no
/// mockup follow design/DESIGN_SYSTEM.md and use the report's verdict and note:
/// - **Worse:** "Put the speaker back where it was" is the primary action; "Keep this setup" is the link; no next
///   suggestion, because the report's note already says to put it back.
/// - **Unchanged, mixed, not conclusive:** the mockup's layout, without the check mark (it is for "improved").
///
/// There is no close button in the mockup; every action leaves the screen, and VoiceOver's escape gesture calls
/// `onClose`.
struct VerifyScreen: View {
    let comparison: ComparisonReport
    let before: SeatReport
    let after: SeatReport
    let onKeep: () -> Void
    let onNextSuggestion: () -> Void
    let onPutBack: () -> Void
    let onClose: () -> Void

    private var tracker: RoomDisplay.Tracker {
        RoomDisplay.tracker(OptimizeProgress(scanned: true, measured: true, moved: true, verified: true))
    }

    /// "Next suggestion" is offered only when the report names something left to work on, and not after a worse result.
    private var offersNext: Bool { comparison.nextTarget != nil && comparison.outcome != .worse }

    var body: some View {
        VStack(spacing: ResoniqSpace.s4) {
            ScrollView {
                VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
                    ResoniqProgressTracker(steps: tracker.steps, current: tracker.current)
                    verdict
                    curve
                    rows
                    Text(comparison.note)
                        .font(ResoniqFont.caption)
                        .foregroundStyle(ResoniqColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, ResoniqSpace.screenInset)
            }
            .scrollIndicators(.hidden)

            actions
                .padding(.horizontal, ResoniqSpace.screenInset)
        }
        .padding(.top, ResoniqSpace.s3)
        .padding(.bottom, ResoniqSpace.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ResoniqColor.ink)
        .accessibilityAction(.escape, onClose)
    }

    // MARK: Verdict

    private var verdict: some View {
        HStack(alignment: .top, spacing: ResoniqSpace.s3) {
            // The check is for an improvement only; the verdict's words carry the rest.
            if comparison.outcome == .improved {
                ResoniqIconView(.check)
                    .foregroundStyle(ResoniqColor.onAction)
                    .frame(width: Metrics.badge, height: Metrics.badge)
                    .background(ResoniqColor.improved, in: Circle())
                    .accessibilityHidden(true)
            }
            Text(comparison.verdict)
                .resoniqTitle(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: Chart and rows

    private var curve: some View {
        ResponseCurve(
            levels: RoomDisplay.levels(of: after), evenBand: Double(after.evenBandDecibels),
            range: RoomDisplay.Scale.curveDecibelsEachWay, before: RoomDisplay.levels(of: before),
            legend: [
                ResoniqLegendEntry(OptimizeText.before, color: ResoniqColor.muted, isDashed: true),
                ResoniqLegendEntry(OptimizeText.after(spots: after.validSpotCount), color: ResoniqColor.teal),
            ],
            accessibilityLabel: RoomDisplay.curveSummary(of: comparison)
        )
        .resoniqPanel()
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

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if comparison.outcome == .worse {
            VStack(spacing: 0) {
                Button(OptimizeText.putBack, action: onPutBack)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
                Button(OptimizeText.keepThisSetup, action: onKeep)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: ResoniqSpace.s3) {
                    if offersNext {
                        Button(OptimizeText.nextSuggestion, action: onNextSuggestion)
                            .buttonStyle(ResoniqSecondaryButtonStyle())
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Button(OptimizeText.keepThisSetup, action: onKeep)
                        .buttonStyle(ResoniqPrimaryButtonStyle())
                }
                Button(OptimizeText.putBack, action: onPutBack)
                    .buttonStyle(ResoniqTextLinkStyle())
                    .multilineTextAlignment(.center)
            }
        }
    }

    private enum Metrics {
        /// V3OVerify's check badge is 44 pt.
        static let badge: CGFloat = 44
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Improved (the mockup)") {
    VerifyScreen(
        comparison: OptimizeFixtures.improved, before: OptimizeFixtures.before, after: OptimizeFixtures.after,
        onKeep: {}, onNextSuggestion: {}, onPutBack: {}, onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Worse") {
    VerifyScreen(
        comparison: OptimizeFixtures.worse, before: OptimizeFixtures.before, after: OptimizeFixtures.worseAfter,
        onKeep: {}, onNextSuggestion: {}, onPutBack: {}, onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Unchanged") {
    VerifyScreen(
        comparison: OptimizeFixtures.unchanged, before: OptimizeFixtures.before, after: OptimizeFixtures.before,
        onKeep: {}, onNextSuggestion: {}, onPutBack: {}, onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Largest text") {
    VerifyScreen(
        comparison: OptimizeFixtures.improved, before: OptimizeFixtures.before, after: OptimizeFixtures.after,
        onKeep: {}, onNextSuggestion: {}, onPutBack: {}, onClose: {}
    )
    .environment(\.dynamicTypeSize, .accessibility2)
    .preferredColorScheme(.dark)
}
#endif
