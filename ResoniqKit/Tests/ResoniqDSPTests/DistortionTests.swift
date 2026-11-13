import Accelerate
import Testing
@testable import ResoniqDSP

@Suite struct HarmonicDistortionTests {
    static let sweep = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 3, sampleRate: 48000)

    static func analyse(_ speaker: SimulatedSpeaker, sweep: LogSweep = sweep, orders: [Int] = HarmonicDistortion.defaultOrders) -> SweepDistortion {
        let response = Deconvolution.impulseResponse(recording: speaker.record(sweep), sweep: sweep)
        return HarmonicDistortion.analyze(impulseResponse: response, sweep: sweep, orders: orders)
    }

    /// Check points inside harmonic `order`'s trusted band.
    static func inside(order: Int, sweep: LogSweep = sweep, perOctave: Int = 2) -> [Float] {
        let band = HarmonicDistortion.trustedBand(order: order, sweep: sweep)!
        return checkFrequencies(from: Float(band.lowerBound), to: Float(band.upperBound), perOctave: perOctave)
    }

    @Test func `a pure square law shows only the second harmonic, at a·A/2`() {
        let distortion = Self.analyse(SimulatedSpeaker(delaySamples: 2000, quadratic: 0.2))
        let expected = Float(20 * log10(0.2 * 0.25 / 2))  // −32.0 dB
        for frequency in Self.inside(order: 2) {
            let second = distortion.harmonics[2]!.decibels(at: frequency) - distortion.fundamental.decibels(at: frequency)
            #expect(abs(second - expected) < 0.25, "h2 at \(frequency) Hz")
            // Nothing else: the third harmonic sits at the numerical floor, far below the second.
            if Double(frequency) <= HarmonicDistortion.upperFrequency(order: 3, sweep: Self.sweep) {
                let third = distortion.harmonics[3]!.decibels(at: frequency) - distortion.fundamental.decibels(at: frequency)
                #expect(third < expected - 40, "h3 at \(frequency) Hz")
            }
        }
    }

    @Test(arguments: [0.4, 1.6])
    func `a cubic law shows the third harmonic at b·A²/4 of the fundamental`(cubic: Double) {
        let distortion = Self.analyse(SimulatedSpeaker(delaySamples: 512.5, cubic: cubic))
        let amplitude = 0.25
        let ratio = (cubic * amplitude * amplitude / 4) / (1 + 0.75 * cubic * amplitude * amplitude)
        for frequency in Self.inside(order: 3) {
            let third = distortion.harmonics[3]!.decibels(at: frequency) - distortion.fundamental.decibels(at: frequency)
            #expect(abs(third - Float(20 * log10(ratio))) < 0.25, "h3 at \(frequency) Hz")
        }
    }

    // The shortest accurate sweep from 20 Hz and from 10 Hz, and the measurement sweep.
    @Test(arguments: [(20.0, 20000.0, 3.0), (10.0, 22000.0, 3.0), (10.0, 22000.0, 4.0)])
    func `THD is within 3 % of its value across the trusted band`(start: Double, end: Double, duration: Double) {
        // A pure square law at the sweep's 0.25: THD is the second harmonic alone, 2.50 % at every frequency.
        // Every point of the curve is held to the stated accuracy. A 2 s sweep from 20 Hz used to read 1.73 % at
        // 20 Hz and 2.13 % at 25 Hz.
        let sweep = LogSweep(startFrequency: start, endFrequency: end, duration: duration, sampleRate: 48000)
        let distortion = Self.analyse(SimulatedSpeaker(delaySamples: 2000, quadratic: 0.2, tailSeconds: 0.5), sweep: sweep)
        let band = HarmonicDistortion.trustedBand(order: 2, sweep: sweep)!
        #expect(Double(distortion.thd.frequencies.first!) >= band.lowerBound)
        #expect(Double(distortion.thd.frequencies.last!) <= band.upperBound)
        let worst = distortion.thd.frequencies.map { abs(distortion.thdPercent(at: $0) / 2.5 - 1) }.max() ?? 1
        #expect(worst < 0.03, "worst \(100 * worst) % of the value")
    }

    @Test func `a short sweep's top harmonic band stops below its fade`() {
        // On a 1 s sweep the 20 ms fade-out spans 17.4–20 kHz. The second harmonic of 8.8 kHz fell in it and read
        // 18 % off; the band now ends below it, and from 1 kHz to there the reading holds.
        let short = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 1, sampleRate: 48000)
        let distortion = Self.analyse(SimulatedSpeaker(delaySamples: 2000, quadratic: 0.2), sweep: short)
        let top = distortion.thd.frequencies.last!
        #expect(top < 8000)
        let worst = distortion.thd.frequencies.filter { $0 >= 1000 }.map { abs(distortion.thdPercent(at: $0) / 2.5 - 1) }.max() ?? 1
        #expect(worst < 0.03, "worst \(100 * worst) %")
    }

    @Test func `each harmonic is reported only inside its trusted band`() {
        let distortion = Self.analyse(SimulatedSpeaker(quadratic: 0.1))
        for order in 2...5 {
            let band = HarmonicDistortion.trustedBand(order: order, sweep: Self.sweep)!
            let frequencies = distortion.harmonics[order]!.frequencies
            #expect(Double(frequencies.first!) >= band.lowerBound && Double(frequencies.first!) < band.lowerBound * 1.01)
            #expect(Double(frequencies.last!) <= band.upperBound && Double(frequencies.last!) > band.upperBound * 0.99, "order \(order)")
        }
        #expect(distortion.thd.frequencies.last! <= 10000)
        #expect(distortion.fundamental.frequencies.last! <= 20000)
        // Outside the band there is no number.
        #expect(distortion.thdPercent(at: 30).isNaN)
        #expect(!distortion.isMeasurable(at: 30))
    }

    @Test func `the fundamental is the speaker's linear response`() {
        // Checked against the biquad's own magnitude, not against another output of the module.
        let filter = Biquad.peaking(frequency: 3000, q: 1.4, gain: 6, sampleRate: 48000)
        let distortion = Self.analyse(SimulatedSpeaker(delaySamples: 800.5, filters: [filter]))
        for frequency in checkFrequencies(from: 100, to: 16000, perOctave: 6) {
            let expected = Float(20 * log10(filter.magnitude(at: Double(frequency), sampleRate: 48000)))
            #expect(abs(distortion.fundamental.decibels(at: frequency) - expected) < 0.05, "at \(frequency) Hz")
        }
    }

    @Test func `a clean system reads as a low floor, not as distortion`() {
        let distortion = Self.analyse(SimulatedSpeaker(delaySamples: 100, noiseRMS: 0.001))
        // −60 dBFS noise against a 0.25 sweep leaves each harmonic window about 60 dB under the fundamental;
        // four of them sum to roughly 0.1–0.2 %. A real 1 % distortion would be five times this.
        for frequency in checkFrequencies(from: 200, to: 2000, perOctave: 1) {
            #expect(distortion.thdPercent(at: frequency) < 0.3, "at \(frequency) Hz")
            #expect(!distortion.isMeasurable(at: frequency), "at \(frequency) Hz")
        }
        // The sweep's energy falls 3 dB an octave, so the floor rises with the harmonics' frequency.
        #expect(distortion.thdPercent(at: 5000) < 0.6)
    }
}

/// Finding 1 of the review: noise read as distortion. The floor tells a caller which.
@Suite struct DistortionNoiseFloorTests {
    static let sweep = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 3, sampleRate: 48000)

    /// A speaker at 0.3 of the sweep with white noise `snr` dB under the recording's RMS, as `RecordingQuality`
    /// measures it, and half a second of tail.
    static func analyse(quadratic: Double = 0, snr: Double, tail: Double = 0.5) -> SweepDistortion {
        let clean = SimulatedSpeaker(delaySamples: 2000, quadratic: quadratic, tailSeconds: tail).record(sweep).map { $0 * 0.3 }
        let rms = Double(LevelMeter.measure(clean).rms)
        var generator = SeededGenerator(state: 11)
        let noisy = zip(clean, generator.noise(count: clean.count, rms: rms / pow(10, snr / 20))).map { $0 + Float($1) }
        let response = Deconvolution.impulseResponse(recording: noisy, sweep: sweep)
        return HarmonicDistortion.analyze(impulseResponse: response, sweep: sweep)
    }

    static let checks = checkFrequencies(from: 150, to: 8000, perOctave: 3)

    @Test func `noise 20 dB under the recording reads as THD but is not measurable`() throws {
        // The review's case: a perfectly clean speaker, noise at the 20 dB pass mark. THD reads 2.2 % at 1 kHz and
        // 4.9 % at 3 kHz, all of it noise. The floor says so.
        let distortion = Self.analyse(snr: 20)
        #expect(distortion.thdPercent(at: 1000) > 1)
        for frequency in Self.checks {
            #expect(!distortion.isMeasurable(at: frequency), "at \(frequency) Hz")
            // What a caller can say instead: below the floor plus the margin, which is above what THD read.
            let floor = try #require(distortion.noiseFloorPercent(at: frequency))
            let bound = floor * Decibels.toAmplitude(SweepDistortion.measurableMarginDecibels)
            #expect(distortion.thdPercent(at: frequency) < bound, "at \(frequency) Hz")
        }
    }

    @Test func `the floor matches what the harmonic windows collect, on average`() throws {
        // Smoothed over a third of an octave, a noise-only THD and the floor agree within 1 dB everywhere: the floor
        // is measured with the same windows, on the same noise.
        let distortion = Self.analyse(snr: 30)
        let floor = try #require(distortion.noiseFloor)
        let smoothed = Smoothing.fractionalOctave(distortion.thd, fraction: 3)
        for frequency in Self.checks {
            #expect(abs(smoothed.decibels(at: frequency) - floor.decibels(at: frequency)) < 1, "at \(frequency) Hz")
        }
    }

    @Test func `real distortion well above the floor is measured, and its value holds`() {
        // 2.5 % of second harmonic with noise 40 dB under: the floor is a tenth of that, so THD is measured.
        let distortion = Self.analyse(quadratic: 0.2, snr: 40)
        // A single point carries the noise's random phase; averaged over a third of an octave, gross THD is
        // √(2.5² + floor²), within 3 %.
        let smoothed = Smoothing.fractionalOctave(distortion.thd, fraction: 3)
        for frequency in Self.checks where Double(frequency) <= HarmonicDistortion.upperFrequency(order: 2, sweep: Self.sweep) {
            #expect(distortion.isMeasurable(at: frequency), "at \(frequency) Hz")
            let floor = distortion.noiseFloorPercent(at: frequency) ?? 0
            let expected = (2.5 * 2.5 + floor * floor).squareRoot()
            let measured = 100 * Decibels.toAmplitude(smoothed.decibels(at: frequency))
            #expect(abs(measured / expected - 1) < 0.03, "at \(frequency) Hz: \(measured) % against \(expected) %")
        }
    }

    @Test func `the same distortion under more noise is measured where it can be and not where it cannot`() {
        // 30 dB under: the floor rises with frequency, about 0.5 % at 500 Hz and 1.7 % at 4 kHz. 2.5 % stands 14 dB
        // clear of it at 500 Hz and only 3 dB at 4 kHz. Each point scatters with the noise, so count the points.
        let distortion = Self.analyse(quadratic: 0.2, snr: 30)
        func measuredShare(_ range: ClosedRange<Float>) -> Double {
            let points = distortion.thd.frequencies.filter { range.contains($0) }
            return Double(points.filter { distortion.isMeasurable(at: $0) }.count) / Double(points.count)
        }
        #expect(measuredShare(400...700) > 0.9)
        #expect(measuredShare(3000...5000) < 0.1)
    }

    @Test func `a recording that stops right after the sweep has no floor and measures nothing`() {
        let distortion = Self.analyse(quadratic: 0.2, snr: 40, tail: 0.1)
        #expect(distortion.noiseFloor == nil)
        #expect(!distortion.isMeasurable(at: 1000))
        // THD itself is still reported; it is only not known to be above the noise.
        #expect(distortion.thdPercent(at: 1000).isFinite)
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

    /// A tone at `frequency · (1 + ppm·10⁻⁶)`: the playback clock running fast against the recording's.
    static func offsetTone(_ frequency: Double, ppm: Double, seconds: Double) -> [Float] {
        let step = 2 * Double.pi * frequency * (1 + ppm * 1e-6) / sampleRate
        let phase = vDSP.ramp(withInitialValue: 0, increment: step, count: Int(seconds * sampleRate))
        let tone = vDSP.add(vForce.sin(phase), vDSP.add(
            vDSP.multiply(0.02, vForce.sin(vDSP.multiply(2, phase))),
            vDSP.multiply(0.01, vForce.sin(vDSP.multiply(5, phase)))
        ))
        return vDSP.doubleToFloat(vDSP.multiply(0.25, tone))
    }

    @Test(arguments: [(3000.0, 100.0, 10.0), (3000.0, 50.0, 4.0), (1000.0, 100.0, 10.0), (3000.0, 0.0, 1.0)])
    func `a clock offset does not lose the harmonics`(frequency: Double, ppm: Double, seconds: Double) throws {
        // √(2² + 1²) % = 2.236 %. With the lobes at the nominal multiples, a 100 ppm offset on a 10 s, 3 kHz tone read
        // 1.38 %, lost the fifth harmonic (15 kHz is 1.5 Hz off, 15 resolution bins) and raised the residue from
        // −90 to −35 dB, which looks like rub and buzz.
        let result = ToneDistortion.analyze(recording: Self.offsetTone(frequency, ppm: ppm, seconds: seconds), frequency: frequency, sampleRate: Self.sampleRate)
        let located = try #require(result.fundamentalFrequency)
        // Located to within a fiftieth of the recording's resolution, 1 / seconds hertz.
        #expect(abs(located - frequency * (1 + ppm * 1e-6)) < 0.02 / seconds, "located \(located) Hz")
        #expect(abs(result.thdPercent - 2.2361) < 0.01)
        #expect(abs(try #require(result.harmonicLevels[5]) - -40) < 0.1)
        #expect(result.nonHarmonicResidue < -80)
    }

    @Test func `silence finds no tone and does not trap`() {
        let result = ToneDistortion.analyze(recording: [Float](repeating: 0, count: 48000), frequency: 1000, sampleRate: Self.sampleRate)
        #expect(!result.isToneFound)
        #expect(result.thdPercent.isNaN && result.thdPlusNoisePercent.isNaN)
        #expect(!result.isMeasurable)
    }

    @Test func `noise alone finds no tone instead of reading 265 %`() {
        var generator = SeededGenerator(state: 2)
        let noise = generator.noise(count: 48000, rms: 0.001).map(Float.init)
        let result = ToneDistortion.analyze(recording: noise, frequency: 1000, sampleRate: Self.sampleRate)
        #expect(!result.isToneFound)
        #expect(result.thdPercent.isNaN)
        #expect(result.harmonicLevels.isEmpty)
    }

    @Test(arguments: [0, 1, 400])
    func `a recording too short to resolve the tone finds none and does not trap`(count: Int) {
        let result = ToneDistortion.analyze(recording: [Float](repeating: 0.1, count: count), frequency: 1000, sampleRate: Self.sampleRate)
        #expect(!result.isToneFound)
    }

    @Test(arguments: [Float.nan, .infinity])
    func `a corrupt recording finds no tone`(value: Float) {
        var recording = Self.tone(1000, harmonics: [2: 0.01])
        recording[100] = value
        #expect(!ToneDistortion.analyze(recording: recording, frequency: 1000, sampleRate: Self.sampleRate).isToneFound)
    }

    @Test func `harmonics above the noise are measurable, a clean tone's are not`() {
        let distorted = ToneDistortion.analyze(recording: Self.tone(1000, harmonics: [2: 0.01], noiseRMS: 0.001), frequency: 1000, sampleRate: Self.sampleRate)
        #expect(distorted.isMeasurable)
        #expect(distorted.noiseFloorPercent < distorted.thdPercent)
        let clean = ToneDistortion.analyze(recording: Self.tone(1000, noiseRMS: 0.001), frequency: 1000, sampleRate: Self.sampleRate)
        #expect(clean.isToneFound)
        #expect(!clean.isMeasurable)
        // What can be said instead: THD is below the floor raised by the margin.
        #expect(clean.thdPercent < clean.noiseFloorPercent * Decibels.toAmplitude(SweepDistortion.measurableMarginDecibels))
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
