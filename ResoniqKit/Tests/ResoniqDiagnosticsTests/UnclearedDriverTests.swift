import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

// A driver that is neither called even nor named by any finding must not pass silently under "Sounds healthy.".
// Found when the app's simulated bookshelf speaker (a woofer high-passed at 70 Hz) reported "Tweeter and mid are even"
// and "Sounds healthy." with no word on the woofer: its bass roll-off sits 3–6 dB under the trend at 50–69 Hz, which
// is neither even nor a dip (a dip that runs into the bottom of the span is the bass rolling off).

@Suite struct UnclearedDriverTests {
    /// `Bench.healthy` with its woofer rolling off below 70 Hz instead of 45 Hz, as the app's simulated bookshelf does.
    static let rollingOff: SimulatedSpeaker = {
        var speaker = Bench.healthy
        speaker.filters = [Biquad.highPass(frequency: 70, q: 0.707, sampleRate: Bench.sampleRate)]
        return speaker
    }()

    static let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(rollingOff, seed: 71), counterpart: nil)

    @Test func `a woofer left out of the even statement is named in the verdict`() throws {
        let report = Self.report
        #expect(report.suspectedDefects.isEmpty)
        #expect(report.verdict == "The tweeter and mid sound healthy; the woofer isn't clearly even, but I found no fault in it.")
    }

    @Test func `the even statement says why the woofer is not in it`() throws {
        let even = try #require(Self.report.findings.first { $0.kind == .even })
        #expect(even.bands == [.tweeter, .middle])
        #expect(even.detail.contains("The woofer isn't in this: around 50–"))
        #expect(even.detail.contains("dB off the notes around it."))
        // THD is read from 80 Hz with this sweep; below it the woofer's distortion was not checked, and it says so.
        #expect(even.detail.contains("I couldn't check it for distortion below 80 Hz."))
    }

    /// A buzz too narrow to report (over 10 % for less than `minimumDistortionOctaves`) in a woofer left out of the even
    /// statement is said as what was measured, short of a buzz, never as "under 10 %".
    @Test func `distortion over the threshold but short of a buzz is said as read`() throws {
        var speaker = Self.rollingOff
        speaker.distortionBand = 123...134
        speaker.bandQuadratic = 1.6
        speaker.bandCubic = 8
        speaker.bandFadeOctaves = 1.0 / 48
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker, seed: 73), counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .distortion })
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.detail.contains("Its distortion reached"))
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
}
