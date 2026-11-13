import Foundation
import Testing
@testable import ResoniqDSP

/// The phase's "Done when": a sweep played through a simulated speaker, recorded with an unknown delay and noise,
/// gives back the speaker's response and distortion.
@Suite struct EndToEndTests {
    static let sampleRate = 48000.0
    static let sweep = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 3, sampleRate: sampleRate)
    /// A 2nd-order high-pass at 80 Hz and a +6 dB bell at 2 kHz, then y = x + 0.16·x² + 0.32·x³ (about 2 % THD
    /// at the sweep's 0.25 peak), then white noise at −60 dBFS, recorded 0.15 s late with half a second after.
    static let speaker = SimulatedSpeaker(
        delaySamples: 7213.37,
        filters: [
            Biquad.highPass(frequency: 80, q: 0.707, sampleRate: sampleRate),
            Biquad.peaking(frequency: 2000, q: 1.4, gain: 6, sampleRate: sampleRate),
        ],
        quadratic: 0.16,
        cubic: 0.32,
        noiseRMS: 0.001,
        tailSeconds: 0.5,
        seed: 42
    )
    static let response = Deconvolution.impulseResponse(recording: speaker.record(sweep), sweep: sweep)

    @Test func `the delay is found`() {
        // The filters' own group delay at the peak is a fraction of a millisecond.
        #expect(abs(Self.response.delay - 7213.37 / Self.sampleRate) < 0.0005)
    }

    @Test func `the filter's magnitude response is recovered within 1 dB from 50 Hz to 16 kHz`() {
        let frequencies = checkFrequencies(from: 50, to: 16000, perOctave: 24)
        let expected = MagnitudeResponse(
            frequencies: frequencies,
            decibels: frequencies.map {
                // The cubic term puts ¾·b·A′³ back into the fundamental; the expected curve includes it.
                Float(20 * log10(Self.speaker.fundamentalGain(at: Double($0), amplitude: 0.25, sampleRate: Self.sampleRate)))
            }
        )
        let measured = ResponseComparison.levelMatched(Self.response.frequencyResponse(), to: expected)
        let error = ResponseComparison.difference(measured, expected)
        let inRange = zip(error.frequencies, error.decibels).filter { $0.0 >= 50 && $0.0 <= 16000 }
        let worst = inRange.map { abs($0.1) }.max() ?? .infinity
        print("end-to-end response: worst error \(worst) dB over \(inRange.count) points")
        #expect(worst < 1)
        // The response itself is far better than the plan's 1 dB; hold it to 0.25 dB so a regression shows.
        #expect(worst < 0.25)
    }

    @Test(arguments: [300.0, 500.0, 1000.0, 2000.0, 3000.0])
    func `the nonlinearity's THD is recovered within a quarter of its value`(frequency: Double) {
        let distortion = HarmonicDistortion.analyze(impulseResponse: Self.response, sweep: Self.sweep)
        let expected = 100 * Self.speaker.expectedTHD(at: frequency, amplitude: 0.25, sampleRate: Self.sampleRate)
        let measured = Double(distortion.thdPercent(at: Float(frequency)))
        print("end-to-end THD at \(frequency) Hz: measured \(measured) %, expected \(expected) %")
        #expect(abs(measured - expected) < expected / 4)
    }
}
