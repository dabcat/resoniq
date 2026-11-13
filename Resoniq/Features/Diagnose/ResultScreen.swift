import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqStore
import SwiftUI

/// Where a result was kept: the room and the system it belongs to.
struct KeptIn: Equatable {
    var room: String
    var system: String
}

/// The result of one speaker (design/screens/V3Result.dc.html): the verdict, the finished portrait with each
/// finding written beside it at the height of its frequency, where it is kept, and the next test.
///
/// The screen decides nothing. Every sentence comes from the report, and what happens next is the caller's:
/// the primary button's title and action (the caller knows which test is the most useful next, or that the
/// recordings failed and the same test should be tried again), and what each of the other controls does.
struct ResultScreen: View {
    let report: SpeakerReport
    let speaker: SpeakerPosition
    /// Nil is a quick check that was not saved: the screen says so instead of showing where it is kept.
    let keptIn: KeptIn?
    /// The Kit's sentence when the phone moved while a run played (`ReadingText.phoneMovedNote`); nil when it did not, and
    /// for a result opened from the store, which does not carry it.
    var phoneMovedNote: String? = nil
    let primaryTitle: String
    let onPrimary: () -> Void
    let onOpenFinding: (Finding) -> Void
    let onRename: () -> Void
    let onDontKeep: () -> Void
    let onClose: () -> Void

    /// VoiceOver lands on the verdict when the screen appears, not on the line above it.
    @AccessibilityFocusState private var verdictFocused: Bool

    var body: some View {
        VStack(spacing: ResoniqSpace.s4) {
            ScrollView {
                VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
                    header
                    portraitPanel
                    movedNote
                    keptRow
                }
                .padding(.horizontal, ResoniqSpace.screenInset)
            }
            .scrollIndicators(.hidden)

            Button(primaryTitle, action: onPrimary)
                .buttonStyle(ResoniqPrimaryButtonStyle())
                .padding(.horizontal, ResoniqSpace.screenInset)
        }
        .padding(.top, ResoniqSpace.s3)
        .padding(.bottom, ResoniqSpace.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ResoniqColor.ink)
        .accessibilityAction(.escape, onClose)
        .onAppear { verdictFocused = true }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            Text(caption)
                .resoniqCapsLabel()
            Text(report.verdict)
                .resoniqTitle(.medium)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($verdictFocused)
        }
    }

    /// "Left speaker · 3 runs".
    private var caption: String {
        let runs = report.runs.count
        return "\(speaker.speakerPhrase) · \(runs) \(runs == 1 ? "run" : "runs")"
    }

    // MARK: Portrait and findings

    private var portraitPanel: some View {
        PortraitNotesLayout(minHeight: Metrics.portraitHeight, noteGap: ResoniqSpace.s3, gutter: Metrics.gutter) {
            HStack(alignment: .top, spacing: ResoniqSpace.s1) {
                FrequencyRuler(.beside)
                SpeakerPortrait(
                    widths: report.profile.portraitWidths,
                    state: report.profile.portraitStatus,
                    deviations: report.profile.portraitDeviations,
                    accessibilityLabel: "\(speaker.speakerPhrase) portrait. \(report.verdict)"
                )
                .frame(width: Metrics.portraitWidth)
            }

            ForEach(report.findings) { finding in
                FindingNote(finding: finding) { onOpenFinding(finding) }
                    .layoutValue(key: NoteHeight.self, value: finding.heightFraction)
            }
        }
        .resoniqPanel()
    }

    /// "The phone moved while run 2 played. I kept that run, so read its details with a little care." with how it is
    /// known. Said plainly, not as a finding: the run is kept and the result stands.
    @ViewBuilder
    private var movedNote: some View {
        if let phoneMovedNote {
            VStack(alignment: .leading, spacing: 3) {
                ResoniqEvidenceTag(.measured, basis: ReadingText.phoneMovedBasis)
                Text(phoneMovedNote)
                    .font(ResoniqFont.body)
                    .foregroundStyle(ResoniqColor.ivory)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(phoneMovedNote) Measured, from \(ReadingText.phoneMovedBasis).")
        }
    }

    // MARK: Where it is kept

    @ViewBuilder
    private var keptRow: some View {
        if let keptIn {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ResoniqSpace.s3) {
                    keptLabel(keptIn)
                    Spacer(minLength: 0)
                    keptActions
                }
                VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
                    keptLabel(keptIn)
                    HStack(spacing: ResoniqSpace.s5) { keptActions }
                }
            }
            .frame(minHeight: Metrics.keptRowHeight)
        } else {
            Text(Words.notSaved)
                .font(ResoniqFont.body)
                .foregroundStyle(ResoniqColor.muted)
                .frame(minHeight: Metrics.keptRowHeight, alignment: .leading)
        }
    }

    private func keptLabel(_ keptIn: KeptIn) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Kept in").resoniqCapsLabel()
            Text("\(keptIn.room) · \(keptIn.system)")
                .font(ResoniqFont.bodyMedium)
                .foregroundStyle(ResoniqColor.ivory)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var keptActions: some View {
        Button("Rename", action: onRename)
            .buttonStyle(ResoniqInlineLinkStyle())
        Button("Don't keep", action: onDontKeep)
            .buttonStyle(ResoniqInlineLinkStyle(.quiet))
    }

    // MARK: Constants

    /// Words on this screen that do not describe the speaker.
    enum Words {
        /// Shown in place of "Kept in" after a quick check.
        static let notSaved = "This was a quick check, so it isn't saved."
    }

    private enum Metrics {
        /// V3Result draws the portrait 380 pt tall inside its panel.
        static let portraitHeight: CGFloat = 380
        /// The portrait's own width: the 80 pt the shape spans in the mockup, with room for a peak.
        static let portraitWidth: CGFloat = 86
        /// Between the portrait and the findings written beside it.
        static let gutter: CGFloat = 14
        static let keptRowHeight: CGFloat = 48
    }
}

// MARK: - A finding beside the portrait

/// One finding as the portrait's margin note: tag, title, then the line that says more, or the way to hear it
/// (`Finding.noteAction` decides which, and whether the row leads to the Finding screen).
private struct FindingNote: View {
    let finding: Finding
    /// Opens the Finding screen, for the findings that have one.
    let onHear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            text
            switch finding.noteAction {
            case .hear:
                Button("Hear it yourself", action: onHear)
                    .buttonStyle(ResoniqInlineLinkStyle(.deviation))
            case .showRuns:
                Button("See the runs", action: onHear)
                    .buttonStyle(ResoniqInlineLinkStyle(.deviation))
            case .informational:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            ResoniqEvidenceTag(finding.evidenceKind, basis: finding.tagBasis, isDeviation: finding.kind.isDeviation)
            Text(finding.headline)
                .font(finding.kind.isDeviation ? ResoniqFont.bodySemibold : ResoniqFont.bodyMedium)
                .foregroundStyle(ResoniqColor.ivory)
                .fixedSize(horizontal: false, vertical: true)
            // The mockup gives a finding with something to hear its title and the way to hear it, no more.
            if !finding.hasSomethingToHear {
                Text(finding.detail)
                    .font(ResoniqFont.caption)
                    .foregroundStyle(ResoniqColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(finding.headline). \(finding.detail) \(finding.tagLine).")
    }
}

// MARK: - Layout

/// Where a note wants to sit, as a fraction of the portrait's height from the bottom; nil for a finding with no
/// frequency, which goes to the top.
private nonisolated struct NoteHeight: LayoutValueKey {
    static let defaultValue: Double? = nil
}

/// The portrait with its ruler (the first subview) and the notes beside it. Each note is centred at the height
/// of its frequency; a note that would overlap the one above moves down, and when there are too many to fit, the
/// whole thing grows, the portrait with it, so the notes stay in the order of the frequencies and the portrait
/// stays as wide as it was.
private struct PortraitNotesLayout: Layout {
    var minHeight: CGFloat
    var noteGap: CGFloat
    var gutter: CGFloat

    private struct Plan {
        var height: CGFloat
        var portraitWidth: CGFloat
        var noteWidth: CGFloat
        /// The top of each note, in the order of the subviews after the first.
        var tops: [CGFloat]
        var sizes: [CGSize]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.fallbackWidth
        return CGSize(width: width, height: plan(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let portrait = subviews.first else { return }
        let plan = plan(width: bounds.width, subviews: subviews)
        portrait.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: plan.portraitWidth, height: plan.height)
        )
        let x = bounds.minX + plan.portraitWidth + gutter
        for (index, subview) in subviews.dropFirst().enumerated() {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY + plan.tops[index]),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: plan.noteWidth, height: plan.sizes[index].height)
            )
        }
    }

    private static let fallbackWidth: CGFloat = 320
    private static let narrowestNote: CGFloat = 80

    private func plan(width: CGFloat, subviews: Subviews) -> Plan {
        guard let portrait = subviews.first else {
            return Plan(height: minHeight, portraitWidth: 0, noteWidth: width, tops: [], sizes: [])
        }
        let portraitWidth = portrait.sizeThatFits(ProposedViewSize(width: nil, height: minHeight)).width
        let noteWidth = max(width - portraitWidth - gutter, Self.narrowestNote)
        let notes = Array(subviews.dropFirst())
        let sizes = notes.map { $0.sizeThatFits(ProposedViewSize(width: noteWidth, height: nil)) }
        let wants = notes.map { $0[NoteHeight.self] }

        // Two passes: the second lays the notes out against the height the first needed.
        var height = minHeight
        var tops: [CGFloat] = []
        for _ in 0..<2 {
            (tops, height) = settle(height: height, sizes: sizes, wants: wants)
        }
        return Plan(height: height, portraitWidth: portraitWidth, noteWidth: noteWidth, tops: tops, sizes: sizes)
    }

    /// The tops of the notes for a portrait `height` tall, and the height they need.
    private func settle(height: CGFloat, sizes: [CGSize], wants: [Double?]) -> ([CGFloat], CGFloat) {
        // Top of the portrait first: the nil ones, then the highest frequency down.
        let order = sizes.indices.sorted { (wants[$0] ?? .infinity, -Double($0)) > (wants[$1] ?? .infinity, -Double($1)) }
        var tops = [CGFloat](repeating: 0, count: sizes.count)
        var cursor: CGFloat = 0
        for index in order {
            let centre = wants[index].map { height * (1 - CGFloat($0)) } ?? 0
            let top = max(centre - sizes[index].height / 2, cursor, 0)
            tops[index] = top
            cursor = top + sizes[index].height + noteGap
        }
        let needed = sizes.isEmpty ? minHeight : cursor - noteGap
        return (tops, max(minHeight, needed))
    }
}

#if DEBUG
#Preview("Buzz, dip, even") {
    ResultScreen(
        report: DiagnoseFixtures.buzzing, speaker: .left, keptIn: KeptIn(room: "My room", system: "My speakers"),
        primaryTitle: "Now the right speaker", onPrimary: {}, onOpenFinding: { _ in },
        onRename: {}, onDontKeep: {}, onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Healthy, quick check") {
    ResultScreen(
        report: DiagnoseFixtures.healthy, speaker: .right, keptIn: nil,
        primaryTitle: "Done", onPrimary: {}, onOpenFinding: { _ in },
        onRename: {}, onDontKeep: {}, onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Inconclusive") {
    ResultScreen(
        report: DiagnoseFixtures.inconclusive, speaker: .left, keptIn: nil,
        primaryTitle: "Try the left speaker again", onPrimary: {}, onOpenFinding: { _ in },
        onRename: {}, onDontKeep: {}, onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Largest text") {
    ResultScreen(
        report: DiagnoseFixtures.buzzing, speaker: .left, keptIn: KeptIn(room: "My room", system: "My speakers"),
        primaryTitle: "Now the right speaker", onPrimary: {}, onOpenFinding: { _ in },
        onRename: {}, onDontKeep: {}, onClose: {}
    )
    .dynamicTypeSize(.accessibility2)
    .preferredColorScheme(.dark)
}
#endif
