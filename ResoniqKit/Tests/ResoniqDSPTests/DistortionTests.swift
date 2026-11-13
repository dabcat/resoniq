import Foundation
import Testing
@testable import ResoniqDSP

@Suite struct HarmonicDistortionTests {
    static let sweep = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 2, sampleRate: 48000)

    static func analyse(_ speaker: SimulatedSpeaker, orders: [Int] = HarmonicDistortion.defaultOrders) -> SweepDistortion {
        let response = Deconvolution.impulseResponse(recording: speaker.record(sweep), sweep: sweep)
        return HarmonicDistortion.analyze(impulseResponse: response, sweep: sweep, orders: orders)
    }

    @Test func `a pure square law shows only the second harmonic, at a·A/2`() {
        let distortion = Self.analyse(SimulatedSpeaker(delaySamples: 2000, quadratic: 0.2))
        let expected = Float(20 * log10(0.2 * 0.25 / 2))  // −32.0 dB
        // Within an octave of the sweep's start the harmonic chirp's own start ripples it (0.6 dB at 50 Hz).
        let low = distortion.harmonics[2]!.decibels(at: 50) - distortion.fundamental.decibels(at: 50)
        #expect(abs(low - expected) < 1)
        for frequency in checkFrequencies(from: 100, to: 8000, perOctave: 2) {
            let second = distortion.harmonics[2]!.decibels(at: frequency) - distortion.fundamental.decibels(at: frequency)
            // 0.1 dB: measured error is under 0.05 dB; what is left is the sweep's spectral ripple at 2f and f.
            #expect(abs(second - expected) < 0.1, "h2 at \(frequency) Hz")
            // Nothing else: the third harmonic sits at the numerical floor, far below the second.
            let third = distortion.harmonics[3]!.decibels(at: frequency) - distortion.fundamental.decibels(at: frequency)
            #expect(third < expected - 40, "h3 at \(frequency) Hz")
            #expect(abs(distortion.thdPercent(at: frequency) - 2.5) < 0.1, "THD at \(frequency) Hz")
        }
    }

    @Test(arguments: [0.4, 1.6])
    func `a cubic law shows the third harmonic at b·A²/4 of the fundamental`(cubic: Double) {
        let distortion = Self.analyse(SimulatedSpeaker(delaySamples: 512.5, cubic: cubic))
        let amplitude = 0.25
        let ratio = (cubic * amplitude * amplitude / 4) / (1 + 0.75 * cubic * amplitude * amplitude)
        for frequency in checkFrequencies(from: 100, to: 5000, perOctave: 2) {
            let third = distortion.harmonics[3]!.decibels(at: frequency) - distortion.fundamental.decibels(at: frequency)
            #expect(abs(third - Float(20 * log10(ratio))) < 0.1, "h3 at \(frequency) Hz")
        }
    }

    @Test func `each harmonic is reported only where it lies inside the sweep`() {
        let distortion = Self.analyse(SimulatedSpeaker(quadratic: 0.1))
        for order in 2...5 {
            let top = distortion.harmonics[order]!.frequencies.last!
            let limit = Float(HarmonicDistortion.upperFrequency(order: order, sweep: Self.sweep))
            #expect(top <= limit && top > limit * 0.99, "order \(order)")
            #expect(distortion.harmonics[order]!.frequencies.first == distortion.fundamental.frequencies.first)
        }
        #expect(distortion.thd.frequencies.last! <= 10000)
        #expect(distortion.fundamental.frequencies.last! <= 20000)
    }

    @Test func `the fundamental is the windowed linear response`() {
        let response = Deconvolution.impulseResponse(recording: SimulatedSpeaker().record(Self.sweep), sweep: Self.sweep)
        let distortion = HarmonicDistortion.analyze(impulseResponse: response, sweep: Self.sweep)
        #expect(distortion.fundamental == response.frequencyResponse())
    }

    @Test func `a clean system reads as a low floor, not as distortion`() {
        let distortion = Self.analyse(SimulatedSpeaker(delaySamples: 100, noiseRMS: 0.001))
        // −60 dBFS noise against a 0.25 sweep leaves each harmonic window about 60 dB under the fundamental;
        // four of them sum to roughly 0.1–0.2 %. A real 1 % distortion would be five times this.
        for frequency in checkFrequencies(from: 100, to: 2000, perOctave: 1) {
            #expect(distortion.thdPercent(at: frequency) < 0.3, "at \(frequency) Hz")
        }
        // The sweep's energy falls 3 dB an octave, so the floor rises with the harmonics' frequency.
        #expect(distortion.thdPercent(at: 5000) < 0.6)
    }
}

@Suite struct ToneDistortionTests {
    static let sampleRate = 48000.0

    static func tone(
        _ frequency: Double,
        harmonics: [Int: Double] = [:],
        extra: [(frequency: Double, amplitude: Double)] = [],
        noiseRMS: Double = 0,
        seconds: Double = 1
    ) -> [Float] {
        let count = Int(seconds * sampleRate)
        var generator = SeededGenerator(state: 7)
        let noise = noiseRMS > 0 ? generator.noise(count: count, rms: noiseRMS) : [Double](repeating: 0, count: count)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            var value = 0.25 * sin(2 * Double.pi * frequency * time)
            for (order, amplitude) in harmonics {
                value += 0.25 * amplitude * sin(2 * Double.pi * frequency * Double(order) * time + 0.3 * Double(order))
            }
            for line in extra { value += line.amplitude * sin(2 * Double.pi * line.frequency * time) }
            return Float(value + noise[index])
        }
    }

    @Test(arguments: [100.0, 997.3, 3000.0])
    func `known harmonics give the known THD`(frequency: Double) {
        let result = ToneDistortion.analyze(
            recording: Self.tone(frequency, harmonics: [2: 0.01, 3: 0.005]),
            frequency: frequency,
            sampleRate: Self.sampleRate
        )
        // √(0.01² + 0.005²) = 1.118 %; without noise the only error is window leakage, far below 0.01 %.
        #expect(abs(result.thdPercent - 1.1180) < 0.005)
        #expect(abs(result.harmonicLevels[2]! - -40) < 0.05)
        #expect(abs(result.harmonicLevels[3]! - -46.02) < 0.05)
        #expect(result.harmonicLevels[4]! < -100)
        #expect(abs(result.thdPlusNoisePercent - result.thdPercent) < 0.005)
    }

    @Test func `harmonics are counted only below Nyquist`() {
        let result = ToneDistortion.analyze(recording: Self.tone(5000), frequency: 5000, sampleRate: Self.sampleRate)
        #expect(Set(result.harmonicLevels.keys) == [2, 3, 4])
    }

    @Test func `noise raises THD+N but not THD`() {
        // White noise at −60 dBFS against a 0.25 tone: √(1e-6 / 0.03125) = 0.566 % of the fundamental.
        let result = ToneDistortion.analyze(
            recording: Self.tone(1000, harmonics: [2: 0.01], noiseRMS: 0.001),
            frequency: 1000,
            sampleRate: Self.sampleRate
        )
        // THD: the noise share is subtracted, so it stays within the noise's own scatter of 1 %.
        #expect(abs(result.thdPercent - 1) < 0.03)
        let expected = (0.01 * 0.01 + 1e-6 / 0.03125).squareRoot() * 100
        #expect(abs(Double(result.thdPlusNoisePercent) - expected) < 0.02)
    }

    @Test func `steady noise and harmonics leave no non-harmonic residue`() {
        let result = ToneDistortion.analyze(
            recording: Self.tone(1000, harmonics: [2: 0.01, 3: 0.005], noiseRMS: 0.001),
            frequency: 1000,
            sampleRate: Self.sampleRate
        )
        // The noise is at −45 dB re the tone; its estimate is good to a few per cent, so what is left is
        // below −60 dB.
        #expect(result.nonHarmonicResidue < -60)
    }

    @Test func `a non-harmonic line shows as residue at its level`() {
        let result = ToneDistortion.analyze(
            recording: Self.tone(1000, harmonics: [2: 0.01], extra: [(1370, 0.25 * 0.003)], noiseRMS: 0.001),
            frequency: 1000,
            sampleRate: Self.sampleRate
        )
        // 0.3 % of the fundamental: −50.5 dB. 0.5 dB: the noise in the line's bins and the floor estimate.
        #expect(abs(result.nonHarmonicResidue - -50.46) < 0.5)
        #expect(abs(result.thdPercent - 1) < 0.03)
    }

    @Test func `a buzz of clicks on each cycle raises the residue`() {
        let frequency = 100.0
        let clean = Self.tone(frequency, noiseRMS: 0.001)
        var buzzing = clean
        // A short click at every peak, like a voice coil touching: periodic, so mostly high-order harmonics.
        for start in stride(from: 120, to: buzzing.count - 4, by: 480) {
            for offset in 0..<3 { buzzing[start + offset] += offset == 1 ? -0.02 : 0.01 }
        }
        let quiet = ToneDistortion.analyze(recording: clean, frequency: frequency, sampleRate: Self.sampleRate)
        let buzz = ToneDistortion.analyze(recording: buzzing, frequency: frequency, sampleRate: Self.sampleRate)
        #expect(buzz.nonHarmonicResidue > quiet.nonHarmonicResidue + 20)
        #expect(buzz.nonHarmonicResidue > -50)
    }
}
