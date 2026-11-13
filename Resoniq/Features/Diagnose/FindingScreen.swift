import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqStore
import SwiftUI

// MARK: - Tone

/// What "hold to hear" needs from the audio: a steady tone on one channel, started on press and stopped on release.
protocol FindingTonePlaying: AnyObject {
    /// Starts a steady tone at `frequency` hertz on `channel`. Safe to call while one is playing or starting.
    func start(frequency: Double, on channel: SpeakerChannel)
    /// Fades the tone out. Safe to call at any time, including before a start has finished.
    func stop()
}

/// Plays the tone with `ResoniqAudio.TonePlayer`.
///
/// `TonePlayer.start` is asynchronous, and a finger can lift before it has finished; a tone that began after the
/// release would then play until something else stopped it. The adapter remembers whether the tone is still wanted
/// and stops it the moment the player is ready if it is not.
final class TonePlayerAdapter: FindingTonePlaying {
    private let player: TonePlayer
    private var wanted = false
    private var starting: Task<Void, Never>?

    init(player: TonePlayer) {
        self.player = player
    }

    func start(frequency: Double, on channel: SpeakerChannel) {
        wanted = true
        let previous = starting
        starting = Task { [player] in
            await previous?.value
            guard wanted else { return }
            do {
                try await player.start(frequency: frequency, on: channel)
            } catch {
                return
            }
            if !wanted { player.stop() }
        }
    }

    func stop() {
        wanted = false
        player.stop()
    }
}

/// Plays nothing: for previews and the debug screens, which have no speaker to play through.
final class SilentTonePlayer: FindingTonePlaying {
    private(set) var isPlaying = false

    func start(frequency: Double, on channel: SpeakerChannel) { isPlaying = true }
    func stop() { isPlaying = false }
}

// MARK: - Screen

/// One finding, with the way to check it by ear (design/screens/V3Finding.dc.html): the sentence, the runs it
/// rests on laid one above the other, hold-to-hear, how sure the finding is, and what to do next.
///
/// The words about the speaker come from the finding. The two next steps are informational: the flow that can
/// run a swap test or a second listen does not exist yet, so they are not buttons.
struct FindingScreen: View {
    let finding: Finding
    let report: SpeakerReport
    let speaker: SpeakerPosition
    let tone: any FindingTonePlaying
    let onClose: () -> Void
    let onShowNumbers: () -> Void

    @State private var showsNumbers = false

    var body: some View {
        VStack(spacing: ResoniqSpace.s4) {
            topBar
                .padding(.horizontal, ResoniqSpace.screenInset)

            ScrollView {
                VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
                    Text(finding.sentence)
                        .resoniqTitle(.large)
                        .accessibilityAddTraits(.isHeader)
                    if let comparison {
                        comparisonPanel(comparison)
                    }
                    if let frequency = finding.listenFrequency {
                        holdToHear(frequency: frequency)
                    }
                    confidenceAndSteps
                }
                .padding(.horizontal, ResoniqSpace.screenInset)
            }
            .scrollIndicators(.hidden)

            if finding.numbers != nil {
                Button(Words.showNumbers(for: finding)) {
                    onShowNumbers()
                    showsNumbers = true
                }
                .buttonStyle(ResoniqTextLinkStyle())
                .padding(.horizontal, ResoniqSpace.screenInset)
            }
        }
        .padding(.top, ResoniqSpace.s3)
        .padding(.bottom, ResoniqSpace.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ResoniqColor.ink)
        .onDisappear { tone.stop() }
        .accessibilityAction(.escape, onClose)
        .sheet(isPresented: $showsNumbers) {
            FindingNumbersSheet(finding: finding, report: report)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: ResoniqSpace.s3) {
            Button(action: onClose) {
                ResoniqIconView(.back)
            }
            .buttonStyle(ResoniqIconButtonStyle())
            .accessibilityLabel("Back to the portrait")
            Text(eyebrow)
                .resoniqCapsLabel()
            Spacer(minLength: 0)
        }
    }

    /// "Left speaker · woofer".
    private var eyebrow: String {
        [speaker.speakerPhrase, finding.band?.displayName.lowercased()].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: The runs

    private var comparison: RunComparison? {
        RunComparison(finding: finding, report: report)
    }

    private func comparisonPanel(_ comparison: RunComparison) -> some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    runsCompared(comparison)
                    Spacer(minLength: ResoniqSpace.s2)
                    repeatability
                }
                VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
                    runsCompared(comparison)
                    repeatability
                }
            }
            RunOverlay(
                traces: comparison.traces,
                markedRange: comparison.marked,
                accessibilityLabel: comparison.accessibilityLabel
            )
            HStack {
                Text(comparison.lowerLabel)
                Spacer(minLength: ResoniqSpace.s1)
                Text(comparison.rangeLabel)
                    .foregroundStyle(ResoniqColor.signalText)
                Spacer(minLength: ResoniqSpace.s1)
                Text(comparison.upperLabel)
            }
            .font(ResoniqFont.axis)
            .foregroundStyle(ResoniqColor.muted)
            .accessibilityHidden(true)
        }
        .resoniqPanel()
    }

    private func runsCompared(_ comparison: RunComparison) -> some View {
        Text("\(comparison.traces.count) \(comparison.traces.count == 1 ? "run" : "runs") compared")
            .resoniqCapsLabel()
    }

    @ViewBuilder
    private var repeatability: some View {
        if let text = finding.repeatability {
            Text(text)
                .resoniqCapsLabel()
                .foregroundStyle(ResoniqColor.signalText)
        }
    }

    // MARK: Hold to hear

    private func holdToHear(frequency: Float) -> some View {
        let spoken = FrequencyRuler.spokenFrequency(Double(frequency))
        let label = "Hold to play \(spoken) through \(speaker.speakerInSentence)"
        let hold = ResoniqHoldToHear(accessibilityLabel: label) { pressing in
            if pressing {
                tone.start(frequency: Double(frequency), on: speaker.toneChannel)
            } else {
                tone.stop()
            }
        }
        let words = VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
            Text("Hold to hear it")
                .font(ResoniqFont.headline)
                .foregroundStyle(ResoniqColor.ivory)
            Text(Words.holdSentence(finding: finding, frequency: frequency, speaker: speaker))
                .font(ResoniqFont.bodySmall)
                .foregroundStyle(ResoniqColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: ResoniqSpace.s5) {
                hold
                words
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
                hold
                words
            }
        }
        .padding(.vertical, ResoniqSpace.s1)
    }

    // MARK: How sure, and what next

    private var confidenceAndSteps: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: ResoniqSpace.s3) {
                ResoniqEvidenceMark(finding.evidenceKind, isDeviation: finding.kind.isDeviation)
                    .padding(.top, Metrics.markInset)
                Text(finding.confidenceStatement)
                    .font(ResoniqFont.bodySmall)
                    .foregroundStyle(ResoniqColor.ivory)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, ResoniqSpace.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { rule }
            .accessibilityElement(children: .combine)

            if finding.hasSomethingToHear {
                ForEach(Words.nextSteps(finding: finding, speaker: speaker)) { step in
                    VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
                        Text(step.title)
                            .font(ResoniqFont.rowTitle)
                            .foregroundStyle(ResoniqColor.ivory)
                        Text(step.detail)
                            .font(ResoniqFont.caption)
                            .foregroundStyle(ResoniqColor.muted)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: Metrics.stepHeight, alignment: .leading)
                    .padding(.vertical, ResoniqSpace.s2)
                    .overlay(alignment: .top) { rule }
                    .accessibilityElement(children: .combine)
                }
                rule
            }
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(ResoniqColor.line)
            .frame(height: ResoniqSize.strokeHairline)
    }

    // MARK: Words

    /// Words on this screen that the finding does not carry.
    enum Words {
        struct Step: Identifiable {
            var title: String
            var detail: String
            var id: String { title }
        }

        static func showNumbers(for finding: Finding) -> String {
            finding.kind == .distortion ? "Show the distortion numbers" : "Show the numbers"
        }

        /// "I play a steady 90 Hz through the left speaker. Put your ear near the woofer."
        static func holdSentence(finding: Finding, frequency: Float, speaker: SpeakerPosition) -> String {
            let place = finding.band.map { "the \($0.displayName.lowercased())" } ?? "the speaker"
            return "I play a steady \(DiagnosisText.frequency(frequency)) through \(speaker.speakerInSentence). Put your ear near \(place)."
        }

        /// The swap test needs two speakers to swap; a single speaker or a soundbar goes straight to listening
        /// from another place.
        static func nextSteps(finding: Finding, speaker: SpeakerPosition) -> [Step] {
            var steps: [Step] = []
            if speaker != .single {
                steps.append(Step(
                    title: "Speaker or room? Swap test",
                    detail: "Swap left and right. If the \(problem(of: finding)) moves, it's the speaker."
                ))
            }
            let closer = finding.band.map { "A closer run at the \($0.displayName.lowercased()) raises confidence." }
                ?? "A closer run raises confidence."
            steps.append(Step(title: "Listen from a second spot", detail: closer))
            return steps
        }

        private static func problem(of finding: Finding) -> String {
            switch finding.kind {
            case .distortion: "buzz"
            case .responseDip, .topEndDip: "dip"
            case .responsePeak: "peak"
            case .leftRightDifference: "difference"
            case .even, .invalidRecording: "problem"
            }
        }
    }

    private enum Metrics {
        /// Lines the 10 pt tag dot up with the first line of the statement, as the mockup's 5 pt margin does.
        static let markInset: CGFloat = 5
        static let stepHeight: CGFloat = 60
    }
}

#Preview("Buzz") {
    FindingScreen(
        finding: DiagnoseFixtures.buzz, report: DiagnoseFixtures.buzzing, speaker: .left,
        tone: SilentTonePlayer(), onClose: {}, onShowNumbers: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Single speaker") {
    FindingScreen(
        finding: DiagnoseFixtures.buzz, report: DiagnoseFixtures.buzzing, speaker: .single,
        tone: SilentTonePlayer(), onClose: {}, onShowNumbers: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Largest text") {
    FindingScreen(
        finding: DiagnoseFixtures.buzz, report: DiagnoseFixtures.buzzing, speaker: .left,
        tone: SilentTonePlayer(), onClose: {}, onShowNumbers: {}
    )
    .dynamicTypeSize(.accessibility2)
    .preferredColorScheme(.dark)
}
