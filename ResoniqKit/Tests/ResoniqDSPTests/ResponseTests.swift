import Foundation
import Testing
@testable import ResoniqDSP

/// Log-spaced check points, `perOctave` to the octave, from `low` to `high` hertz.
func checkFrequencies(from low: Float, to high: Float, perOctave: Int = 6) -> [Float] {
    let octaves = log2(high / low)
    let steps = Int((octaves * Float(perOctave)).rounded(.up))
    return (0...steps).map { low * pow(2, octaves * Float($0) / Float(steps)) }
}

@Suite struct DeconvolutionTests {
    static let sweep = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 1, sampleRate: 48000)

    @Test func `a recording identical to the sweep gives a unit impulse at time zero`() {
        let response = Deconvolution.impulseResponse(recording: Self.sweep.samples(), sweep: Self.sweep)
        #expect(response.peakIndex == 0)
        #expect(abs(response.delay) < 1e-6)
        // Band-limited to 20 kHz of a 24 kHz Nyquist, so the peak sample is the passband fraction, about 0.83.
        #expect(response.samples[0] > 0.8 && response.samples[0] <= 1)
        #expect(response.band == 20...20000)
    }

    /// Well inside the trusted band, where the response is exact to a few hundredths of a dB. The band's edges,
    /// and the looser accuracy there, are `TrustedBandTests`' to check.
    static let interior = checkFrequencies(from: 100, to: 18000)

    @Test func `the response of an unchanged sweep is flat at 0 dB inside the band`() {
        let magnitude = Deconvolution.impulseResponse(recording: Self.sweep.samples(), sweep: Self.sweep).frequencyResponse()
        #expect(magnitude.frequencies.first! >= 40 && magnitude.frequencies.last! <= 20000)
        for frequency in Self.interior {
            #expect(abs(magnitude.decibels(at: frequency)) < 0.05, "at \(frequency) Hz")
        }
    }

    @Test(arguments: [0.0, 1234.0, 4800.5, 7213.37])
    func `a delayed copy is found at its delay and stays flat`(delay: Double) {
        let speaker = SimulatedSpeaker(delaySamples: delay)
        let response = Deconvolution.impulseResponse(recording: speaker.record(Self.sweep), sweep: Self.sweep)
        // A parabola through a band-limited peak is good to a few hundredths of a sample.
        #expect(abs(response.delay * 48000 - delay) < 0.1)
        // A delay of half a sample has two equal neighbours; either may be the peak.
        #expect(abs(Double(response.peakIndex) - delay) <= 0.5)
        let magnitude = response.frequencyResponse()
        for frequency in Self.interior {
            #expect(abs(magnitude.decibels(at: frequency)) < 0.05, "at \(frequency) Hz")
        }
    }

    @Test func `a quieter recording gives a proportionally lower response`() {
        let quiet = Self.sweep.samples().map { $0 * 0.1 }
        let magnitude = Deconvolution.impulseResponse(recording: quiet, sweep: Self.sweep).frequencyResponse()
        for frequency in Self.interior {
            #expect(abs(magnitude.decibels(at: frequency) + 20) < 0.05, "at \(frequency) Hz")
        }
    }

    @Test func `a known filter's magnitude response is recovered`() {
        let filter = Biquad.peaking(frequency: 1000, q: 2, gain: -9, sampleRate: 48000)
        let speaker = SimulatedSpeaker(delaySamples: 300.25, filters: [filter])
        let magnitude = Deconvolution.impulseResponse(recording: speaker.record(Self.sweep), sweep: Self.sweep)
            .frequencyResponse()
        for frequency in checkFrequencies(from: 100, to: 18000, perOctave: 12) {
            let expected = Float(20 * log10(filter.magnitude(at: Double(frequency), sampleRate: 48000)))
            // 0.1 dB: interpolating the 2.9 Hz linear grid across the notch's curvature.
            #expect(abs(magnitude.decibels(at: frequency) - expected) < 0.1, "at \(frequency) Hz")
        }
    }

    @Test func `content above the sweep's range is not amplified`() {
        // A loud 23 kHz whistle the sweep never played: the deconvolution must not blow it up.
        let clean = Self.sweep.samples()
        let whistled = clean.enumerated().map { $0.element + 0.1 * Float(sin(2 * Double.pi * 23000 * Double($0.offset) / 48000)) }
        let reference = Deconvolution.impulseResponse(recording: clean, sweep: Self.sweep)
        let response = Deconvolution.impulseResponse(recording: whistled, sweep: Self.sweep)
        let difference = zip(response.samples, reference.samples).map { $0 - $1 }
        let leaked = (difference.map { $0 * $0 }.reduce(0, +)).squareRoot()
        // The whistle has 0.1 · √(N/2) ≈ 15 units of energy per unit of recording; less than 1 % of it may remain.
        #expect(leaked < 0.01 * 0.1 * Float(clean.count / 2).squareRoot())
        #expect(abs(response.frequencyResponse().decibels(at: 1000)) < 0.05)
    }

    /// The impulse-response energy a tone of 0.01 at `frequency` adds to a clean recording of `bassSweep`. The
    /// deconvolution is linear, so that is the energy of the tone's own deconvolution.
    static func addedEnergy(of frequency: Double) -> Double {
        let length = bassSweep.sampleCount + 26000
        let tone = (0..<length).map { Float(0.01 * sin(2 * Double.pi * frequency * Double($0) / bassSweep.sampleRate)) }
        return Deconvolution.impulseResponse(recording: tone, sweep: bassSweep).samples.reduce(0) { $0 + Double($1 * $1) }
    }

    /// The review's sweep. A shorter one lets the test tone's own truncation leak into the band and muddies the
    /// figure.
    static let bassSweep = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 3, sampleRate: 48000)
    static let fortyHertzEnergy = addedEnergy(of: 40)

    @Test(arguments: [6.0, 10.0, 12.0, 14.0])
    func `content below the sweep's range is not amplified`(frequency: Double) {
        // In band the deconvolution's gain for a tone grows as √f (a log sweep spends less energy per hertz as it
        // rises); below the start it must fall, not rise. A 10–12 Hz tone used to come out 16 dB above an equal
        // 40 Hz tone. Now it is at least 10 dB under it.
        let ratio = 10 * log10(Self.addedEnergy(of: frequency) / Self.fortyHertzEnergy)
        #expect(ratio < -10, "\(frequency) Hz: \(ratio) dB re a 40 Hz tone")
    }

    @Test func `rumble below the sweep does not bend the bass`() {
        // The reviewer's case: a speaker that rolls off below 80 Hz, recorded at 0.3, with 12 Hz rumble at about
        // −30 dBFS. The rumble used to leak into the response by several dB at the bottom of the band.
        let sweep = Self.sweep
        let highPass = Biquad.highPass(frequency: 80, q: 0.707, sampleRate: 48000)
        let speaker = SimulatedSpeaker(delaySamples: 7000, filters: [highPass])
        let quiet = speaker.record(sweep).map { $0 * 0.3 }
        let rumbling = quiet.enumerated().map { $0.element + Float(0.0316 * sin(2 * Double.pi * 12 * Double($0.offset) / 48000)) }
        let clean = Deconvolution.impulseResponse(recording: quiet, sweep: sweep).frequencyResponse()
        let measured = Deconvolution.impulseResponse(recording: rumbling, sweep: sweep).frequencyResponse()
        for frequency in checkFrequencies(from: Float(sweep.trustedBand!.lowerBound), to: 200, perOctave: 12) {
            let error = measured.decibels(at: frequency) - clean.decibels(at: frequency)
            #expect(abs(error) < 0.1, "at \(frequency) Hz: \(error) dB")
        }
    }

    @Test func `negative time wraps to the end of the buffer`() {
        let response = ImpulseResponse(samples: [Float](repeating: 0, count: 8).enumerated().map { $0.offset == 2 ? 1 : 0 }, sampleRate: 8)
        #expect(response.peakIndex == 2)
        #expect(response.index(atTime: -0.25) == 6)
        #expect(response.index(atOffset: -0.5) == 6)
        #expect(response.index(atOffset: 0.25) == 4)
    }
}

/// What a recording actually holds of the sweep, and the band a response is reported over.
@Suite struct CapturedBandTests {
    static let sweep = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 1, sampleRate: 48000)

    /// The sweep delayed by `delay` seconds into a recording `length` seconds long (cut or padded), with a little
    /// noise so nothing is exactly zero.
    static func recording(delay: Double, length: Double) -> [Float] {
        var speaker = SimulatedSpeaker(delaySamples: delay * 48000, noiseRMS: 0.0005, tailSeconds: 0)
        speaker.tailSeconds = max(0, length - delay - Self.sweep.duration) + 0.01
        return Array(speaker.record(Self.sweep).prefix(Int(length * 48000)))
    }

    @Test func `a whole recording captures the whole sweep`() {
        let response = Deconvolution.impulseResponse(recording: Self.recording(delay: 0.15, length: 1.65), sweep: Self.sweep)
        #expect(response.capturedBand == Self.sweep.startFrequency...Self.sweep.endFrequency)
        #expect(response.capturesWholeSweep)
        #expect(response.trustedBand == Self.sweep.trustedBand)
    }

    @Test func `a recording that ends early says which frequencies it never heard`() throws {
        // A 1 s route delay and a recording that stops half a second before the sweep does: only the first half of
        // the sweep, 20 Hz to 632 Hz, was recorded. (The review's case, a 2 s delay on a 3 s sweep cut 1.5 s short,
        // gave a confident response reading −30 dB at 1 kHz and −85 dB at 5 kHz.)
        let response = Deconvolution.impulseResponse(recording: Self.recording(delay: 1, length: 1.5), sweep: Self.sweep)
        #expect(!response.capturesWholeSweep)
        let captured = try #require(response.capturedBand)
        let heard = Self.sweep.frequency(at: 0.5)
        #expect(abs(captured.upperBound / heard - 1) < 0.01, "captured to \(captured.upperBound) Hz")
        #expect(captured.lowerBound == 20)
        // Nothing is reported where nothing was recorded, and what is reported is right.
        let magnitude = response.frequencyResponse()
        let top = try #require(magnitude.frequencies.last)
        #expect(Double(top) < heard)
        for frequency in checkFrequencies(from: magnitude.frequencies.first!, to: top, perOctave: 6) {
            #expect(abs(magnitude.decibels(at: frequency)) < 0.3, "at \(frequency) Hz")
        }
    }

    @Test func `a recording that starts late says it lost the bass`() throws {
        // The recording starts 0.3 s into the sweep, which by then is at 159 Hz.
        let full = SimulatedSpeaker(noiseRMS: 0.0005).record(Self.sweep)
        let late = Array(full[14400...])
        let response = Deconvolution.impulseResponse(recording: late, sweep: Self.sweep)
        #expect(!response.capturesWholeSweep)
        let captured = try #require(response.capturedBand)
        #expect(abs(captured.lowerBound / Self.sweep.frequency(at: 0.3) - 1) < 0.01, "captured from \(captured.lowerBound) Hz")
        let magnitude = response.frequencyResponse()
        #expect(Double(try #require(magnitude.frequencies.first)) > captured.lowerBound)
    }

    @Test(arguments: [0, 1, 10, 2400])
    func `a recording too short to hold anything traps nothing and reports nothing`(count: Int) {
        let response = Deconvolution.impulseResponse(recording: [Float](repeating: 0.1, count: count), sweep: Self.sweep)
        #expect(response.capturedBand == nil || count == 2400)
        #expect(response.frequencyResponse().count == 0 || count == 2400)
        // A 2400-sample recording holds the first 50 ms of the sweep: at most 21 Hz, nothing trusted.
        #expect(response.trustedBand == nil)
        // Distortion of nothing is nothing, not a trap.
        let distortion = HarmonicDistortion.analyze(impulseResponse: response, sweep: Self.sweep)
        #expect(distortion.thd.count == 0)
    }

    @Test func `a very short sweep and a ten-sample recording do not trap`() {
        let short = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 0.05, sampleRate: 48000)
        let response = Deconvolution.impulseResponse(recording: [Float](repeating: 0.1, count: 10), sweep: short)
        #expect(response.frequencyResponse().count == 0)
    }

    @Test func `an all-zero recording captured nothing`() {
        let response = Deconvolution.impulseResponse(recording: [Float](repeating: 0, count: 48000 * 2), sweep: Self.sweep)
        #expect(response.capturedBand == nil)
        #expect(response.frequencyResponse().count == 0)
    }

    @Test(arguments: [Float.nan, .infinity])
    func `a corrupt recording gives no response, not a finite-looking one`(value: Float) {
        var recording = Self.recording(delay: 0.15, length: 1.65)
        recording[5000] = value
        let response = Deconvolution.impulseResponse(recording: recording, sweep: Self.sweep)
        #expect(response.capturedBand == nil)
        #expect(response.frequencyResponse().count == 0)
        let distortion = HarmonicDistortion.analyze(impulseResponse: response, sweep: Self.sweep)
        #expect(distortion.thd.decibels.allSatisfy { !$0.isFinite })
    }
}

/// The band a sweep's response is accurate over, and the measurement sweep the app plays.
@Suite struct TrustedBandTests {
    @Test(arguments: [44100.0, 48000.0])
    func `the measurement sweep covers the reported band`(sampleRate: Double) throws {
        let sweep = LogSweep.measurement(sampleRate: sampleRate)
        let trusted = try #require(sweep.trustedBand)
        #expect(trusted.lowerBound <= LogSweep.reportedBand.lowerBound)
        #expect(trusted.upperBound >= LogSweep.reportedBand.upperBound)
        #expect(sweep.amplitude == LogSweep.maximumAmplitude)
        #expect(sweep.duration >= LogSweep.minimumAccurateDuration)
    }

    @Test(arguments: [(10.0, 22000.0, 4.0, 48000.0), (10.0, 22000.0, 3.0, 44100.0), (20.0, 20000.0, 3.0, 48000.0), (20.0, 20000.0, 1.0, 48000.0)])
    func `an unchanged sweep reads flat across the trusted band and nothing is reported outside it`(
        start: Double, end: Double, duration: Double, sampleRate: Double
    ) throws {
        let sweep = LogSweep(startFrequency: start, endFrequency: end, duration: duration, sampleRate: sampleRate)
        let response = Deconvolution.impulseResponse(recording: SimulatedSpeaker(delaySamples: 1234.5).record(sweep), sweep: sweep)
        let trusted = try #require(sweep.trustedBand)
        let magnitude = response.frequencyResponse()
        #expect(Double(magnitude.frequencies.first!) >= trusted.lowerBound)
        #expect(Double(magnitude.frequencies.last!) <= trusted.upperBound)
        // The stated accuracy: within 0.3 dB over the whole band, within 0.1 dB from three times the start. Every
        // point is checked, not a sample of them.
        let points = zip(magnitude.frequencies, magnitude.decibels)
        let bottom = points.filter { Double($0.0) < 3 * start }.max { abs($0.1) < abs($1.1) }
        let rest = points.filter { Double($0.0) >= 3 * start }.max { abs($0.1) < abs($1.1) }
        #expect(abs(bottom?.1 ?? 0) < 0.3, "worst below \(3 * start) Hz: \(String(describing: bottom))")
        #expect(abs(rest?.1 ?? 0) < 0.1, "worst above \(3 * start) Hz: \(String(describing: rest))")
    }
}

@Suite struct ResponseComparisonTests {
    let base: MagnitudeResponse = {
        let frequencies = checkFrequencies(from: 20, to: 20000, perOctave: 12)
        return MagnitudeResponse(frequencies: frequencies, decibels: frequencies.map { _ in 0 })
    }()

    @Test func `level matching removes a constant offset`() {
        let shape: (Float) -> Float = { 3 * sin(log2($0)) }
        let reference = base.withLevels(shape)
        let louder = base.withLevels { shape($0) + 12.5 }
        let matched = ResponseComparison.levelMatched(louder, to: reference)
        #expect(matched.frequencies == louder.frequencies)
        #expect(zip(matched.decibels, reference.decibels).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    @Test func `level matching uses the median in the band, so a narrow peak does not move it`() {
        let reference = base.withLevels { _ in 0 }
        let peaked = base.withLevels { abs($0 - 1000) < 60 ? 20 : -6 }
        let matched = ResponseComparison.levelMatched(peaked, to: reference)
        #expect(abs(matched.decibels(at: 500) - 0) < 1e-4)
    }

    @Test func `level matching respects the band it is given`() {
        let reference = base.withLevels { _ in 0 }
        let tilted = base.withLevels { $0 < 200 ? 10 : 0 }
        let matched = ResponseComparison.levelMatched(tilted, to: reference, band: 50...150)
        #expect(abs(matched.decibels(at: 100)) < 1e-4)
        #expect(abs(matched.decibels(at: 1000) + 10) < 1e-4)
    }

    @Test func `the difference is taken on a log grid over the shared range`() {
        let first = MagnitudeResponse(frequencies: [20, 20000], decibels: [0, 0])
        let second = MagnitudeResponse(frequencies: [100, 10000], decibels: [-3, -3])
        let difference = ResponseComparison.difference(first, second)
        #expect(abs(difference.frequencies.first! - 100) < 1e-3)
        #expect(abs(difference.frequencies.last! - 10000) < 0.1)
        // 6.64 octaves at 48 to the octave.
        #expect(difference.count == 320)
        #expect(difference.decibels.allSatisfy { abs($0 - 3) < 1e-5 })
        let ratios = zip(difference.frequencies.dropFirst(), difference.frequencies).map { $0 / $1 }
        #expect(ratios.allSatisfy { abs($0 - ratios[0]) < 1e-4 })
    }
}

extension MagnitudeResponse {
    func withLevels(_ level: (Float) -> Float) -> MagnitudeResponse {
        MagnitudeResponse(frequencies: frequencies, decibels: frequencies.map(level))
    }
}
