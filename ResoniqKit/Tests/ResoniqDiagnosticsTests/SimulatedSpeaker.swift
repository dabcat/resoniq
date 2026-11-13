import Foundation
import ResoniqDSP
import ResoniqDiagnostics
import Synchronization
import Testing

// Copied from Tests/ResoniqDSPTests/SimulatedSpeaker.swift (a test target cannot be imported) and extended with a
// low-pass, a distortion confined to a band of the sweep, an overall gain and a limiter.

/// A second-order IIR section (RBJ cookbook), in double precision.
struct Biquad {
    let b0, b1, b2, a1, a2: Double

    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 + cos(w)) / 2 / a0, b1: -(1 + cos(w)) / a0, b2: (1 + cos(w)) / 2 / a0,
            a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0
        )
    }

    static func lowPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 - cos(w)) / 2 / a0, b1: (1 - cos(w)) / a0, b2: (1 - cos(w)) / 2 / a0,
            a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0
        )
    }

    static func peaking(frequency: Double, q: Double, gain decibels: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let a = pow(10, decibels / 40)
        let a0 = 1 + alpha / a
        return Biquad(
            b0: (1 + alpha * a) / a0, b1: -2 * cos(w) / a0, b2: (1 - alpha * a) / a0,
            a1: -2 * cos(w) / a0, a2: (1 - alpha / a) / a0
        )
    }

    /// A plain loop with plain assignments: the same arithmetic as a `map` with a tuple swap, without the per-sample
    /// generic overhead those carry in the debug build the tests run.
    func process(_ input: [Double]) -> [Double] {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var output = [Double](repeating: 0, count: input.count)
        var index = 0
        while index < input.count {
            let x = input[index]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            output[index] = y
            index += 1
        }
        return output
    }
}

/// One case of the healthy-speaker tests: a noise seed, and the room's signal-to-noise ratio (nil: quiet).
struct HealthyCase: Hashable, Sendable, CustomTestStringConvertible {
    let seed: UInt64
    let signalToNoise: Double?

    var testDescription: String { signalToNoise.map { "seed \(seed) at \(Int($0)) dB" } ?? "seed \(seed), quiet" }
}

/// A deterministic generator (SplitMix64), so noisy tests give the same answer every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Gaussian white noise with standard deviation `rms` (Box–Muller).
    mutating func noise(count: Int, rms: Double) -> [Double] {
        (0..<count).map { _ in
            let u = Double.random(in: Double.ulpOfOne..<1, using: &self)
            let v = Double.random(in: 0..<1, using: &self)
            return rms * (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
        }
    }
}

/// A loudspeaker in a test: the sweep times `gain`, delayed by a fractional number of samples, through linear
/// `filters`, then the memoryless nonlinearity `y = x + quadratic·x² + cubic·x³`, then the band nonlinearity, plus
/// white noise, then the limiter, with silence after.
///
/// The band nonlinearity `bandQuadratic·x² + bandCubic·x³` acts only while the sweep plays `distortionBand`
/// (hertz), fading in and out over `bandFadeOctaves` inside its edges: a buzz that appears at some frequencies only.
struct SimulatedSpeaker {
    var gain: Double = 1
    var delaySamples: Double = 2400.5
    var filters: [Biquad] = []
    var quadratic: Double = 0
    var cubic: Double = 0
    var distortionBand: ClosedRange<Double>?
    var bandQuadratic: Double = 0
    var bandCubic: Double = 0
    var bandFadeOctaves: Double = 1.0 / 12
    var noiseRMS: Double = 0.001
    /// A limiter's output ceiling, applied last (after the noise), so the waveform has flat tops.
    var clipLevel: Double?
    var tailSeconds: Double = 0.3
    var seed: UInt64 = 1

    func record(_ sweep: LogSweep) -> [Float] {
        let length = sweep.sampleCount + Int(delaySamples.rounded(.up)) + Int(tailSeconds * sweep.sampleRate)
        var signal = Self.delayedSweep(sweep, by: delaySamples, length: length).map { Double($0) * gain }
        for filter in filters { signal = filter.process(signal) }
        signal = signal.map { $0 + quadratic * $0 * $0 + cubic * $0 * $0 * $0 }
        if let band = distortionBand {
            for index in signal.indices {
                let weight = bandWeight(time: (Double(index) - delaySamples) / sweep.sampleRate, band: band, sweep: sweep)
                guard weight > 0 else { continue }
                let x = signal[index]
                signal[index] = x + weight * (bandQuadratic * x * x + bandCubic * x * x * x)
            }
        }
        if noiseRMS > 0 {
            var generator = SeededGenerator(state: seed)
            signal = zip(signal, generator.noise(count: length, rms: noiseRMS)).map(+)
        }
        if let ceiling = clipLevel {
            signal = signal.map { min(max($0, -ceiling), ceiling) }
        }
        return signal.map(Float.init)
    }

    /// 0 outside `band`, rising along a raised cosine over its first and last `bandFadeOctaves`, 1 in between.
    private func bandWeight(time: Double, band: ClosedRange<Double>, sweep: LogSweep) -> Double {
        guard time >= 0, time <= sweep.duration else { return 0 }
        let frequency = sweep.frequency(at: time)
        guard band.contains(frequency) else { return 0 }
        let inside = min(log2(frequency / band.lowerBound), log2(band.upperBound / frequency))
        guard inside < bandFadeOctaves else { return 1 }
        return 0.5 * (1 - cos(Double.pi * inside / bandFadeOctaves))
    }

    private struct DelayKey: Hashable {
        let start, end, duration, sampleRate, fade: Double
        let amplitude: Float
        let delay: Double
        let length: Int
    }

    private static let delayedSweeps = OnceCache<DelayKey, [Float]>()

    /// `delayed(sweep.samples(), …)`, computed once per sweep, delay and length: every run of a test shares it.
    static func delayedSweep(_ sweep: LogSweep, by delay: Double, length: Int) -> [Float] {
        let key = DelayKey(
            start: sweep.startFrequency, end: sweep.endFrequency, duration: sweep.duration, sampleRate: sweep.sampleRate,
            fade: sweep.fadeDuration, amplitude: sweep.amplitude, delay: delay, length: length
        )
        return delayedSweeps.value(for: key) { delayed(sweep.samples(), by: delay, length: length) }
    }

    /// `signal` delayed by `delay` samples (any real number ≥ 0) into a buffer of `length`, by a linear phase
    /// shift in the frequency domain: exact for a band-limited signal.
    static func delayed(_ signal: [Float], by delay: Double, length: Int) -> [Float] {
        let size = FFT.nextPowerOfTwo(length + 1024)
        let spectrum = FFT.forward(signal, size: size)
        var real = spectrum.real
        var imaginary = spectrum.imaginary
        for bin in 0..<size {
            let signedBin = bin <= size / 2 ? Double(bin) : Double(bin - size)
            let phase = -2 * Double.pi * signedBin * delay / Double(size)
            let (c, s) = (Float(cos(phase)), Float(sin(phase)))
            (real[bin], imaginary[bin]) = (real[bin] * c - imaginary[bin] * s, real[bin] * s + imaginary[bin] * c)
        }
        return Array(FFT.inverse(ComplexSpectrum(real: real, imaginary: imaginary)).prefix(length))
    }
}

/// Values made once per key, even when tests running side by side ask for the same one at the same moment: the first
/// makes it under that key's lock and the others wait for it, instead of each making it again.
final class OnceCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private final class Entry: Sendable {
        let value = Mutex<Value?>(nil)
    }

    private let entries = Mutex([Key: Entry]())

    func value(for key: Key, make: () -> Value) -> Value {
        let entry = entries.withLock { entries in
            if let entry = entries[key] { return entry }
            let entry = Entry()
            entries[key] = entry
            return entry
        }
        return entry.value.withLock { stored in
            if let stored { return stored }
            let made = make()
            stored = made
            return made
        }
    }
}

/// The measurement every test uses: the measurement sweep's range (10 Hz to 22 kHz, so the response is trusted over
/// the whole 20 Hz–20 kHz grid) shortened to `LogSweep.minimumAccurateDuration` (3 s, the shortest for which the DSP
/// states its THD accuracy) to keep the suite fast, at 48 kHz; a noise floor measured from a second of the same noise.
enum Bench {
    static let sampleRate = 48000.0
    static let sweep = LogSweep(
        startFrequency: LogSweep.measurementStartFrequency,
        endFrequency: LogSweep.measurementEndFrequency,
        duration: LogSweep.minimumAccurateDuration,
        sampleRate: sampleRate
    )

    /// The same range over 2 s, for tests about the response alone: the response's stated accuracy holds from 1 s,
    /// and the shorter recording halves the deconvolution's transform (2^18 points instead of 2^19). Distortion read
    /// with it is less accurate than the DSP states, so no test that asserts anything about distortion uses it.
    static let responseSweep = LogSweep(
        startFrequency: LogSweep.measurementStartFrequency,
        endFrequency: LogSweep.measurementEndFrequency,
        duration: 2,
        sampleRate: sampleRate
    )

    private static let noiseFloors = OnceCache<Double, NoiseFloorReport>()

    /// The floor the app would measure before the runs: one second of the room's noise alone, with a seed of its
    /// own. As in the app, one floor serves every run in a room of that noise, so it is measured once per level.
    static func noiseFloor(rms: Double) -> NoiseFloorReport {
        noiseFloors.value(for: rms) {
            var generator = SeededGenerator(state: 0xF100)
            let quiet = generator.noise(count: Int(sampleRate), rms: rms).map(Float.init)
            return NoiseFloor.measure(quiet, sampleRate: sampleRate)
        }
    }

    /// One run of `speaker`, analysed against a floor of its own noise.
    static func analyze(_ speaker: SimulatedSpeaker, sweep: LogSweep = Bench.sweep) -> RunAnalysis {
        RunAnalyzer.analyze(
            recording: speaker.record(sweep),
            sweep: sweep,
            noiseFloor: noiseFloor(rms: max(speaker.noiseRMS, 1e-6))
        )
    }

    /// `count` runs of `speaker`, each with its own noise seed derived from `seed`; `adjust` changes run `index`.
    static func runs(
        _ speaker: SimulatedSpeaker,
        seed: UInt64 = 1,
        count: Int = 3,
        sweep: LogSweep = Bench.sweep,
        adjust: (Int, inout SimulatedSpeaker) -> Void = { _, _ in }
    ) -> [RunAnalysis] {
        analyzeAll((0..<count).map { index in
            var run = speaker
            run.seed = seed &* 7919 &+ UInt64(index)
            adjust(index, &run)
            return run
        }, sweep: sweep)
    }

    /// One run of each speaker. The runs are independent; simulating and analysing them side by side keeps the
    /// suite fast.
    static func analyzeAll(_ speakers: [SimulatedSpeaker], sweep: LogSweep = Bench.sweep) -> [RunAnalysis] {
        let results = Mutex([Int: RunAnalysis]())
        DispatchQueue.concurrentPerform(iterations: speakers.count) { index in
            let analysis = analyze(speakers[index], sweep: sweep)
            results.withLock { $0[index] = analysis }
        }
        return results.withLock { all in speakers.indices.map { all[$0]! } }
    }

    /// Three runs of `buzzing`, made once and shared: a case with the buzz in fewer runs mixes them with healthy runs.
    static let buzzingRuns = runs(buzzing)

    /// One run of `buzzing` played too loud into a limiter: clipped.
    static let clippedRun: RunAnalysis = {
        var speaker = buzzing
        speaker.gain = 2
        speaker.clipLevel = 0.3
        return analyze(speaker)
    }()

    /// One run of `healthy` in a room too loud for it.
    static let noisyRun: RunAnalysis = {
        var speaker = healthy
        speaker.noiseRMS = 0.03
        return analyze(speaker)
    }()

    /// Three runs of `healthy` for each of `HealthySpeakerTests.seeds` (in a quiet room, the speaker's own −60 dBFS of
    /// noise) and for each of `HealthySpeakerTests.noisyCases` (in a room `signalToNoise` dB under the recording),
    /// made once, in one batch, and shared by the tests. Seeded as `runs(_:seed:)` seeds them.
    static let healthyRuns: [HealthyCase: [RunAnalysis]] = {
        let cases = HealthySpeakerTests.seeds.map { HealthyCase(seed: $0, signalToNoise: nil) } + HealthySpeakerTests.noisyCases
        let speakers = cases.flatMap { item in
            (0..<3).map { index in
                var run = item.signalToNoise.map { noisy(healthy, signalToNoise: $0) } ?? healthy
                run.seed = item.seed &* 7919 &+ UInt64(index)
                return run
            }
        }
        let all = analyzeAll(speakers)
        return Dictionary(uniqueKeysWithValues: cases.enumerated().map { ($0.element, Array(all[($0.offset * 3)..<($0.offset * 3 + 3)])) })
    }()

    /// Three runs of `healthy` in a quiet room, for one of `HealthySpeakerTests.seeds`.
    static func healthyRuns(seed: UInt64) -> [RunAnalysis] { healthyRuns[HealthyCase(seed: seed, signalToNoise: nil)]! }

    /// The RMS of `healthy`'s recording without noise.
    static let healthyLevel = Double(LevelMeter.measure({ () -> [Float] in
        var quiet = healthy
        quiet.noiseRMS = 0
        return quiet.record(sweep)
    }()).rms)

    /// `speaker` in a room whose white noise lies `signalToNoise` dB under `healthy`'s recording, so the recording
    /// check reads about that ratio. A quarter of a dB is added so a ratio of exactly the gate's 20 dB is not lost
    /// to the scatter of a one-second floor.
    static func noisy(_ speaker: SimulatedSpeaker, signalToNoise: Double) -> SimulatedSpeaker {
        var noisy = speaker
        noisy.noiseRMS = healthyLevel * pow(10, -(signalToNoise + 0.25) / 20)
        return noisy
    }

    /// A healthy speaker: a woofer rolling off below 45 Hz, about 1 % distortion.
    static let healthy = SimulatedSpeaker(
        filters: [Biquad.highPass(frequency: 45, q: 0.707, sampleRate: sampleRate)],
        quadratic: 0.08,
        cubic: 0.16
    )

    /// `healthy` plus `extra` filters.
    static func healthy(with extra: [Biquad]) -> SimulatedSpeaker {
        var speaker = healthy
        speaker.filters += extra
        return speaker
    }

    /// `healthy` with a buzz while the sweep plays 72–110 Hz (about 20 % THD there). THD is only read from 80 Hz,
    /// the bottom of the DSP's trusted band for the second harmonic, so it is measured as 80–110 Hz rather than the
    /// mockup's 70–110 Hz.
    static let buzzing: SimulatedSpeaker = {
        var speaker = healthy
        speaker.distortionBand = 72...110
        speaker.bandQuadratic = 1.6
        speaker.bandCubic = 8
        return speaker
    }()
}
