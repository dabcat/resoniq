import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

// The bottom of the woofer's range. A natural roll-off (the response falling steadily below a knee at or under
// `DiagnosisThresholds.rollOffUpperFrequency`) is normal: the woofer is judged from the knee up, and the roll-off is
// a plain measured line in the even statement. A driver that is still neither even nor named by any finding is not
// passed over silently under "Sounds healthy.": it is left out with its reasons and the verdict hedges.
// Found when the app's simulated bookshelf (a woofer high-passed at 70 Hz) reported "Tweeter and mid are even" and
// "Sounds healthy." with no word on the woofer.

/// `Bench.healthy` with its bass high-passed (second order) at `frequency` instead of 45 Hz.
func rollingOff(at frequency: Double) -> SimulatedSpeaker {
    var speaker = Bench.healthy
    speaker.filters = [Biquad.highPass(frequency: frequency, q: 0.707, sampleRate: Bench.sampleRate)]
    return speaker
}

@Suite struct RollOffTests {
    /// Rolling off below 70 Hz, as the app's simulated bookshelf (its clean right speaker) does.
    static let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(rollingOff(at: 70), seed: 71), counterpart: nil)

    @Test func `a natural roll-off is healthy and said plainly`() throws {
        let report = Self.report
        #expect(report.verdict == "Sounds healthy.")
        #expect(report.suspectedDefects.isEmpty)
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.tag == .measured)
        #expect(even.bands == [.tweeter, .middle, .woofer])
        #expect(even.detail.hasPrefix("It stays within 3 dB from 70 Hz to 14 kHz. Bass rolls off below 70 Hz."))
        #expect(even.detail.contains("I couldn't check for distortion below 80 Hz."))
        #expect(!even.detail.contains("isn't in this"))
    }

    /// The two rules at the bottom of the woofer meet at `rollOffUpperFrequency` (100 Hz), where the quiet-band rule
    /// starts reading the woofer's level: a knee at or under it is a roll-off; above it the bass is judged as it is,
    /// as uneven (the hedge) or, 15 dB down, as barely heard. Never silent, never both.
    @Test func `a knee at 90 Hz is a roll-off, at 120 Hz it is not`() throws {
        #expect(DiagnosisThresholds.standard.rollOffUpperFrequency == DiagnosisThresholds.standard.quietBandLowerFrequency)
        let low = SpeakerDiagnosis.diagnose(runs: Bench.runs(rollingOff(at: 90), seed: 75), counterpart: nil)
        #expect(low.verdict == "Sounds healthy.")
        let lowEven = try #require(low.findings.first { $0.kind == .even })
        #expect(lowEven.detail.contains("Bass rolls off below 90 Hz."))
        #expect(!low.findings.contains { $0.kind == .quietBand })

        let high = SpeakerDiagnosis.diagnose(runs: Bench.runs(rollingOff(at: 120), seed: 77), counterpart: nil)
        #expect(high.verdict == "The tweeter and mid sound healthy; the woofer isn't clearly even, but I found no fault in it.")
        let highEven = try #require(high.findings.first { $0.kind == .even })
        #expect(!highEven.detail.contains("rolls off"))
        #expect(highEven.detail.contains("The woofer isn't in this: around 50–"))
        #expect(!high.findings.contains { $0.kind == .quietBand })
    }

    @Test func `a woofer with no output is barely heard, not a roll-off`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: UnheardBandTests.noWoofer, counterpart: nil)
        #expect(report.verdict == "Sounds healthy, except I could barely hear the woofer.")
        #expect(report.findings.contains { $0.kind == .quietBand && $0.band == .woofer })
        #expect(!report.findings.contains { $0.detail.contains("rolls off") })
    }

    /// A dip that comes back below it is not a roll-off, whatever lies under it.
    @Test func `a dip that recovers lower down is not a roll-off`() throws {
        var speaker = Bench.healthy
        speaker.filters = [
            Biquad.highPass(frequency: 30, q: 0.707, sampleRate: Bench.sampleRate),
            Biquad.peaking(frequency: 70, q: 3, gain: -9, sampleRate: Bench.sampleRate),
        ]
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker, seed: 79), counterpart: nil)
        #expect(!report.findings.contains { $0.detail.contains("rolls off") })
        #expect(report.findings.contains { $0.kind == .responseDip && $0.band == .woofer })
    }

    /// The knee on hand-made curves: a steady fall below 70 Hz is a roll-off; the same bottom with the response falling
    /// again going up (a dip at 60 Hz merging into it) is not; a fall that ends above 100 Hz is not.
    @Test func `the knee needs a steady fall that ends by 100 Hz`() {
        let thresholds = DiagnosisThresholds.standard
        let grid = ResponseGrid.frequencies
        func knee(_ curve: (Float) -> Float) -> Float? {
            let consensus = grid.map(curve)
            let deviation = Trend.deviation(of: consensus, thresholds: thresholds)
            let assessed = [Bool](repeating: true, count: grid.count)
            return SpeakerDiagnosis.rollOffKnee(consensus: consensus, deviation: deviation, assessed: assessed, thresholds: thresholds)
                .map { grid[$0] }
        }
        // 12 dB per octave below the corner.
        func rollOff(_ corner: Float) -> (Float) -> Float { { $0 < corner ? -12 * log2(corner / $0) : 0 } }
        let steady = knee(rollOff(70))
        #expect(steady.map { (55...75).contains($0) } ?? false)
        let notched = knee { frequency in rollOff(70)(frequency) - 6 * exp(-pow(log2(frequency / 60) / 0.1, 2)) }
        #expect(notched == nil)
        #expect(knee(rollOff(160)) == nil)
    }
}

@Suite struct UnclearedDriverTests {
    /// A 5 dB rise from about 100 to 250 Hz above a normal roll-off: 3–6 dB off the trend, neither even nor a peak.
    @Test func `a woofer 3–6 dB off its trend above the knee is the hedge`() throws {
        var speaker = rollingOff(at: 70)
        speaker.filters.append(Biquad.peaking(frequency: 160, q: 0.9, gain: 5, sampleRate: Bench.sampleRate))
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker, seed: 83), counterpart: nil)
        #expect(report.suspectedDefects.isEmpty)
        #expect(report.verdict == "The tweeter and mid sound healthy; the woofer isn't clearly even, but I found no fault in it.")
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.bands == [.tweeter, .middle])
        #expect(even.detail.contains("Bass rolls off below 70 Hz."))
        #expect(even.detail.contains("The woofer isn't in this: around "))
        #expect(even.detail.contains("dB off the notes around it."))
        #expect(even.detail.contains("I couldn't check it for distortion below 80 Hz."))
    }

    /// A buzz too narrow to report (over 10 % for less than `minimumDistortionOctaves`) keeps its driver out of the even
    /// statement, said as what was measured, short of a buzz, never as "under 10 %".
    @Test func `distortion over the threshold but short of a buzz is said as read`() throws {
        var speaker = rollingOff(at: 70)
        speaker.distortionBand = 123...134
        speaker.bandQuadratic = 1.6
        speaker.bandCubic = 8
        speaker.bandFadeOctaves = 1.0 / 48
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker, seed: 73), counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .distortion })
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.bands == [.tweeter, .middle])
        #expect(even.detail.contains("The woofer isn't in this: its distortion reached"))
        #expect(even.detail.contains("short of what I'd call a buzz."))
        #expect(report.verdict == "The tweeter and mid sound healthy; the woofer isn't clearly even, but I found no fault in it.")
    }

    @Test func `the verdict names drivers that are neither even nor faulty`() {
        #expect(DiagnosisText.verdict(suspected: [], uncleared: [.woofer])
            == "The tweeter and mid sound healthy; the woofer isn't clearly even, but I found no fault in it.")
        #expect(DiagnosisText.verdict(suspected: [], uncleared: [.middle, .woofer])
            == "The tweeter sounds healthy; the mid and woofer aren't clearly even, but I found no fault in them.")
        #expect(DiagnosisText.verdict(suspected: [], uncleared: DriverBand.allCases.reversed())
            == "I found no fault, but the tweeter, mid and woofer aren't clearly even.")
        #expect(DiagnosisText.verdict(suspected: [], unchecked: [.woofer], checked: [.tweeter, .middle], uncleared: [.middle])
            == "The tweeter sounds healthy; I couldn't check the woofer, and the mid isn't clearly even, but I found no fault in it.")
        // Unchanged without such a driver.
        #expect(DiagnosisText.verdict(suspected: []) == "Sounds healthy.")
        #expect(DiagnosisText.verdict(suspected: [], unchecked: [.woofer], checked: [.tweeter, .middle])
            == "The tweeter and mid sound healthy; I couldn't check the woofer.")
    }
}

@Suite struct MeasurementSweepBuzzTests {
    /// The app's sweep (10 Hz–22 kHz over 4 s), not the suite's 3 s one: a buzz of about 20 % confined to 100–160 Hz,
    /// the debug fixture's case, is found with it too.
    @Test func `a buzz at 100–160 Hz is found with the measurement sweep`() throws {
        var speaker = Bench.healthy
        speaker.distortionBand = 100...160
        speaker.bandQuadratic = 1.6
        speaker.bandCubic = 8
        let sweep = LogSweep.measurement(sampleRate: Bench.sampleRate)
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker, seed: 81, sweep: sweep), counterpart: nil)
        let buzz = try #require(report.findings.first { $0.kind == .distortion })
        #expect(buzz.headline == "Possible buzz at 100–160 Hz")
        #expect(buzz.basis.text == "3 of 3 runs")
        #expect(report.verdict == "Sounds healthy, except the woofer may be buzzing.")
    }

    /// The demo's buzz over a 70 Hz roll-off, as the app's left speaker: still the buzz, the roll-off changing nothing.
    @Test func `a buzz over a roll-off is still the buzz`() throws {
        var speaker = rollingOff(at: 70)
        speaker.distortionBand = 100...160
        speaker.bandQuadratic = 1.6
        speaker.bandCubic = 8
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker, seed: 85), counterpart: nil)
        #expect(report.verdict == "Sounds healthy, except the woofer may be buzzing.")
    }
}
