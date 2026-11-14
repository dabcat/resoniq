import Accelerate
import Foundation
import Testing
@testable import ResoniqDSP

/// A file of sweeps played by a device whose clock runs `ratio` times the phone's, recorded by the phone: each sweep is
/// computed exactly at the stretched times (not resampled), passed through `filters` and the nonlinearity
/// `y = x + cubic·x³`, with white noise and silence around.
struct ExternalRecording {
    var sampleRate = 48000.0
    var sweep = LogSweep.measurement(sampleRate: 48000)
    /// Where each sweep starts in the recording, in samples (any real number).
    var starts: [Double]
    var ratio = 1.0
    var filters: [Biquad] = []
    var cubic = 0.0
    var noiseRMS = 0.0
    var duration: Double
    var seed: UInt64 = 7
    /// Where the clock tone starts, in samples; nil for none.
    var toneStart: Double? = nil

    /// The sweep as a player `ratio` times fast plays it, starting `start` samples into a buffer of `count`.
    static func stretched(_ sweep: LogSweep, ratio: Double, start: Double, into signal: inout [Double]) {
        let count = sweep.sampleCount
        let fade = RaisedCosine.sampleCount(of: sweep.fadeDuration, sampleRate: sweep.sampleRate)
        let scale = 2 * Double.pi * sweep.startFrequency * sweep.duration / sweep.logRatio
        let first = max(0, Int(start.rounded(.up)))
        let last = min(signal.count - 1, Int((start + Double(count - 1) / ratio).rounded(.down)))
        guard first <= last else { return }
        for index in first...last {
            // The sweep's own sample index played at this instant.
            let position = (Double(index) - start) * ratio
            guard position >= 0, position <= Double(count - 1) else { continue }
            let time = position / sweep.sampleRate
            let phase = scale * (exp(time * sweep.logRatio / sweep.duration) - 1)
            let distance = min(position, Double(count - 1) - position)
            signal[index] += Double(sweep.amplitude) * RaisedCosine.rise(distance, over: Double(max(fade, 1))) * sin(phase)
        }
    }

    func record() -> [Float] {
        let length = Int(duration * sampleRate)
        var signal = [Double](repeating: 0, count: length)
        for start in starts { Self.stretched(sweep, ratio: ratio, start: start, into: &signal) }
        if let toneStart {
            // The tone as the player plays it: its frequency and its length scaled by the clock.
            let length = SweepFinder.clockToneDuration * sampleRate / ratio
            let fade = 0.02 * sampleRate / ratio
            for index in max(0, Int(toneStart.rounded(.up)))..<min(length > 0 ? Int(toneStart + length) : 0, signal.count) {
                let t = Double(index) - toneStart
                let edge = RaisedCosine.rise(min(t, length - t), over: fade)
                signal[index] += Double(SweepFinder.clockToneAmplitude) * edge
                    * sin(2 * Double.pi * SweepFinder.clockToneFrequency * ratio * t / sampleRate)
            }
        }
        for filter in filters { signal = filter.process(signal) }
        if cubic != 0 { signal = signal.map { $0 + cubic * $0 * $0 * $0 } }
        if noiseRMS > 0 {
            var generator = SeededGenerator(state: seed)
            signal = zip(signal, generator.noise(count: length, rms: noiseRMS)).map(+)
        }
        return signal.map(Float.init)
    }
}

/// A small speaker: rolls off under 70 Hz, a presence bump, and a cubic term giving about 1 % THD in the midrange.
let bookshelfFilters = [
    Biquad.highPass(frequency: 70, q: 0.707, sampleRate: 48000),
    Biquad.peaking(frequency: 2500, q: 1.2, gain: 3, sampleRate: 48000),
]

@Suite struct SweepFinderTests {
    static let sampleRate = 48000.0
    static let sweep = LogSweep.measurement(sampleRate: 48000)

    @Test(arguments: [1, 2, 3])
    func `finds every sweep at its position in room noise through a speaker`(count: Int) {
        let starts = [2.31, 11.07, 19.55].prefix(count).map { $0 * Self.sampleRate + 0.37 }
        let recording = ExternalRecording(starts: Array(starts), filters: bookshelfFilters, cubic: 0.3, noiseRMS: 0.003, duration: 28).record()
        let found = SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep)
        #expect(found.count == count)
        for (sweep, start) in zip(found, starts) {
            // The speaker's own group delay at the filter's peak is a fraction of a millisecond.
            #expect(abs(sweep.start - start) < 24, "found at \(sweep.start), played at \(start)")
            #expect(sweep.isComplete)
            #expect(sweep.strength > 30)
        }
    }

    @Test func `the position is exact to a fraction of a sample without a speaker`() {
        let start = 3.0 * Self.sampleRate + 123.4
        let recording = ExternalRecording(starts: [start], noiseRMS: 0.001, duration: 9).record()
        let found = SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep)
        #expect(found.count == 1)
        #expect(abs((found.first?.start ?? 0) - start) < 0.2)
    }

    @Test func `expectedCount keeps the strongest`() {
        let recording = ExternalRecording(starts: [48000, 500_000, 1_000_000], noiseRMS: 0.003, duration: 27).record()
        let found = SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep, expectedCount: 2)
        #expect(found.count == 2)
    }

    @Test func `a sweep cut off by the end of the recording is flagged`() {
        let recording = ExternalRecording(starts: [48000, 8 * 48000], noiseRMS: 0.001, duration: 10).record()
        let found = SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep)
        #expect(found.count == 2)
        #expect(found.first?.isComplete == true)
        #expect(found.last?.isComplete == false)
    }

    @Test func `a sweep that began before the recording is flagged`() {
        let recording = ExternalRecording(starts: [-48000], noiseRMS: 0.001, duration: 8).record()
        let found = SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep)
        #expect(found.count == 1)
        #expect(found.first?.isComplete == false)
        #expect((found.first?.start ?? 0) < 0)
    }

    @Test func `nothing is found in a minute of pink noise`() {
        let noise = pinkNoise(count: Int(60 * Self.sampleRate), rms: 0.05, seed: 3)
        #expect(SweepFinder.find(in: noise, sampleRate: Self.sampleRate, sweep: Self.sweep).isEmpty)
    }

    @Test func `nothing is found in a minute of a synthetic tune`() {
        let tune = syntheticTune(seconds: 60, sampleRate: Self.sampleRate)
        let found = SweepFinder.find(in: tune, sampleRate: Self.sampleRate, sweep: Self.sweep)
        #expect(found.isEmpty)
    }

    /// Speech and a chord progression with vibrato and glides, synthesised (`syntheticSpeech`, `syntheticChords`):
    /// nothing is found by either rule, dry or in a reverberant room, and the follower follows nothing.
    @Test(arguments: ["speech", "chords"])
    func `nothing is found in speech or in chords with vibrato and glides`(material: String) {
        let sound = material == "speech"
            ? syntheticSpeech(seconds: 40, sampleRate: Self.sampleRate)
            : syntheticChords(seconds: 40, sampleRate: Self.sampleRate)
        let strict = SweepFinder.find(in: sound, sampleRate: Self.sampleRate, sweep: Self.sweep)
        let anchored = SweepFinder.find(in: sound, sampleRate: Self.sampleRate, sweep: Self.sweep, anchored: true)
        print("\(material): strict \(strict), anchored \(anchored)")
        #expect(strict.isEmpty)
        #expect(anchored.isEmpty)
        let room = ReverberantRoom(directToReverberant: -6, reverberationTime: 0.6).apply(sound, sampleRate: Self.sampleRate)
        #expect(SweepFinder.find(in: room, sampleRate: Self.sampleRate, sweep: Self.sweep, anchored: true).isEmpty)
        #expect(SweepFollowerTests.follow(sound).isEmpty)
        #expect(SweepFollowerTests.follow(room).isEmpty)
    }

    @Test func `a sweep is found under speech`() {
        let sweep = ExternalRecording(starts: [5 * Self.sampleRate], filters: bookshelfFilters, duration: 20).record()
        let recording = vDSP.add(syntheticSpeech(seconds: 20, sampleRate: Self.sampleRate), vDSP.multiply(0.5, sweep))
        let found = SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep)
        #expect(found.count == 1)
        #expect(abs((found.first?.start ?? 0) - 5 * Self.sampleRate) < 24)
    }

    @Test func `a sweep is found under music`() {
        var recording = syntheticTune(seconds: 20, sampleRate: Self.sampleRate).map { $0 * 0.5 }
        let sweep = ExternalRecording(starts: [5 * Self.sampleRate], filters: bookshelfFilters, duration: 20).record()
        recording = vDSP.add(recording, sweep)
        let found = SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep)
        #expect(found.count == 1)
        #expect(abs((found.first?.start ?? 0) - 5 * Self.sampleRate) < 24)
    }

    @Test func `silence and garbage give nothing`() {
        #expect(SweepFinder.find(in: [], sampleRate: Self.sampleRate, sweep: Self.sweep).isEmpty)
        #expect(SweepFinder.find(in: [Float](repeating: 0, count: 100_000), sampleRate: Self.sampleRate, sweep: Self.sweep).isEmpty)
        #expect(SweepFinder.find(in: [0, .nan, 1], sampleRate: Self.sampleRate, sweep: Self.sweep).isEmpty)
    }

    // MARK: The player's clock

    @Test(arguments: [-500.0, -300.0, -100.0, 0.0, 100.0, 300.0, 500.0])
    func `the clock ratio is recovered from the spacing of three sweeps`(ppm: Double) {
        let ratio = 1 + ppm * 1e-6
        let spacing = 7.0
        let starts = (0..<3).map { 2.5 * Self.sampleRate + Double($0) * spacing * Self.sampleRate / ratio }
        let recording = ExternalRecording(starts: starts, ratio: ratio, filters: bookshelfFilters, cubic: 0.3, noiseRMS: 0.003, duration: 23).record()
        let found = SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep)
        #expect(found.count == 3)
        let estimate = SweepFinder.clockRatio(starts: found.map(\.start), expectedSpacing: spacing, sampleRate: Self.sampleRate)
        let error = ((estimate ?? 0) - ratio) * 1e6
        print("clock ratio at \(ppm) ppm: estimated with an error of \(error) ppm")
        #expect(abs(error) < 10)
    }

    @Test func `a missed sweep in the middle still gives the ratio`() {
        let ratio = 1.0003
        let starts = [0.0, 14.0].map { 1 * Self.sampleRate + $0 * Self.sampleRate / ratio }
        let estimate = SweepFinder.clockRatio(starts: starts, expectedSpacing: 7, sampleRate: Self.sampleRate)
        #expect(abs((estimate ?? 0) - ratio) < 1e-7)
        #expect(SweepFinder.clockRatio(starts: [0, 5 * 48000], expectedSpacing: 7, sampleRate: 48000) == nil)
        #expect(SweepFinder.clockRatio(starts: [1000], expectedSpacing: 7, sampleRate: 48000) == nil)
    }

    @Test func `the fit says how far three starts stray from a line`() throws {
        let ratio = 1.0002
        let starts = (0..<3).map { 48000 + Double($0) * 7 * 48000 / ratio }
        let fit = try #require(SweepFinder.clockFit(starts: starts, expectedSpacing: 7, sampleRate: 48000))
        #expect(abs(fit.ratio - ratio) < 1e-9)
        #expect(fit.residual < 1e-6)
        // The middle sweep placed on a reflection 3 ms late.
        let misplaced = try #require(SweepFinder.clockFit(starts: [starts[0], starts[1] + 144, starts[2]], expectedSpacing: 7, sampleRate: 48000))
        #expect(misplaced.residual > 50)
    }

    @Test(arguments: [-500.0, -100.0, 0.0, 300.0, 1000.0])
    func `the clock ratio is read from the clock tone through a speaker and a room`(ppm: Double) {
        let ratio = 1 + ppm * 1e-6
        let recording = ExternalRecording(
            starts: [], ratio: ratio, filters: bookshelfFilters + [allPass(at: 1100)], noiseRMS: 0.003, duration: 3,
            toneStart: 0.4 * Self.sampleRate
        ).record()
        let estimate = SweepFinder.clockRatio(ofTone: recording, sampleRate: Self.sampleRate)
        let error = ((estimate ?? 0) - ratio) * 1e6
        print("clock tone at \(ppm) ppm: error \(error) ppm")
        #expect(abs(error) < 1)
    }

    @Test func `no clock ratio is read from noise or from a sweep`() {
        let noise = pinkNoise(count: 96000, rms: 0.05, seed: 5)
        #expect(SweepFinder.clockRatio(ofTone: noise, sampleRate: Self.sampleRate) == nil)
        let sweep = ExternalRecording(starts: [0], noiseRMS: 0.001, duration: 4.5).record()
        #expect(SweepFinder.clockRatio(ofTone: sweep, sampleRate: Self.sampleRate) == nil)
        #expect(SweepFinder.clockRatio(ofTone: [], sampleRate: Self.sampleRate) == nil)
    }

    @Test func `the correctable range is the documented limit`() {
        #expect(SweepFinder.isCorrectable(1.0005))
        #expect(SweepFinder.isCorrectable(0.9991))
        #expect(!SweepFinder.isCorrectable(1.0011))
        #expect(!SweepFinder.isCorrectable(48000.0 / 44100))
        #expect(!SweepFinder.isCorrectable(.nan))
    }

    @Test func `correcting by a ratio of 1 changes nothing`() {
        let samples: [Float] = [0, 1, 2, 3]
        #expect(SweepFinder.corrected(samples, ratio: 1) == samples)
    }

    @Test func `the interpolator reproduces a band-limited signal between its samples`() {
        // A 15 kHz sine read at a quarter-sample offset with a step slightly under 1.
        let frequency = 15000.0
        let samples = (0..<4000).map { Float(sin(2 * Double.pi * frequency * Double($0) / 48000)) }
        let start = 500.25
        let step = 0.9995
        let read = Interpolation.resample(samples, from: start, step: step, count: 2000)
        var worst: Float = 0
        for (index, value) in read.enumerated() {
            let expected = Float(sin(2 * Double.pi * frequency * (start + Double(index) * step) / 48000))
            worst = max(worst, abs(value - expected))
        }
        // −80 dB.
        #expect(worst < 1e-4)
    }
}

/// How the player's clock bends what a run measures, with and without correction. The accuracy stated in
/// `docs/modules/ResoniqDSP.md` is pinned here.
@Suite struct ClockOffsetAccuracyTests {
    static let sampleRate = 48000.0
    static let sweep = LogSweep.measurement(sampleRate: 48000)
    static let start = 0.25 * 48000 + 0.3

    static func recording(ratio: Double) -> [Float] {
        ExternalRecording(starts: [start], ratio: ratio, filters: bookshelfFilters, cubic: 2, noiseRMS: 0.0003, duration: 5).record()
    }

    static let reference: (response: MagnitudeResponse, thd: SweepDistortion) = analyse(recording(ratio: 1))

    static func analyse(_ recording: [Float]) -> (response: MagnitudeResponse, thd: SweepDistortion) {
        let response = Deconvolution.impulseResponse(recording: recording, sweep: sweep)
        let smoothed = Smoothing.fractionalOctave(response.frequencyResponse(), fraction: 3)
        let distortion = HarmonicDistortion.analyze(impulseResponse: response, sweep: sweep)
        let thd = SweepDistortion(
            fundamental: distortion.fundamental,
            harmonics: distortion.harmonics,
            thd: Smoothing.fractionalOctave(distortion.thd, fraction: 3),
            noiseFloor: distortion.noiseFloor
        )
        return (smoothed, thd)
    }

    /// The worst response difference in dB over 20 Hz to 20 kHz, and the worst THD difference as a fraction of the
    /// reference's, from 100 Hz to 5 kHz.
    static func errors(_ measured: (response: MagnitudeResponse, thd: SweepDistortion)) -> (decibels: Float, thd: Float) {
        let frequencies = checkFrequencies(from: 20, to: 20000, perOctave: 12)
        let response = frequencies.map { abs(measured.response.decibels(at: $0) - reference.response.decibels(at: $0)) }.max() ?? .infinity
        let thd = checkFrequencies(from: 100, to: 5000, perOctave: 6).map { frequency in
            let expected = reference.thd.thdPercent(at: frequency)
            return abs(measured.thd.thdPercent(at: frequency) - expected) / expected
        }.max() ?? .infinity
        return (response, thd)
    }

    @Test(arguments: [-500.0, -300.0, -100.0, 100.0, 300.0, 500.0])
    func `corrected, a clock offset measures as no offset`(ppm: Double) {
        let ratio = 1 + ppm * 1e-6
        let recording = Self.recording(ratio: ratio)
        let uncorrected = Self.errors(Self.analyse(recording))
        let corrected = Self.errors(Self.analyse(SweepFinder.corrected(recording, ratio: ratio)))
        print("clock \(ppm) ppm: uncorrected \(uncorrected.decibels) dB, THD off by \(uncorrected.thd * 100) %; corrected \(corrected.decibels) dB, THD off by \(corrected.thd * 100) %")
        #expect(corrected.decibels < 0.1)
        #expect(corrected.thd < 0.05)
    }

    @Test func `uncorrected, the offsets a player has bend the response by little and the distortion by more`() {
        for ppm in [100.0, 300.0, 500.0, 1000.0] {
            let errors = Self.errors(Self.analyse(Self.recording(ratio: 1 + ppm * 1e-6)))
            print("uncorrected \(ppm) ppm: \(errors.decibels) dB, THD off by \(errors.thd * 100) %")
        }
    }
}

/// A second-order all-pass at `frequency`: a crossover's phase without its magnitude.
func allPass(at frequency: Double, q: Double = 0.707, sampleRate: Double = 48000) -> Biquad {
    let w = 2 * Double.pi * frequency / sampleRate
    let alpha = sin(w) / (2 * q)
    let a0 = 1 + alpha
    return Biquad(b0: (1 - alpha) / a0, b1: -2 * cos(w) / a0, b2: (1 + alpha) / a0, a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
}

/// Pink noise by Paul Kellet's filter on white noise, scaled to `rms`.
func pinkNoise(count: Int, rms: Double, seed: UInt64) -> [Float] {
    var generator = SeededGenerator(state: seed)
    let white = generator.noise(count: count, rms: 1)
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
    var pink = [Double](repeating: 0, count: count)
    for index in 0..<count {
        let w = white[index]
        b0 = 0.99886 * b0 + w * 0.0555179
        b1 = 0.99332 * b1 + w * 0.0750759
        b2 = 0.96900 * b2 + w * 0.1538520
        b3 = 0.86650 * b3 + w * 0.3104856
        b4 = 0.55000 * b4 + w * 0.5329522
        b5 = -0.7616 * b5 - w * 0.0168980
        pink[index] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
        b6 = w * 0.115926
    }
    let measured = (pink.map { $0 * $0 }.reduce(0, +) / Double(count)).squareRoot()
    return pink.map { Float($0 * rms / measured) }
}

/// A tune: notes of a pentatonic melody, each with a few harmonics and a decaying envelope, a bass line under it, and
/// a few notes that glide upwards, as music does.
func syntheticTune(seconds: Double, sampleRate: Double) -> [Float] {
    let count = Int(seconds * sampleRate)
    var signal = [Double](repeating: 0, count: count)
    let scale = [261.63, 293.66, 329.63, 392.0, 440.0, 523.25, 587.33, 659.25, 783.99, 880.0]
    var generator = SeededGenerator(state: 11)
    var time = 0.0
    var note = 0
    while time < seconds {
        let length = [0.125, 0.25, 0.25, 0.5][Int(generator.next() % 4)]
        let frequency = scale[Int(generator.next() % UInt64(scale.count))]
        let glide = note % 7 == 3 ? 1.5 : 0
        let first = Int(time * sampleRate)
        let last = min(count, Int((time + length * 1.5) * sampleRate))
        let bass = scale[Int(generator.next() % 5)] / 4
        if first < last {
            var phase = 0.0
            var bassPhase = 0.0
            for index in first..<last {
                let t = Double(index - first) / sampleRate
                let instant = frequency * pow(2, glide * t / length)
                phase += 2 * Double.pi * instant / sampleRate
                bassPhase += 2 * Double.pi * bass / sampleRate
                let envelope = exp(-3 * t / length) * min(1, t * 200)
                let tone = sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase) + 0.12 * sin(5 * phase)
                signal[index] += 0.08 * envelope * tone + 0.06 * envelope * sin(bassPhase)
            }
        }
        time += length
        note += 1
    }
    return signal.map(Float.init)
}
