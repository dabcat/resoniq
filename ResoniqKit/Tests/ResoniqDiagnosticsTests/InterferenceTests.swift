import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

/// Labels for back-to-back 1.5 s windows overlapping by half, as `SystemSoundClassifier` gives them.
func windows(_ labels: [[(String, Float)]]) -> [SoundClassification] {
    labels.enumerated().flatMap { index, window in
        window.map { SoundClassification(identifier: $0.0, confidence: $0.1, start: Double(index) * 0.75, duration: 1.5) }
    }
}

/// A classifier that returns what it is given, or fails.
struct StubClassifier: SoundClassifying {
    var result: Result<[SoundClassification], StubError>
    struct StubError: Error {}

    func classify(_ samples: [Float], sampleRate: Double) async throws -> [SoundClassification] {
        try result.get()
    }
}

@Suite struct InterferenceMappingTests {
    @Test func `every mapped identifier is one the system classifier knows`() {
        let known = Set(SoundClassifierLabels.version1)
        #expect(SoundClassifierLabels.version1.count == 303)
        for identifier in InterferenceMapping.labels.keys.sorted() + InterferenceMapping.ignored.sorted() {
            #expect(known.contains(identifier), "\(identifier) is not a label of the system classifier")
        }
    }

    @Test func `the kinds that matter are mapped, and the sweep's own labels are test signal`() {
        #expect(InterferenceMapping.label(for: "speech") == .kind(.speech))
        #expect(InterferenceMapping.label(for: "music") == .kind(.music))
        #expect(InterferenceMapping.label(for: "vacuum_cleaner") == .kind(.appliance))
        #expect(InterferenceMapping.label(for: "dog_bark") == .kind(.animal))
        #expect(InterferenceMapping.label(for: "traffic_noise") == .kind(.traffic))
        #expect(InterferenceMapping.label(for: "door_slam") == .kind(.doorOrFootsteps))
        #expect(InterferenceMapping.label(for: "rain") == .kind(.windOrRain))
        #expect(InterferenceMapping.label(for: "baby_crying") == .kind(.babyOrChildren))
        #expect(InterferenceMapping.label(for: "ringtone") == .kind(.phoneOrAlarm))
        for label in ["synthesizer", "theremin", "tuning_fork", "beep", "whistling", "bell"] {
            #expect(InterferenceMapping.label(for: label) == .testSignal)
        }
        #expect(InterferenceMapping.label(for: "cough") == nil)
        // Every kind but the TV (no such label) and unknown (not a label) has labels.
        let mapped = Set(InterferenceMapping.labels.values.compactMap { if case .kind(let kind) = $0 { kind } else { nil } })
        #expect(mapped == Set(InterferenceKind.allCases).subtracting([.televisionOrRadio, .unknown]))
    }
}

@Suite struct InterferenceAdvisorTests {
    @Test func `speech over most of the stretch is named, inferred, with its basis`() throws {
        let labels = windows([
            [("speech", 0.9), ("music", 0.1)],
            [("speech", 0.8), ("music", 0.2)],
            [("silence", 0.9)],
        ])
        let report = try #require(InterferenceAdvisor.describe(classifications: labels))
        #expect(report.kind == .speech)
        #expect(report.sentence == "It sounds like someone talking.")
        #expect(abs(report.confidence - 0.85) < 1e-6)
        #expect(report.basis == "sound classifier, 85 %")
        #expect(report.tagLine == "Inferred · sound classifier, 85 %")
        #expect(report.tag == .inferred)
        #expect(abs(report.duration - 2.25) < 1e-9)
        #expect(abs(report.fraction - 2.25 / 3) < 1e-9)
    }

    @Test func `below the minimum confidence nothing is said`() {
        let labels = windows([[("speech", 0.45), ("waterfall", 0.3)], [("speech", 0.49)]])
        #expect(InterferenceAdvisor.describe(classifications: labels) == nil)
        #expect(InterferenceAdvisor.describe(classifications: []) == nil)
        // The threshold is the named one.
        #expect(InterferenceAdvisor.describe(classifications: labels, thresholds: InterferenceThresholds(minimumConfidence: 0.4))?.kind == .speech)
    }

    @Test func `the kind heard longest wins, and a tie goes to the more confident`() {
        let longer = windows([[("dog_bark", 0.95)], [("music", 0.6)], [("music", 0.7)], [("music", 0.6)]])
        #expect(InterferenceAdvisor.describe(classifications: longer)?.kind == .music)
        let tie = windows([[("dog_bark", 0.95), ("music", 0.6)]])
        #expect(InterferenceAdvisor.describe(classifications: tie)?.kind == .animal)
        // Labels of one kind count once per stretch, at the most confident.
        let several = windows([[("dog", 0.7), ("dog_bark", 0.9)]])
        #expect(InterferenceAdvisor.describe(classifications: several)?.confidence == 0.9)
    }

    @Test func `test-signal labels are never named, and while the sweep plays neither is music`() {
        let sweepLike = windows([[("music", 0.86), ("synthesizer", 0.76), ("theremin", 0.75)], [("bird_chirp_tweet", 0.52), ("whistling", 0.33)]])
        #expect(InterferenceAdvisor.describe(classifications: sweepLike, context: .sweepPlaying) == nil)
        // Without the sweep, the same music would be named, but the synthesizer never is.
        #expect(InterferenceAdvisor.describe(classifications: sweepLike, context: .sweepSilent)?.kind == .music)
        #expect(InterferenceAdvisor.describe(classifications: windows([[("synthesizer", 0.99)]])) == nil)
        // Speech over the sweep is still speech.
        let talkOver = windows([[("music", 0.9), ("speech", 0.8)]])
        #expect(InterferenceAdvisor.describe(classifications: talkOver, context: .sweepPlaying)?.kind == .speech)
    }

    @Test func `a confident label no kind covers is unknown, which adds nothing under the noise message`() async throws {
        let labels = windows([[("gunshot_gunfire", 0.8), ("silence", 0.9)]])
        let report = try #require(InterferenceAdvisor.describe(classifications: labels))
        #expect(report.kind == .unknown)
        #expect(report.sentence == "I couldn't tell what the sound was.")
        let note = await InterferenceAdvisor.noiseNote(heard: [0], sampleRate: 48000, context: .sweepSilent, classifier: StubClassifier(result: .success(labels)))
        #expect(note == nil)
        // While the sweep plays an unmapped label may be the sweep, so it is not even unknown.
        #expect(InterferenceAdvisor.describe(classifications: labels, context: .sweepPlaying) == nil)
        // Silence alone is nothing.
        #expect(InterferenceAdvisor.describe(classifications: windows([[("silence", 0.99)]])) == nil)
    }

    @Test func `the app's call returns the sentence, and nil when the classifier fails`() async {
        let talking = StubClassifier(result: .success(windows([[("speech", 0.82)]])))
        let sentence = await InterferenceAdvisor.noiseSentence(heard: [0], sampleRate: 48000, context: .sweepSilent, classifier: talking)
        #expect(sentence == "It sounds like someone talking.")
        let note = await InterferenceAdvisor.noiseNote(heard: [0], sampleRate: 48000, context: .sweepSilent, classifier: talking)
        #expect(note?.tagLine == "Inferred · sound classifier, 82 %")
        let failing = StubClassifier(result: .failure(.init()))
        #expect(await InterferenceAdvisor.noiseSentence(heard: [0], sampleRate: 48000, context: .sweepSilent, classifier: failing) == nil)
    }

    @Test(arguments: InterferenceKind.allCases)
    func `every sentence is hedged and in the product's voice`(kind: InterferenceKind) {
        let sentence = ModelText.interference(kind)
        checkWording(sentence)
        #expect(sentence.hasPrefix("It sounds like") || kind == .unknown)
        #expect(sentence.hasSuffix("."))
    }

    @Test func `percentages are whole and never 0 or 100`() {
        #expect(ModelText.percent(0.824) == "82 %")
        #expect(ModelText.percent(1) == "99 %")
        #expect(ModelText.percent(0.001) == "1 %")
    }
}

@Suite struct InterferenceInReportsTests {
    static let report = InterferenceAdvisor.describe(classifications: windows([[("vacuum_cleaner", 0.77)]]))!

    @Test func `a noisy run carries what was heard into its invalid-recording finding`() throws {
        let noisy = Bench.noisyRun.adding(interference: Self.report)
        #expect(noisy.record.interference == Self.report)
        #expect(noisy.verdict == Bench.noisyRun.verdict)
        let speaker = SpeakerDiagnosis.diagnose(runs: [Bench.buzzingRuns[0], Bench.clippedRun, noisy], counterpart: nil)
        let finding = try #require(speaker.findings.first { $0.recordingProblem == .tooNoisy })
        #expect(finding.interference == Self.report)
        #expect(finding.interference?.sentence == "It sounds like a machine running, such as a vacuum cleaner.")
        // Nothing else changes, and the clipped run's finding has none.
        #expect(speaker.findings.first { $0.recordingProblem == .clipped }?.interference == nil)
        let plain = SpeakerDiagnosis.diagnose(runs: [Bench.buzzingRuns[0], Bench.clippedRun, Bench.noisyRun], counterpart: nil)
        #expect(plain.verdict == speaker.verdict)
        #expect(plain.findings.map(\.headline) == speaker.findings.map(\.headline))
    }

    @Test func `a report with interference survives JSON, and one stored before it still decodes`() throws {
        let record = RunRecord(check: .tooNoisy(signalToNoise: 8), measurement: nil, interference: Self.report)
        let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        let old = try JSONDecoder().decode(RunRecord.self, from: Data(#"{"check":{"tooNoisy":{"signalToNoise":8}}}"#.utf8))
        #expect(old.interference == nil)
        // The pinned reports decode with no interference and no model lines.
        let speaker = try JSONDecoder().decode(SpeakerReport.self, from: Data(GoldenJSON.speaker.utf8))
        #expect(speaker.modelFindings == nil)
        #expect(speaker.findings.allSatisfy { $0.interference == nil && $0.modelSupport == nil })
        #expect(speaker.runs.allSatisfy { $0.interference == nil })
    }
}
