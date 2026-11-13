import Accelerate
import Testing
@testable import ResoniqDSP

/// Fixtures for the room tests, each built without the code under test.
enum RoomFixture {
    static let sampleRate = 48000.0

    /// Gaussian white noise, seeded, kept only between `band`'s edges by zeroing every other bin of one transform
    /// (a brick wall, unlike the analysis's own filter).
    static func bandLimitedNoise(count: Int, band: ClosedRange<Double>, seed: UInt64) -> [Double] {
        var generator = SeededGenerator(state: seed)
        let noise = generator.noise(count: count, rms: 1).map(Float.init)
        let size = FFT.nextPowerOfTwo(count)
        let spectrum = FFT.forward(noise, size: size)
        // Bins whose frequency lies in the band, and their mirror images.
        var mask = [Float](repeating: 0, count: size)
        let low = Int((band.lowerBound * Double(size) / sampleRate).rounded(.up))
        let high = Int((band.upperBound * Double(size) / sampleRate).rounded(.down))
        for bin in low...high {
            mask[bin] = 1
            mask[size - bin] = 1
        }
        let kept = ComplexSpectrum(real: vDSP.multiply(spectrum.real, mask), imaginary: vDSP.multiply(spectrum.imaginary, mask))
        return vDSP.floatToDouble(FFT.inverse(kept).prefix(count))
    }

    /// Band-limited noise whose energy falls by 60 dB every `rt60` seconds: amplitude `10^(−3·t/rt60)`, starting
    /// at an RMS of `level`.
    static func decay(rt60: Double, band: ClosedRange<Double>, seconds: Double, level: Double = 1, seed: UInt64) -> [Double] {
        decays(rt60: rt60, band: band, seconds: seconds, level: level, count: 1, seed: seed)[0]
    }

    /// `count` independent decays, cut one after another from one long band-limited noise: pieces of band noise
    /// further apart than `1 / bandwidth` are uncorrelated, and one long transform is cheaper than many.
    static func decays(rt60: Double, band: ClosedRange<Double>, seconds: Double, level: Double = 1, count: Int, seed: UInt64) -> [[Double]] {
        let length = Int(seconds * sampleRate)
        let noise = bandLimitedNoise(count: length * count, band: band, seed: seed)
        // 10^(−3·t/rt60) = e^(−3·ln 10 · n / (rate · rt60)).
        let envelope = vForce.exp(vDSP.ramp(withInitialValue: 0, increment: -3 * log(10) / (sampleRate * rt60), count: length))
        return (0..<count).map { piece in
            let slice = Array(noise[(piece * length)..<((piece + 1) * length)])
            return vDSP.multiply(level / vDSP.rootMeanSquare(slice), vDSP.multiply(slice, envelope))
        }
    }

    /// A hand-built response: `positive` from time zero (the peak at index 0), then as many zeros for the negative
    /// half of the circular buffer.
    static func response(
        _ positive: [Double],
        trustedBand: ClosedRange<Double> = 20...20000
    ) -> ImpulseResponse {
        let samples = positive.map(Float.init) + [Float](repeating: 0, count: positive.count)
        return ImpulseResponse(
            samples: samples, sampleRate: sampleRate, peakIndex: 0,
            band: 10...22000, capturedBand: 10...22000, trustedBand: trustedBand, recordingDuration: nil
        )
    }

    /// Adds white noise of standard deviation `rms`.
    static func withNoise(_ signal: [Double], rms: Double, seed: UInt64) -> [Double] {
        var generator = SeededGenerator(state: seed)
        return zip(signal, generator.noise(count: signal.count, rms: rms)).map(+)
    }

    /// The edges of the base-ten octave centred on `centre`, computed here: `centre · 10^(∓0.15)`.
    static func octave(_ centre: Double) -> ClosedRange<Double> {
        centre * pow(10, -0.15)...centre * pow(10, 0.15)
    }

    /// The 60 dB decay time of a biquad's poles, from the radius `r = √a2`: the energy falls as `r^(2n)`, so
    /// 60 dB takes `n = −3·ln 10 / ln r` samples.
    static func poleDecayTime(_ filter: Biquad) -> Double {
        -3 * log(10) / log(filter.a2.squareRoot()) / sampleRate
    }
}

/// `Decay`: the room's decay time, from an impulse response.
@Suite struct DecayTests {
    /// The stated accuracy: 10 %. ISO 3382-2's engineering grade asks for 10 % in octave bands; a reading that
    /// good is all a phone microphone could hope for, and the synthetic decays here are exact, so whatever error
    /// there is belongs to the estimator (the noise's own fluctuation and the band filter).
    static let tolerance = 0.10

    @Test(arguments: [0.3, 0.6, 1.2])
    func `a known decay time is recovered`(rt60: Double) throws {
        let band = RoomFixture.octave(500)
        let signal = RoomFixture.decay(rt60: rt60, band: band, seconds: 3 * rt60 + 0.5, seed: 7)
        // Noise 70 dB under the decay's start, in the band, so the range is wide and T30 is used.
        let noisy = RoomFixture.withNoise(signal, rms: 1e-3, seed: 8)
        let estimate = try #require(Decay.estimate(impulseResponse: RoomFixture.response(noisy), band: band))
        print("decay \(rt60) s at 500 Hz: \(estimate.seconds) s, \(estimate.evaluationRange), range \(estimate.dynamicRangeDecibels) dB, ξ \(estimate.nonlinearity) ‰")
        #expect(abs(estimate.seconds / rt60 - 1) < Self.tolerance)
        #expect(estimate.evaluationRange == .t30)
        #expect(estimate.band == band)
        #expect(estimate.nonlinearity >= 0 && estimate.nonlinearity < 50)
    }

    /// In a band 40 Hz wide one decay of random sound is itself uncertain: a single reading of an exact exponential
    /// scatters by 12 to 17 % (one standard deviation, measured over 32 seeds), against 6 % in the 500 Hz octave. So
    /// the estimator is held to 10 % on the mean of sixteen independent decays (its bias), and each reading to 50 %.
    @Test(arguments: [0.3, 0.6, 1.2])
    func `a known decay time is recovered in the bass`(rt60: Double) async throws {
        let band = 40.0...80.0
        // Long enough for the decay to fall 70 dB and for the band's 20 periods, with noise 80 dB under it in the
        // band (one noise for every seed: at that depth it only sets where the decay ends).
        let seconds = 1.5 * rt60 + 0.5
        var generator = SeededGenerator(state: 200)
        let noise = generator.noise(count: Int(seconds * RoomFixture.sampleRate), rms: 1e-3)
        let decays = RoomFixture.decays(rt60: rt60, band: band, seconds: seconds, count: 16, seed: 100)
        let readings = await withTaskGroup(of: (Int, Double?).self) { group in
            for (index, signal) in decays.enumerated() {
                group.addTask {
                    let response = RoomFixture.response(vDSP.add(signal, noise))
                    return (index, Decay.estimate(impulseResponse: response, band: band)?.seconds)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }.sorted { $0.0 < $1.0 }.map(\.1)
        }
        #expect(readings.count == 16)
        let found = readings.compactMap { $0 }
        #expect(found.count == readings.count, "every decay is estimated")
        for reading in found {
            #expect(abs(reading / rt60 - 1) < 0.5, "\(reading) s")
        }
        let mean = found.reduce(0, +) / Double(found.count)
        print("decay \(rt60) s at 40–80 Hz: mean \(mean) s of \(found)")
        #expect(abs(mean / rt60 - 1) < Self.tolerance)
    }

    @Test func `a decay as fast as the band filter's own gives nothing`() {
        // A unit impulse has no decay; what is read is the filter's, about 5.8 / bandwidth seconds.
        var impulse = [Double](repeating: 0, count: 96000)
        impulse[0] = 1
        let response = RoomFixture.response(RoomFixture.withNoise(impulse, rms: 1e-9, seed: 5))
        #expect(Decay.estimates(impulseResponse: response).allSatisfy { $0.estimate == nil })
        #expect(Decay.estimate(impulseResponse: response, band: 40...80) == nil)
    }

    @Test func `two bands with different decay times are told apart`() throws {
        let low = RoomFixture.octave(125)
        let high = RoomFixture.octave(1000)
        let slow = RoomFixture.decay(rt60: 1.0, band: low, seconds: 3, seed: 21)
        let fast = RoomFixture.decay(rt60: 0.3, band: high, seconds: 3, seed: 22)
        let both = RoomFixture.withNoise(zip(slow, fast).map(+), rms: 1e-4, seed: 23)
        let response = RoomFixture.response(both)
        let slowEstimate = try #require(Decay.estimate(impulseResponse: response, band: low))
        let fastEstimate = try #require(Decay.estimate(impulseResponse: response, band: high))
        print("two bands: \(slowEstimate.seconds) s (1.0) and \(fastEstimate.seconds) s (0.3)")
        #expect(abs(slowEstimate.seconds / 1.0 - 1) < Self.tolerance)
        #expect(abs(fastEstimate.seconds / 0.3 - 1) < Self.tolerance)

        // The band table: octaves 63 Hz to 4 kHz, the same edges as `OctaveBands`, with the same answers.
        let table = Decay.estimates(impulseResponse: response)
        let centres = [63.0957, 125.893, 251.189, 501.187, 1000, 1995.26, 3981.07]
        #expect(table.count == centres.count)
        for (row, centre) in zip(table, centres) {
            let expected = RoomFixture.octave(centre)
            #expect(abs(row.band.lowerBound / expected.lowerBound - 1) < 1e-5)
            #expect(abs(row.band.upperBound / expected.upperBound - 1) < 1e-5)
        }
        let tableSlow = try #require(table.first { $0.band.contains(125) }?.estimate)
        let tableFast = try #require(table.first { $0.band.contains(1000) }?.estimate)
        #expect(abs(tableSlow.seconds / 1.0 - 1) < Self.tolerance)
        #expect(abs(tableFast.seconds / 0.3 - 1) < Self.tolerance)
    }

    /// The decay's start over the noise in the band, computed from the levels the fixture was built with: band
    /// noise of RMS 1 against white noise of RMS `rms`, of which the band holds its width over the Nyquist
    /// frequency.
    static func designedRange(band: ClosedRange<Double>, rms: Double) -> Double {
        10 * log10(1 / (rms * rms * (band.upperBound - band.lowerBound) / (RoomFixture.sampleRate / 2)))
    }

    @Test func `the evaluation range follows the dynamic range, and too little gives nothing`() throws {
        let band = RoomFixture.octave(250)
        let signal = RoomFixture.decay(rt60: 0.6, band: band, seconds: 2.5, seed: 31)
        // About 55, 40 and 25 dB of range in the band.
        let wide = RoomFixture.withNoise(signal, rms: 0.0152, seed: 32)
        let middle = RoomFixture.withNoise(signal, rms: 0.0855, seed: 32)
        let narrow = RoomFixture.withNoise(signal, rms: 0.48, seed: 32)

        let t30 = try #require(Decay.estimate(impulseResponse: RoomFixture.response(wide), band: band))
        #expect(t30.evaluationRange == .t30)
        #expect(abs(t30.seconds / 0.6 - 1) < Self.tolerance)
        let t20 = try #require(Decay.estimate(impulseResponse: RoomFixture.response(middle), band: band))
        #expect(t20.evaluationRange == .t20)
        #expect(abs(t20.seconds / 0.6 - 1) < Self.tolerance)
        print("range: \(t30.dynamicRangeDecibels) dB (designed \(Self.designedRange(band: band, rms: 0.0152))), \(t20.dynamicRangeDecibels) dB (designed \(Self.designedRange(band: band, rms: 0.0855))); T30 \(t30.seconds) s, T20 \(t20.seconds) s")
        // The reported range is the designed one, to within the first block's own decay and the filter's skirts.
        #expect(abs(t30.dynamicRangeDecibels - Self.designedRange(band: band, rms: 0.0152)) < 3)
        #expect(abs(t20.dynamicRangeDecibels - Self.designedRange(band: band, rms: 0.0855)) < 3)

        #expect(Decay.estimate(impulseResponse: RoomFixture.response(narrow), band: band) == nil)
    }

    @Test func `a band outside the trusted band gives nothing`() {
        let signal = RoomFixture.withNoise(RoomFixture.decay(rt60: 0.6, band: 20...200, seconds: 3, seed: 41), rms: 1e-4, seed: 42)
        let response = RoomFixture.response(signal, trustedBand: 40...18000)
        #expect(Decay.estimate(impulseResponse: response, band: 40...80) != nil)
        #expect(Decay.estimate(impulseResponse: response, band: 20...40) == nil)
        #expect(Decay.estimate(impulseResponse: response, band: 30...60) == nil)
        #expect(Decay.estimate(impulseResponse: response, band: 10000...20000) == nil)

        // Nothing trusted or nothing captured: nothing to say.
        let untrusted = ImpulseResponse(
            samples: response.samples, sampleRate: RoomFixture.sampleRate, peakIndex: 0,
            band: 10...22000, capturedBand: nil, trustedBand: nil, recordingDuration: nil
        )
        #expect(Decay.estimate(impulseResponse: untrusted, band: 40...80) == nil)
    }

    @Test func `the bass band is under 80 Hz, clipped to the trusted band`() throws {
        let signal = RoomFixture.withNoise(RoomFixture.decay(rt60: 0.6, band: 20...80, seconds: 3, seed: 51), rms: 1e-4, seed: 52)
        #expect(Decay.bassBand(for: RoomFixture.response(signal, trustedBand: 20...20000)) == 20...80)
        #expect(Decay.bassBand(for: RoomFixture.response(signal, trustedBand: 40...20000)) == 40...80)
        // Less than half an octave left under 80 Hz: no bass band.
        #expect(Decay.bassBand(for: RoomFixture.response(signal, trustedBand: 60...20000)) == nil)
        #expect(Decay.bassBand(for: RoomFixture.response(signal, trustedBand: 100...20000)) == nil)

        let bass = try #require(Decay.bass(impulseResponse: RoomFixture.response(signal, trustedBand: 20...20000)))
        print("bass: \(bass.seconds) s over \(bass.band)")
        #expect(bass.band == 20...80)
        #expect(abs(bass.seconds / 0.6 - 1) < Self.tolerance)
    }

    @Test func `a response too short for the band gives nothing`() throws {
        // 0.3 s holds 13 periods of the 63 Hz octave's lowest frequency (44.7 Hz), under the 20 required; the same
        // length holds plenty of the 1 kHz octave's.
        let low = RoomFixture.octave(63.0957)
        let high = RoomFixture.octave(1000)
        let short = RoomFixture.withNoise(
            zip(RoomFixture.decay(rt60: 0.1, band: low, seconds: 0.3, seed: 61),
                RoomFixture.decay(rt60: 0.1, band: high, seconds: 0.3, seed: 62)).map(+),
            rms: 1e-5, seed: 63
        )
        let response = RoomFixture.response(short)
        #expect(Decay.minimumDuration(of: low) > 0.3)
        #expect(Decay.estimate(impulseResponse: response, band: low) == nil)
        #expect(Decay.estimate(impulseResponse: response, band: high) != nil)
    }

    @Test(arguments: [Float.nan, .infinity])
    func `a corrupt response gives nothing`(value: Float) {
        let signal = RoomFixture.withNoise(RoomFixture.decay(rt60: 0.6, band: RoomFixture.octave(500), seconds: 2, seed: 71), rms: 1e-4, seed: 72)
        var samples = RoomFixture.response(signal).samples
        samples[30000] = value
        let response = ImpulseResponse(samples: samples, sampleRate: RoomFixture.sampleRate, peakIndex: 0, band: 10...22000)
        #expect(Decay.estimate(impulseResponse: response, band: RoomFixture.octave(500)) == nil)
        #expect(Decay.estimates(impulseResponse: response).allSatisfy { $0.estimate == nil })
    }

    @Test func `silence gives nothing`() {
        let response = RoomFixture.response([Double](repeating: 0, count: 48000))
        #expect(Decay.estimate(impulseResponse: response, band: RoomFixture.octave(500)) == nil)
    }

    /// A room with one decaying resonance at 50 Hz, a +15 dB bell of Q 5, whose poles fix the decay time.
    static let resonance = Biquad.peaking(frequency: 50, q: 5, gain: 15, sampleRate: RoomFixture.sampleRate)
    static let resonanceBand = 35.0...70.0

    @Test func `the full chain reads the same decay as the room's own impulse response`() throws {
        let expected = RoomFixture.poleDecayTime(Self.resonance)

        // The room's impulse response, directly: a unit impulse through the resonance.
        var impulse = [Double](repeating: 0, count: Int(4 * RoomFixture.sampleRate))
        impulse[0] = 1
        let direct = RoomFixture.withNoise(Self.resonance.process(impulse), rms: 1e-6, seed: 81)
        let directEstimate = try #require(Decay.estimate(impulseResponse: RoomFixture.response(direct), band: Self.resonanceBand))

        // The same room measured: the app's sweep, through the room, recorded 0.1 s late with 3 s after and a
        // little noise, then deconvolved.
        let sweep = LogSweep.measurement(sampleRate: RoomFixture.sampleRate)
        let room = SimulatedSpeaker(delaySamples: 4800, filters: [Self.resonance], noiseRMS: 1e-5, tailSeconds: 3, seed: 82)
        let measured = Deconvolution.impulseResponse(recording: room.record(sweep), sweep: sweep)
        let chainEstimate = try #require(Decay.estimate(impulseResponse: measured, band: Self.resonanceBand, sweep: sweep))

        print("resonance: poles \(expected) s, direct \(directEstimate.seconds) s, chain \(chainEstimate.seconds) s (\(chainEstimate.evaluationRange), \(chainEstimate.dynamicRangeDecibels) dB)")
        #expect(abs(directEstimate.seconds / expected - 1) < Self.tolerance)
        #expect(abs(chainEstimate.seconds / expected - 1) < Self.tolerance)
        #expect(abs(chainEstimate.seconds / directEstimate.seconds - 1) < 0.05)
    }

    @Test func `the stretch after a recording's end is not read as quiet`() throws {
        // A short tail: the response's positive half runs on for seconds past what the recording holds of the
        // treble. With the sweep named, the noise is read where it was recorded and the decay still comes out.
        let sweep = LogSweep.measurement(sampleRate: RoomFixture.sampleRate)
        let band = RoomFixture.octave(2000)
        let room = SimulatedSpeaker(
            delaySamples: 4800, filters: [Biquad.peaking(frequency: 2000, q: 40, gain: 20, sampleRate: RoomFixture.sampleRate)],
            noiseRMS: 3e-4, tailSeconds: 1, seed: 91
        )
        let measured = Deconvolution.impulseResponse(recording: room.record(sweep), sweep: sweep)
        let expected = RoomFixture.poleDecayTime(Biquad.peaking(frequency: 2000, q: 40, gain: 20, sampleRate: RoomFixture.sampleRate))
        let estimate = try #require(Decay.estimate(impulseResponse: measured, band: band, sweep: sweep))
        print("treble resonance: poles \(expected) s, chain \(estimate.seconds) s, range \(estimate.dynamicRangeDecibels) dB")
        #expect(abs(estimate.seconds / expected - 1) < Self.tolerance)
    }
}

/// The room window: a long post window, so a room's reflections and modes stay in the response.
@Suite struct RoomWindowTests {
    static let sampleRate = RoomFixture.sampleRate

    /// A unit impulse at index 0 and one reflection of `gain` `delay` samples later, in a buffer of `count`.
    static func reflected(gain: Float, delay: Int, count: Int = 1 << 16) -> ImpulseResponse {
        var samples = [Float](repeating: 0, count: count)
        samples[0] = 1
        samples[delay] = gain
        return ImpulseResponse(samples: samples, sampleRate: sampleRate, peakIndex: 0)
    }

    /// `|1 + g·e^(−j2πfτ)|` in dB: the comb a single reflection makes.
    static func comb(at frequency: Double, gain: Double, delay: Double) -> Float {
        Float(10 * log10(1 + gain * gain + 2 * gain * cos(2 * Double.pi * frequency * delay)))
    }

    @Test func `a reflection 20 ms late makes the comb it should with the room window, and a gate removes it`() {
        let response = Self.reflected(gain: 0.5, delay: 960)
        let room = response.frequencyResponse(postWindow: ImpulseResponse.roomPostWindow)
        // Peaks every 50 Hz at +3.52 dB, dips between at −6.02 dB.
        var worst: Float = 0
        for frequency in checkFrequencies(from: 60, to: 5000, perOctave: 24) {
            let error = room.decibels(at: frequency) - Self.comb(at: Double(frequency), gain: 0.5, delay: 0.02)
            worst = max(worst, abs(error))
        }
        // The linear grid's points fall off the comb's own extremes, and interpolation between them costs a little.
        print("room window comb: worst error \(worst) dB")
        #expect(worst < 0.3)
        #expect(abs(room.decibels(at: 1000) - 20 * log10(1.5)) < 0.05)
        #expect(abs(room.decibels(at: 1025) - 20 * log10(0.5)) < 0.3)

        // The near-field default (100 ms) also holds a reflection 20 ms late: it is not a gate.
        let nearField = response.frequencyResponse()
        #expect(abs(nearField.decibels(at: 1000) - 20 * log10(1.5)) < 0.1)

        // A gate shorter than the reflection's delay leaves the direct sound alone: flat within 0.1 dB above
        // 1 / gate, where the comb swings by 9.5 dB.
        let gated = response.frequencyResponse(preWindow: 0.001, postWindow: 0.01)
        for frequency in checkFrequencies(from: 500, to: 5000, perOctave: 24) {
            #expect(abs(gated.decibels(at: frequency)) < 0.1, "at \(frequency) Hz")
        }
    }

    @Test func `a narrow resonance reads its true height with the room window and is smeared with the short one`() {
        // A room mode: +12 dB at 45 Hz with Q 10. Its poles are 2.3 Hz wide, so it takes about 1 s to decay by 60 dB.
        let mode = Biquad.peaking(frequency: 45, q: 10, gain: 12, sampleRate: Self.sampleRate)
        #expect(abs(RoomFixture.poleDecayTime(mode) - 0.97) < 0.02)
        var impulse = [Double](repeating: 0, count: 1 << 17)
        impulse[0] = 1
        let response = ImpulseResponse(samples: mode.process(impulse).map(Float.init), sampleRate: Self.sampleRate, peakIndex: 0)

        // Each window's peak against the biquad's own magnitude at the same grid points, so the grid's spacing
        // (which may miss the summit by a fraction of a bin) is not counted against the window.
        func peaks(_ curve: MagnitudeResponse) -> (read: Float, truth: Float) {
            let near = curve.frequencies.indices.filter { (40...50).contains(curve.frequencies[$0]) }
            let truth = near.map { Float(20 * log10(mode.magnitude(at: Double(curve.frequencies[$0]), sampleRate: Self.sampleRate))) }
            return (near.map { curve.decibels[$0] }.max()!, truth.max()!)
        }
        let room = peaks(response.frequencyResponse(postWindow: ImpulseResponse.roomPostWindow))
        let short = peaks(response.frequencyResponse())
        print("45 Hz mode: room window \(room.read) dB (true \(room.truth)), short window \(short.read) dB (true \(short.truth))")
        #expect(abs(room.read - room.truth) < 0.5)
        #expect(short.truth - short.read > 2)
    }

    @Test func `the room window resolves finer than the near-field one`() {
        #expect(ImpulseResponse.roomPostWindow >= 0.3 && ImpulseResponse.roomPostWindow <= 0.5)
        #expect(ImpulseResponse.roomPostWindow > ImpulseResponse.defaultPostWindow)
        // On a measured response the room window still reports only the trusted band.
        let sweep = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 1, sampleRate: Self.sampleRate)
        let measured = Deconvolution.impulseResponse(recording: SimulatedSpeaker(delaySamples: 1234.5, tailSeconds: 1).record(sweep), sweep: sweep)
        let room = measured.frequencyResponse(postWindow: ImpulseResponse.roomPostWindow)
        #expect(Double(room.frequencies.first!) >= sweep.trustedBand!.lowerBound)
        #expect(Double(room.frequencies.last!) <= sweep.trustedBand!.upperBound)
        // An unchanged sweep still reads flat at every point, to the trusted band's stated 0.3 dB: a longer window
        // adds nothing that is not there.
        let worst = room.decibels.map(abs).max() ?? .infinity
        print("room window, unchanged sweep: worst \(worst) dB")
        #expect(worst < 0.3)
    }
}

/// `ResponseAverage`: the seat's curve from several spots, and how far they disagree.
@Suite struct ResponseAverageTests {
    static func flat(_ level: Float, from low: Float = 20, to high: Float = 20000) -> MagnitudeResponse {
        let frequencies = checkFrequencies(from: low, to: high, perOctave: 12)
        return MagnitudeResponse(frequencies: frequencies, decibels: frequencies.map { _ in level })
    }

    @Test func `the power average of two responses 6 dB apart is the energy mean, not the dB mean`() throws {
        let average = ResponseAverage.power([Self.flat(0), Self.flat(6)])
        // (1 + 10^0.6) / 2 in power: 3.97 dB, where the dB mean would say 3.
        let expected = Float(10 * log10((1 + pow(10, 0.6)) / 2))
        #expect(average.count > 0)
        #expect(average.decibels.allSatisfy { abs($0 - expected) < 1e-4 })
        #expect(abs(expected - 3.97) < 0.01)

        let spread = ResponseAverage.spread([Self.flat(0), Self.flat(6)])
        #expect(spread.decibels.allSatisfy { abs($0 - 6) < 1e-4 })
    }

    @Test func `the average is taken point by point on the module's log grid`() throws {
        // Three responses that differ only at 1 kHz: 0, +6 and −6 dB there, 0 dB everywhere else.
        let frequencies = checkFrequencies(from: 20, to: 20000, perOctave: 48)
        func bump(_ height: Float) -> MagnitudeResponse {
            MagnitudeResponse(frequencies: frequencies, decibels: frequencies.map { abs($0 - 1000) < 1 ? height : 0 })
        }
        let average = ResponseAverage.power([bump(0), bump(6), bump(-6)])
        let ratios = zip(average.frequencies.dropFirst(), average.frequencies).map { $0 / $1 }
        #expect(ratios.allSatisfy { abs($0 - ratios[0]) < 1e-4 })
        #expect(abs(ratios[0] - pow(2, 1 / Float(ResponseComparison.pointsPerOctave))) < 1e-3)
        #expect(average.decibels(at: 100) == 0)
        let spread = ResponseAverage.spread([bump(0), bump(6), bump(-6)])
        #expect(spread.decibels(at: 100) == 0)
    }

    @Test func `identical responses have no spread`() {
        let shaped = MagnitudeResponse(
            frequencies: checkFrequencies(from: 20, to: 20000, perOctave: 12),
            decibels: checkFrequencies(from: 20, to: 20000, perOctave: 12).map { 4 * sin(log2($0)) }
        )
        let spread = ResponseAverage.spread([shaped, shaped, shaped])
        #expect(spread.count > 0)
        #expect(spread.decibels.allSatisfy { abs($0) < 1e-5 })
        let average = ResponseAverage.power([shaped, shaped, shaped])
        for (frequency, level) in zip(average.frequencies, average.decibels) {
            #expect(abs(level - shaped.decibels(at: frequency)) < 1e-4)
        }
    }

    @Test func `responses on different grids are averaged over the range they share`() throws {
        // A linear FFT-like grid from DC and a log grid over 50 Hz to 16 kHz, each a straight line in log
        // frequency (which interpolation reproduces exactly): 2 dB per octave and −1 dB per octave from 1 kHz.
        let linear = (0...8000).map { Float($0) * 2.5 }
        let first = MagnitudeResponse(frequencies: linear, decibels: linear.map { $0 > 0 ? 2 * log2($0 / 1000) : -160 })
        let logGrid = checkFrequencies(from: 50, to: 16000, perOctave: 7)
        let second = MagnitudeResponse(frequencies: logGrid, decibels: logGrid.map { -log2($0 / 1000) })

        let average = ResponseAverage.power([first, second])
        #expect(abs(try #require(average.frequencies.first) - 50) < 1e-3)
        #expect(abs(try #require(average.frequencies.last) - 16000) < 0.1)
        for (frequency, level) in zip(average.frequencies, average.decibels) {
            let a = 2 * log2(Double(frequency) / 1000)
            let b = -log2(Double(frequency) / 1000)
            let expected = 10 * log10((pow(10, a / 10) + pow(10, b / 10)) / 2)
            #expect(abs(Double(level) - expected) < 1e-3, "at \(frequency) Hz")
        }
        let spread = ResponseAverage.spread([first, second])
        #expect(abs(spread.decibels(at: 4000) - 6) < 1e-3)
    }

    @Test func `no responses, or none in common, give an empty response`() {
        #expect(ResponseAverage.power([]).count == 0)
        #expect(ResponseAverage.spread([]).count == 0)
        let low = Self.flat(0, from: 20, to: 200)
        let high = Self.flat(0, from: 300, to: 3000)
        #expect(ResponseAverage.power([low, high]).count == 0)
        #expect(ResponseAverage.spread([low, high]).count == 0)
        let empty = MagnitudeResponse(frequencies: [], decibels: [])
        #expect(ResponseAverage.power([low, empty]).count == 0)
        // One response is its own average, with no spread.
        let one = ResponseAverage.power([low])
        #expect(one.decibels.allSatisfy { $0 == 0 })
        #expect(ResponseAverage.spread([low]).decibels.allSatisfy { $0 == 0 })
    }
}
