import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

// The defects an independent review found in the speaker diagnosis, each pinned by a test.

/// A valid run built by hand: a flat response at −12 dB with `response` added, clean THD from 80 Hz to 9 kHz, and
/// `signalToNoise(band centre)` dB in each octave band.
func handRun(response: (Float) -> Float = { _ in 0 }, signalToNoise: (Float) -> Float = { _ in 40 }) -> RunAnalysis {
    let grid = ResponseGrid.frequencies
    let levels = grid.map { -12 + response($0) }
    let bands = Handmade.bands
    let thd: [Float?] = grid.map { $0 >= 80 && $0 <= 9000 ? Decibels.fromAmplitude(0.01) : nil }
    let measurement = RunMeasurement(
        response: levels,
        referenceLevel: RunAnalyzer.referenceLevel(of: levels),
        responseBand: FrequencyRange(lower: 20, upper: 20000),
        thdDecibels: thd,
        thdMeasurable: thd.map { $0 != nil },
        thdNoiseFloorDecibels: thd.map { $0.map { _ in Decibels.fromAmplitude(0.0005) } },
        delay: 0.05,
        bandCentres: bands,
        bandSignalToNoise: bands.map(signalToNoise)
    )
    return RunAnalysis(verdict: .valid(level: Level(peak: 0.25, rms: 0.1, dcOffset: 0), signalToNoise: 30), measurement: measurement)
}

@Suite struct UnheardBandTests {
    /// No output below 500 Hz: a 24 dB/octave high-pass, about −54 dB at 100 Hz.
    static let noWoofer = Bench.runs(
        Bench.healthy(with: [
            Biquad.highPass(frequency: 500, q: 0.707, sampleRate: Bench.sampleRate),
            Biquad.highPass(frequency: 500, q: 0.707, sampleRate: Bench.sampleRate),
        ]),
        seed: 51,
        sweep: Bench.responseSweep
    )

    @Test func `a woofer that cannot be heard is a finding, not silence`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: Self.noWoofer, counterpart: nil)
        print("no woofer: \(report.verdict) | \(report.findings.map { "\($0.headline) [\($0.tagLine)]" })")
        #expect(report.verdict != "Sounds healthy.")
        let quiet = try #require(report.findings.first { $0.kind.rawValue == "quietBand" })
        #expect(quiet.band == .woofer)
        #expect(quiet.tag == .measured)
        #expect(quiet.kind.isDeviation)
        #expect(quiet.headline == "I could barely hear the woofer")
        #expect(quiet.detail.contains("the driver, its connection, or where the phone was"))
        let difference = try #require(quiet.numbers?.extreme)
        #expect(difference < -30)
        #expect(report.verdict == "Sounds healthy, except I could barely hear the woofer.")
        #expect(!(report.findings.first { $0.kind == .even }?.bands.contains(.woofer) ?? false))
    }

    @Test func `nothing assessed is not conclusive`() {
        let runs = (0..<3).map { _ in handRun(signalToNoise: { _ in 5 }) }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        print("all at 5 dB: \(report.verdict) conclusive \(report.isConclusive) | \(report.findings.map(\.headline))")
        #expect(!report.isConclusive)
        #expect(report.verdict == "The room was too loud against the speaker for me to judge it.")
        #expect(!report.verdict.contains("healthy"))
    }

    @Test func `a band too noisy to assess is said to be unchecked, and the verdict covers only the rest`() throws {
        // The 31.5, 63 and 125 Hz octave bands at 5 dB: the woofer's stretch from 50 to about 180 Hz.
        let runs = (0..<3).map { _ in handRun(signalToNoise: { $0 < 200 ? 5 : 40 }) }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        print("noisy bass: \(report.verdict) | \(report.findings.map(\.headline))")
        #expect(report.isConclusive)
        let unchecked = try #require(report.findings.first { $0.kind.rawValue == "notAssessed" })
        #expect(unchecked.band == .woofer)
        #expect(unchecked.tag == .inconclusive)
        #expect(unchecked.headline == "Couldn't check the woofer")
        #expect(report.verdict == "The tweeter and mid sound healthy; I couldn't check the woofer.")
    }
}

@Suite struct EvenStatementTests {
    @Test func `a 5.5 dB dip is not called even`() {
        let runs = (0..<3).map { _ in handRun(response: { bell($0, centre: 1000, gain: -5.5, width: 0.4) }) }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        let even = report.findings.first { $0.kind == .even }
        print("5.5 dB dip: \(report.findings.map(\.headline))")
        #expect(deviations(report).isEmpty)
        #expect(!(even?.bands.contains(.middle) ?? false))
    }

    @Test func `the even statement's range ends below a top-end dip, and says so`() throws {
        let runs = (0..<3).map { _ in handRun(response: { $0 > 13000 ? -12 * log2($0 / 13000) * 3 : 0 }) }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        let top = try #require(report.findings.first { $0.kind == .topEndDip })
        let even = try #require(report.findings.first { $0.kind == .even })
        print("top-end dip: \(report.findings.map { "\($0.headline): \($0.detail)" })")
        let evenRange = try #require(even.frequencyRange)
        let dipRange = try #require(top.frequencyRange)
        #expect(evenRange.upper <= dipRange.lower)
        #expect(even.detail.hasPrefix("It stays within 3 dB from 50 Hz to \(DiagnosisText.frequency(evenRange.upper))."))
    }
}

@Suite struct DeepBassDistortionTests {
    /// A 20 % buzz while the sweep plays 50–85 Hz: under the 80 Hz the second harmonic is trusted from.
    static let runs: [RunAnalysis] = {
        var speaker = Bench.healthy
        speaker.distortionBand = 50...85
        speaker.bandQuadratic = 1.6
        speaker.bandCubic = 8
        return Bench.runs(speaker, seed: 61)
    }()

    @Test func `distortion below 80 Hz is said to be unchecked`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: Self.runs, counterpart: nil)
        print("deep buzz: \(report.verdict) | \(report.findings.map { "\($0.headline): \($0.detail)" })")
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.detail.contains("I couldn't check for distortion below 80 Hz."))
    }
}

@Suite struct HedgedHeadlineTests {
    @Test func `a buzz is a possible buzz in every line`() throws {
        let buzz = try #require(DistortionTests.threeOfThree.findings.first { $0.kind == .distortion })
        #expect(buzz.headline == "Possible buzz at 80–110 Hz")
        #expect(buzz.sentence.hasPrefix("A possible buzz around"))
    }
}
