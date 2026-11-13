import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// The app's simulated left speaker (`SimulatedSpeaker.buzzingBookshelf`, which `AudioEnvironment` plays in the
/// simulator) must buzz loudly enough, over a wide enough band, for the diagnosis to report it: the demo flow ends on
/// "Possible buzz at 100–160 Hz". This target cannot import ResoniqDiagnostics, so the diagnosis's rule is restated
/// from `DiagnosisThresholds.standard`: THD smoothed to 1/12 octave (`distortionSmoothingFraction`), measurable
/// (`SweepDistortion.isMeasurable`), over 10 % (`distortionPercent`) for at least 1/6 octave
/// (`minimumDistortionOctaves`), in every run. The defect it replaced (cubic 40 over 100–160 Hz) peaked at 10.7 % and
/// stayed over 10 % for about 0.15 octave, so the app showed "Sounds healthy.".
@MainActor
@Suite(.timeLimit(.minutes(3))) struct DemoSpeakerTests {
    static let smoothingFraction = 12
    static let buzzPercent: Float = 10
    static let minimumOctaves: Float = 1.0 / 6

    @Test func `the demo speaker buzzes measurably over 100–160 Hz and nowhere else`() async throws {
        // The app's configuration (`AudioEnvironment.simulatedConfiguration`), paced at once.
        let io = SimulatedAudioIO(configuration: .init(left: .buzzingBookshelf, right: .bookshelf, pacing: .immediate))
        let session = Fixture.session(io: io, channel: .left)
        let final = await session.run()
        let result = try #require(final.result, "ended \(final)")
        #expect(result.sweep == LogSweep.measurement(sampleRate: Fixture.sampleRate))
        #expect(result.runs.count == 3)

        for run in result.runs {
            let impulse = Deconvolution.impulseResponse(recording: run.samples, sweep: result.sweep)
            let raw = HarmonicDistortion.analyze(impulseResponse: impulse, sweep: result.sweep)
            let distortion = SweepDistortion(
                fundamental: raw.fundamental,
                harmonics: raw.harmonics,
                thd: Smoothing.fractionalOctave(raw.thd, fraction: Self.smoothingFraction),
                noiseFloor: raw.noiseFloor
            )
            // The widest unbroken stretch where THD is measured over the threshold.
            var widest: (lower: Float, upper: Float)?
            var start: Float?
            var previous: Float = 0
            for frequency in distortion.thd.frequencies where frequency <= 1000 {
                let over = distortion.isMeasurable(at: frequency) && distortion.thdPercent(at: frequency) >= Self.buzzPercent
                if over, start == nil { start = frequency }
                if !over, let lower = start {
                    if log2(previous / lower) > log2((widest?.upper ?? 1) / (widest?.lower ?? 1)) { widest = (lower, previous) }
                    start = nil
                }
                previous = frequency
            }
            let band = try #require(widest, "run \(run.run): no measured THD over \(Self.buzzPercent) %")
            let peak = distortion.thd.frequencies.filter { (100...160).contains($0) }.map(distortion.thdPercent(at:)).max() ?? 0
            print("demo run \(run.run): THD over 10 % from \(band.lower) to \(band.upper) Hz, peak \(peak) %")
            #expect(log2(band.upper / band.lower) >= Self.minimumOctaves * 2)
            #expect(band.lower <= 110 && band.upper >= 150)
            #expect(peak >= 15)
            // Clean away from the defect.
            #expect(distortion.thdPercent(at: 400) < 1)
            #expect(distortion.thdPercent(at: 2000) < 1)
        }
    }
}
