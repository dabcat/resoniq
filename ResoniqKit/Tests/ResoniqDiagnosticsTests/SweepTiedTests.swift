import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

/// What the session heard in the rattle test of `ResoniqAudioTests.SweepTiedSoundTests`: a rattle at 180–320 Hz is
/// marked at about 92–433 Hz (the band-pass skirt and a block either side).
let rattleBand = SweepTiedSound(range: FrequencyRange(lower: 92, upper: 433))

/// Clean hand-built runs, with sound tied to the sweep heard in the runs at `tied` (run index → range).
func tiedRuns(_ tied: [Int: SweepTiedSound], count: Int = 3, run: () -> RunAnalysis = { Handmade.run() }) -> [RunAnalysis] {
    (0..<count).map { index in run().adding(sweepTiedSound: tied[index]) }
}

@Suite struct SweepTiedFindingTests {
    static let twoOfThree = SpeakerDiagnosis.diagnose(runs: tiedRuns([0: rattleBand, 2: rattleBand]), counterpart: nil)

    @Test func `sound tied to the sweep in two of three runs is an inferred, hedged rattle finding`() throws {
        let report = Self.twoOfThree
        let rattle = try #require(report.findings.first { $0.kind == .rattle })
        #expect(rattle.tag == .inferred)
        #expect(rattle.basis.text == "2 of 3 runs")
        #expect(rattle.tagLine == "Inferred · 2 of 3 runs")
        #expect(rattle.confidence == .low)
        #expect(rattle.kind.isDeviation)
        #expect(rattle.sentence == "Something may be rattling around 200 Hz.")
        #expect(rattle.headline == "Possible rattle at 90–430 Hz")
        #expect(rattle.detail == "Around 90–430 Hz a sound that wasn't the test tone came back at the same point when I played that part again, so it followed the test sound, not the room's background. I can't measure how loud it was.")
        #expect(rattle.confidenceStatement == "Inferred, low confidence. It came back at the same place in 2 of 3 runs, but the room or something near the speaker vibrating would sound the same.")
        #expect(rattle.repeatability == "Same place in 2 of 3 runs")
        #expect(rattle.listenFrequency == 200)
        #expect(rattle.numbers == nil)
        #expect(report.verdict == "Sounds healthy, except something may be rattling around 200 Hz.")
        // The drivers it overlaps are not called even.
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.bands == [.tweeter])
    }

    @Test func `in every run it is medium confidence and still names the alternative`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: tiedRuns([0: rattleBand, 1: rattleBand, 2: rattleBand]), counterpart: nil)
        let rattle = try #require(report.findings.first { $0.kind == .rattle })
        #expect(rattle.confidence == .medium)
        #expect(rattle.basis.text == "3 of 3 runs")
        #expect(rattle.confidenceStatement == "Inferred, medium confidence. It came back at the same place every run, but from one microphone position I can't rule out the room or something near the speaker vibrating.")
    }

    /// What the listening session heard of the same rattle played from another device
    /// (`ResoniqAudioTests.ExternalSweepTiedTests`): every run marked at about 121–469 Hz. The report says so as for a
    /// normal test, and says the sound came from another device.
    @Test func `a rattle heard while another device played is reported as a possible rattle`() throws {
        let band = SweepTiedSound(range: FrequencyRange(lower: 121, upper: 469))
        let report = SpeakerDiagnosis.diagnose(runs: tiedRuns([0: band, 1: band, 2: band]), counterpart: nil, source: .anotherDevice)
        let rattle = try #require(report.findings.first { $0.kind == .rattle })
        #expect(rattle.tag == .inferred)
        #expect(rattle.basis.text == "3 of 3 runs")
        #expect(rattle.headline == "Possible rattle at 120–470 Hz")
        #expect(report.source == .anotherDevice)
    }

    @Test func `in one run only it is dropped`() {
        let once = SpeakerDiagnosis.diagnose(runs: tiedRuns([1: rattleBand]), counterpart: nil)
        let never = SpeakerDiagnosis.diagnose(runs: tiedRuns([:]), counterpart: nil)
        #expect(once.findings == never.findings)
        #expect(once.verdict == never.verdict)
    }

    @Test func `at different places in two runs it is dropped`() {
        let apart = tiedRuns([0: rattleBand, 1: SweepTiedSound(range: FrequencyRange(lower: 2000, upper: 4000))])
        let report = SpeakerDiagnosis.diagnose(runs: apart, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .rattle })
    }

    @Test func `an invalid run's observation does not count`() {
        var runs = tiedRuns([0: rattleBand])
        runs.append(Bench.clippedRun.adding(sweepTiedSound: rattleBand))
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .rattle })
    }

    @Test func `over a measured buzz it is one finding with both pieces of evidence`() throws {
        let band = SweepTiedSound(range: FrequencyRange(lower: 1100, upper: 1800))
        let runs = tiedRuns([0: band, 1: band]) { Handmade.midBuzz(measurable: true) }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .rattle })
        let buzz = try #require(report.findings.first { $0.kind == .distortion })
        let plain = try #require(SpeakerDiagnosis.diagnose(runs: tiedRuns([:]) { Handmade.midBuzz(measurable: true) }, counterpart: nil)
            .findings.first { $0.kind == .distortion })
        #expect(buzz.tag == plain.tag && buzz.basis == plain.basis && buzz.headline == plain.headline)
        #expect(buzz.detail == plain.detail + " I also heard sound tied to the test tone there in 2 of 3 runs.")
        let evidence = try #require(buzz.sweepTied)
        #expect(evidence.runsHeard == 2 && evidence.runsCompared == 3)
        #expect(evidence.statement == "I also heard sound tied to the test tone there in 2 of 3 runs.")
        #expect(plain.sweepTied == nil)
    }

    @Test func `the analyzer keeps the observation on the run, valid or not`() {
        let silent = RunAnalyzer.analyze(
            recording: [Float](repeating: 0, count: 4800), sweep: Bench.responseSweep, noiseFloor: Bench.noiseFloor(rms: 0.0001),
            sweepTiedSound: rattleBand
        )
        #expect(silent.record.sweepTiedSound == rattleBand)
        #expect(!silent.isValid)
        #expect(SweepTiedSound(lower: 92, upper: 433) == rattleBand)
        #expect(SweepTiedSound(lower: 0, upper: 433) == nil)
    }

    @Test func `a report with a rattle survives JSON, and a record without the field decodes`() throws {
        let data = try JSONEncoder().encode(Self.twoOfThree)
        #expect(try JSONDecoder().decode(SpeakerReport.self, from: data) == Self.twoOfThree)
        let plain = try storedForm(RunRecord(check: .silent, measurement: nil))
        #expect(!plain.contains("sweepTiedSound"))
        let decoded = try JSONDecoder().decode(RunRecord.self, from: Data(plain.utf8))
        #expect(decoded.sweepTiedSound == nil)
    }
}
