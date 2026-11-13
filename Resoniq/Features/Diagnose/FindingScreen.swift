import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqStore
import SwiftUI

// MARK: - Tone

/// What "hold to hear" needs from the audio: a steady tone on one channel, started on press and stopped on release,
/// and what became of it, so the screen can say when it could not start and when it stopped by itself.
protocol FindingTonePlaying: AnyObject {
    /// Why the latest start failed; nil before any start and after a start that worked.
    var failure: TonePlayerError? { get }
    /// How many tones have ended without the finger lifting: the player fades a tone out by itself after
    /// `TonePlayer.maximumDuration`. The control starts again each time this changes.
    var endedByItself: Int { get }
    /// Starts a steady tone at `frequency` hertz on `channel`. Safe to call while one is playing or starting.
    func start(frequency: Double, on channel: SpeakerChannel)
    /// Fades the tone out. Safe to call at any time, including before a start has finished.
    func stop()
}

/// Plays the tone with `ResoniqAudio.TonePlayer`.
///
/// `TonePlayer.start` is asynchronous, and a finger can lift before it has finished; a tone that began after the
/// release would then play until something else stopped it. The adapter remembers whether the tone is still wanted
/// and stops it the moment the player is ready if it is not. It keeps the error of a start that failed, and notices
/// when the player ends a tone nobody released (its time limit).
@Observable
final class TonePlayerAdapter: FindingTonePlaying {
    private(set) var failure: TonePlayerError?
    private(set) var endedByItself = 0

    @ObservationIgnored private let player: TonePlayer
    @ObservationIgnored private var wanted = false
    /// The player moves through "not playing" while it restarts for a new press; that is not a tone ending.
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var starting: Task<Void, Never>?

    init(player: TonePlayer) {
        self.player = player
    }

    func start(frequency: Double, on channel: SpeakerChannel) {
        wanted = true
        let previous = starting
        starting = Task { [player] in
            await previous?.value
            guard wanted else { return }
            isStarting = true
            defer { isStarting = false }
            do {
                try await player.start(frequency: frequency, on: channel)
            } catch {
                wanted = false
                failure = error as? TonePlayerError ?? .audioUnavailable
                return
            }
            failure = nil
            if !wanted {
                player.stop()
                return
            }
            watchPlayback()
        }
    }

    func stop() {
        wanted = false
        player.stop()
    }

    /// Calls `playbackChanged` the next time the player's `isPlaying` changes.
    private func watchPlayback() {
        withObservationTracking {
            _ = player.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in self?.playbackChanged() }
        }
    }

    private func playbackChanged() {
        if player.isPlaying {
            watchPlayback()
        } else if wanted, !isStarting {
            // The tone is over and nobody released it: the player's own time limit.
            wanted = false
            endedByItself += 1
        }
    }
}

/// Plays nothing: for previews and the debug screens, which have no speaker to play through. A preview can give it a
/// failure to show.
@Observable
final class SilentTonePlayer: FindingTonePlaying {
    private(set) var isPlaying = false
    private(set) var failure: TonePlayerError?
    private(set) var endedByItself = 0

    init(failure: TonePlayerError? = nil) {
        self.failure = failure
    }

    func start(frequency: Double, on channel: SpeakerChannel) { isPlaying = true }
    func stop() { isPlaying = false }
}

// MARK: - Screen

/// One finding, with the way to check it by ear (design/screens/V3Finding.dc.html): the sentence, the runs it
/// rests on laid one above the other, hold-to-hear, how sure the finding is, and what to do next.
///
/// The words about the speaker come from the finding. Hold-to-hear is there only for a finding with a tone to play
/// (`Finding.noteAction`); a quiet band has runs to show and nothing to hear. The next steps are informational: the
/// flow that can run a swap test or a second listen does not exist yet, so they are not buttons.
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
                    if finding.hasSomethingToHear, let frequency = finding.listenFrequency {
                        if report.source == .anotherDevice {
                            holdToHearUnavailable(frequency: frequency)
                        } else {
                            holdToHear(frequency: frequency)
                        }
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
            if comparison.hasGaps {
                Text(RunComparison.Words.gaps)
                    .font(ResoniqFont.caption)
                    .foregroundStyle(ResoniqColor.muted)
                    .accessibilityHidden(true)
            }
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

    /// The test sound came from another device, so the phone cannot play the tone: instead of a control that would
    /// fail, the Kit's sentence says how to hear it (play the file again and listen as it passes the frequency).
    private func holdToHearUnavailable(frequency: Float) -> some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
            Text("Hear it yourself")
                .font(ResoniqFont.headline)
                .foregroundStyle(ResoniqColor.ivory)
            Text(DiagnosisText.holdToHearUnavailable(frequency: DiagnosisText.frequency(frequency)))
                .font(ResoniqFont.bodySmall)
                .foregroundStyle(ResoniqColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, ResoniqSpace.s1)
        .accessibilityElement(children: .combine)
    }

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
        // A tone the player ended by itself (its time limit) leaves the control looking held: a new control is
        // not, and the next press starts a new tone.
        .id(tone.endedByItself)
        let words = VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
            Text("Hold to hear it")
                .font(ResoniqFont.headline)
                .foregroundStyle(ResoniqColor.ivory)
            Text(Words.holdSentence(finding: finding, frequency: frequency, speaker: speaker))
                .font(ResoniqFont.bodySmall)
                .foregroundStyle(ResoniqColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        return VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            ViewThatFits(in: .horizontal) {
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
            if let failure = tone.failure {
                Text(Words.toneFailure(failure))
                    .font(ResoniqFont.bodySmall)
                    .foregroundStyle(ResoniqColor.ivory)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.vertical, ResoniqSpace.s1)
        // Read when it appears, and again when a later press fails.
        .onChange(of: tone.failure) { _, failure in
            if let failure { AccessibilityNotification.Announcement(Words.toneFailure(failure)).post() }
        }
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

            let steps = Words.nextSteps(finding: finding, speaker: speaker)
            if !steps.isEmpty {
                ForEach(steps) { step in
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

        /// "The tone would come from this iPhone. Connect your speakers with a cable, Bluetooth or AirPlay, then hold
        /// again." / "I couldn't start the tone. Close anything else that plays sound, then hold again."
        static func toneFailure(_ error: TonePlayerError) -> String {
            switch error {
            case .speakersNotConnected:
                "The tone would come from this iPhone. Connect your speakers with a cable, Bluetooth or AirPlay, then hold again."
            case .audioUnavailable:
                "I couldn't start the tone. Close anything else that plays sound, then hold again."
            }
        }

        /// What to do next, for the findings that are about the speaker's sound. The swap test needs two speakers to
        /// swap, and a top-end dip may be the phone's angle, which a swap cannot tell; a single speaker or a soundbar
        /// goes straight to listening from another place. A statement, an unusable run, an unchecked band and an unclear
        /// reading have nothing to follow up here.
        static func nextSteps(finding: Finding, speaker: SpeakerPosition) -> [Step] {
            let swaps: Bool
            let secondSpot: Bool
            switch finding.kind {
            case .responseDip, .responsePeak, .distortion, .leftRightDifference, .quietBand, .rattle:
                swaps = speaker != .single
                secondSpot = true
            case .topEndDip:
                swaps = false
                secondSpot = true
            case .even, .invalidRecording, .distortionUnclear, .notAssessed:
                swaps = false
                secondSpot = false
            }
            var steps: [Step] = []
            if swaps {
                steps.append(Step(
                    title: "Speaker or room? Swap test",
                    detail: "Swap left and right. If the \(problem(of: finding)) moves, it's the speaker."
                ))
            }
            if secondSpot {
                let closer = finding.band.map { "A closer run at the \($0.displayName.lowercased()) raises confidence." }
                    ?? "A closer run raises confidence."
                steps.append(Step(title: "Listen from a second spot", detail: closer))
            }
            return steps
        }

        private static func problem(of finding: Finding) -> String {
            switch finding.kind {
            case .distortion: "buzz"
            case .responseDip, .topEndDip: "dip"
            case .responsePeak: "peak"
            case .leftRightDifference: "difference"
            case .quietBand: "quiet band"
            case .rattle: "rattle"
            case .even, .invalidRecording, .distortionUnclear, .notAssessed: "problem"
            }
        }
    }

    private enum Metrics {
        /// Lines the 10 pt tag dot up with the first line of the statement, as the mockup's 5 pt margin does.
        static let markInset: CGFloat = 5
        static let stepHeight: CGFloat = 60
    }
}

#if DEBUG
#Preview("Buzz") {
    FindingScreen(
        finding: DiagnoseFixtures.buzz, report: DiagnoseFixtures.buzzing, speaker: .left,
        tone: SilentTonePlayer(), onClose: {}, onShowNumbers: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Quiet woofer") {
    FindingScreen(
        finding: DiagnoseFixtures.quietWoofer.findings.first { $0.kind == .quietBand }!,
        report: DiagnoseFixtures.quietWoofer, speaker: .left,
        tone: SilentTonePlayer(), onClose: {}, onShowNumbers: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Speakers not connected") {
    FindingScreen(
        finding: DiagnoseFixtures.buzz, report: DiagnoseFixtures.buzzing, speaker: .left,
        tone: SilentTonePlayer(failure: .speakersNotConnected), onClose: {}, onShowNumbers: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Audio unavailable") {
    FindingScreen(
        finding: DiagnoseFixtures.buzz, report: DiagnoseFixtures.buzzing, speaker: .left,
        tone: SilentTonePlayer(failure: .audioUnavailable), onClose: {}, onShowNumbers: {}
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
#endif
