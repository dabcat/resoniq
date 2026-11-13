import Foundation
import Testing
@testable import ResoniqDSP

// MARK: - Synthetic signals

private let sampleRate = 48000.0

/// A seeded generator so every noise test sees the same samples and its tolerances hold on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Uniform white noise with the given RMS (a uniform variable on ±a has RMS a/√3).
private func whiteNoise(rms: Float, count: Int, seed: UInt64 = 7) -> [Float] {
    var generator = SplitMix64(state: seed)
    let bound = rms * sqrt(3)
    return (0..<count).map { _ in Float.random(in: -bound...bound, using: &generator) }
}

private func sine(frequency: Double, amplitude: Float, count: Int, phase: Double = 0) -> [Float] {
    (0..<count).map { Float(Double(amplitude) * sin(2 * Double.pi * frequency * Double($0) / sampleRate + phase)) }
}

private func seconds(_ duration: Double) -> Int { Int(duration * sampleRate) }

private func clamped(_ samples: [Float], to limit: Float) -> [Float] {
    samples.map { min(max($0, -limit), limit) }
}

private func decibels(_ amplitude: Float) -> Float { 20 * log10(amplitude) }

/// The name of a verdict's case, so a test can say which one it expected without matching the payload.
private func kind(of verdict: RecordingVerdict) -> String {
    switch verdict {
    case .valid: "valid"
    case .clipped: "clipped"
    case .tooQuiet: "tooQuiet"
    case .tooNoisy: "tooNoisy"
    case .silent: "silent"
    case .corrupt: "corrupt"
    }
}

// MARK: - Level

@Suite struct LevelMeterTests {
    @Test(arguments: [1.0, 0.5, 0.01] as [Float])
    func `a sine's peak is its amplitude and its RMS is 3 dB lower`(amplitude: Float) {
        // 1 kHz at 48 kHz is 48 samples a period, so a sample lands exactly on each crest.
        let level = LevelMeter.measure(sine(frequency: 1000, amplitude: amplitude, count: 4800))
        #expect(abs(level.peak - amplitude) < amplitude * 1e-5)
        #expect(abs(level.rms - amplitude / sqrt(2)) < amplitude * 1e-4)
        #expect(abs(level.peakDecibels - decibels(amplitude)) < 0.001)
        // A sine's crest factor is √2, 3.0103 dB; 0.01 dB covers Float rounding over 4800 samples.
        #expect(abs(level.crestFactorDecibels - 3.0103) < 0.01)
        #expect(abs(level.dcOffset) < 1e-5)
    }

    @Test func `a square wave has no crest`() {
        let square = (0..<4800).map { ($0 / 24) % 2 == 0 ? Float(0.5) : -0.5 }
        let level = LevelMeter.measure(square)
        #expect(abs(level.crestFactorDecibels) < 1e-4)
        #expect(abs(level.rmsDecibels - decibels(0.5)) < 1e-4)
    }

    @Test func `a constant offset shows as DC`() {
        let samples = sine(frequency: 1000, amplitude: 0.2, count: 4800).map { $0 + 0.1 }
        #expect(abs(LevelMeter.measure(samples).dcOffset - 0.1) < 1e-5)
    }

    @Test(arguments: [[Float](repeating: 0, count: 1000), []])
    func `silence and an empty buffer read as the floor`(samples: [Float]) {
        let level = LevelMeter.measure(samples)
        #expect(level.peak == 0 && level.rms == 0 && level.dcOffset == 0)
        #expect(level.peakDecibels == Decibels.floor)
        #expect(level.rmsDecibels == Decibels.floor)
        #expect(level.crestFactorDecibels == 0)
    }
}

// MARK: - Clipping

@Suite struct ClippingDetectorTests {
    @Test(arguments: [200.0, 1000.0, 10000.0], [0.0, 0.3, 1.1])
    func `a clean full-level sine is not clipped`(frequency: Double, phase: Double) {
        let report = ClippingDetector.detect(sine(frequency: frequency, amplitude: 1, count: seconds(0.5), phase: phase))
        #expect(!report.isClipped)
        #expect(report.clippedSampleCount == 0)
        #expect(report.longestRun == 0)
    }

    @Test func `one full-scale sample is not clipping`() {
        var samples = sine(frequency: 1000, amplitude: 0.3, count: seconds(0.5))
        samples[1000] = 1
        samples[5000] = -1
        let report = ClippingDetector.detect(samples)
        #expect(!report.isClipped)
        #expect(report.clippedSampleCount == 0)
    }

    @Test(arguments: [1000.0, 8000.0])
    func `a sine driven past full scale is clipped`(frequency: Double) {
        // Amplitude 2 clamped to ±1: |2 sin| ≥ 1 for two thirds of each period. At 8 kHz a period is six samples,
        // so the flat tops are two samples long, the shortest a hard clip can show.
        let samples = clamped(sine(frequency: frequency, amplitude: 2, count: seconds(0.5), phase: 0.1), to: 1)
        let report = ClippingDetector.detect(samples)
        #expect(report.isClipped)
        #expect(report.longestRun >= 2)
        // Sampling quantises each flat top to whole samples: a few percent either way at 8 kHz.
        #expect(abs(report.clippedFraction - 2.0 / 3.0) < 0.07)
    }

    @Test func `a limiter's flat top below full scale is clipped`() {
        // A 200 Hz sine of 0.8 limited at 0.5: flat while sin ≥ 0.625, which is 57 % of the time, in runs of about
        // 68 samples (half-period 120 samples × 0.57). ±2 samples covers where the run starts and ends.
        let samples = clamped(sine(frequency: 200, amplitude: 0.8, count: seconds(0.5)), to: 0.5)
        let report = ClippingDetector.detect(samples)
        #expect(report.isClipped)
        #expect(abs(report.longestRun - 68) <= 2)
        #expect(abs(report.clippedFraction - 0.570) < 0.02)
    }

    /// `samples` as a 16-bit converter delivers them.
    private func quantised(_ samples: [Float]) -> [Float] {
        samples.map { ($0 * 32768).rounded() / 32768 }
    }

    @Test(arguments: [Float(1), 2, 3.9])
    func `the app's own sweep, quantised to 16 bits, is not clipped`(gain: Float) {
        // At 20 Hz a 16-bit crest repeats its value for eight samples or more; that used to read as a limiter's
        // flat top. A sine of that level and frequency allows such a run, so it is not one.
        for sweep in [LogSweep.measurement(sampleRate: 48000), LogSweep(startFrequency: 20, endFrequency: 20000, duration: 5, sampleRate: 48000)] {
            let report = ClippingDetector.detect(quantised(sweep.samples().map { $0 * gain }))
            #expect(!report.isClipped, "gain \(gain), sweep from \(sweep.startFrequency) Hz: run \(report.longestRun)")
        }
    }

    @Test(arguments: [(20.0, Float(0.2)), (30, 0.2), (50, 0.12), (100, 0.5), (40, 0.9), (10, 0.25)])
    func `a slow clean sine is not clipped, in float or in 16 bits`(frequency: Double, amplitude: Float) {
        let clean = sine(frequency: frequency, amplitude: amplitude, count: seconds(1), phase: 0.2)
        #expect(!ClippingDetector.detect(clean).isClipped)
        #expect(!ClippingDetector.detect(quantised(clean)).isClipped)
    }

    @Test(arguments: [Float(0.6), 0.3])
    func `a limited sweep is still clipped, in float and in 16 bits`(limit: Float) {
        let limited = LogSweep.measurement(sampleRate: 48000).samples().map { min(max($0 * 3.9, -limit), limit) }
        #expect(ClippingDetector.detect(limited).isClipped)
        #expect(ClippingDetector.detect(quantised(limited)).isClipped)
    }

    @Test func `a mildly limited low tone is clipped`() {
        // 1 % over the limit at 200 Hz: flat for about eleven samples, where a clean crest of that level holds
        // within a step for at most eight.
        let limited = clamped(sine(frequency: 200, amplitude: 0.505, count: seconds(0.5)), to: 0.5)
        #expect(ClippingDetector.detect(limited).isClipped)
    }

    @Test func `silence is not clipped`() {
        #expect(!ClippingDetector.detect([Float](repeating: 0, count: 4800)).isClipped)
        #expect(!ClippingDetector.detect([]).isClipped)
    }

    @Test func `a quiet flat top is below the level where clipping is looked for`() {
        // Flat at 0.01 (−40 dBFS): no input stage clips there, so this is a quiet waveform, not a limiter.
        let samples = clamped(sine(frequency: 200, amplitude: 0.02, count: seconds(0.5)), to: 0.01)
        #expect(!ClippingDetector.detect(samples).isClipped)
    }
}

// MARK: - Noise floor

@Suite struct NoiseFloorTests {
    @Test func `bands are the ten OctaveBands octaves from 31.5 Hz to 16 kHz`() {
        let report = NoiseFloor.measure(whiteNoise(rms: 0.01, count: seconds(1)), sampleRate: sampleRate)
        #expect(report.bandLevels.frequencies == OctaveBands.centres(fraction: 1, from: 31.5, to: 16000))
        #expect(report.bandLevels.count == 10)
    }

    @Test func `the bands of white noise add up to its broadband level`() {
        // Every level is a mean square, so the bands' powers sum to the noise's variance times the share of
        // 0…Nyquist they cover (22.4 Hz to 22.4 kHz of 24 kHz). 0.1 dB: the estimate's spread over 4 s.
        let rms: Float = 0.01
        let report = NoiseFloor.measure(whiteNoise(rms: rms, count: seconds(4)), sampleRate: sampleRate)
        let total = report.bandLevels.decibels.reduce(Float(0)) { $0 + pow(10, $1 / 10) }
        let low = OctaveBands.edges(ofCentre: report.bandLevels.frequencies.first!, fraction: 1).lower
        let high = OctaveBands.edges(ofCentre: report.bandLevels.frequencies.last!, fraction: 1).upper
        let expected = rms * rms * (high - low) / Float(sampleRate / 2)
        #expect(abs(10 * log10(total) - 10 * log10(expected)) < 0.1)
    }

    @Test func `broadband level is the recording's RMS`() {
        let noise = whiteNoise(rms: 0.01, count: seconds(2))
        let report = NoiseFloor.measure(noise, sampleRate: sampleRate)
        #expect(abs(report.rmsDecibels - LevelMeter.measure(noise).rmsDecibels) < 1e-4)
        #expect(abs(report.rmsDecibels - -40) < 0.1)
    }

    @Test(arguments: [63.0, 1000.0, 8000.0])
    func `a tone lands in its own band at its RMS level`(frequency: Double) throws {
        // A sine of 0.1 has an RMS of −23.01 dBFS. Within 0.2 dB: the Hann window's main lobe lies inside the band,
        // and the remainder is the sin² ripple over a frame that holds a non-integer number of periods.
        let tone = sine(frequency: frequency, amplitude: 0.1, count: seconds(2))
        let bands = NoiseFloor.measure(tone, sampleRate: sampleRate).bandLevels
        let index = try #require(bands.frequencies.firstIndex { abs(Double($0) - frequency) / frequency < 0.02 })
        #expect(abs(bands.decibels[index] - -23.0103) < 0.2)
        // Leakage into other bands stays at least 30 dB down, so rumble and hiss can be told apart.
        for (other, level) in bands.decibels.enumerated() where other != index {
            #expect(level < bands.decibels[index] - 30)
        }
    }

    @Test(arguments: [250.0, 1000.0, 4000.0, 16000.0])
    func `white noise fills each band in proportion to its width`(nominal: Double) throws {
        // White noise of variance σ² puts σ² · width / (fs/2) into a band of the given width. 0.5 dB covers the
        // estimator's spread over 4 s and rounding the band edges to whole FFT bins (2.9 Hz apart).
        let rms: Float = 0.01
        let bands = NoiseFloor.measure(whiteNoise(rms: rms, count: seconds(4)), sampleRate: sampleRate).bandLevels
        let index = try #require(bands.frequencies.firstIndex { abs(Double($0) / nominal - 1) < 0.03 })
        let edges = OctaveBands.edges(ofCentre: bands.frequencies[index], fraction: 1)
        let width = Double(min(edges.upper, Float(sampleRate / 2)) - edges.lower)
        let expected = Decibels.fromPower(rms * rms * Float(width / (sampleRate / 2)))
        #expect(abs(bands.decibels[index] - expected) < 0.5)
    }

    @Test func `steady noise is steady`() {
        let report = NoiseFloor.measure(whiteNoise(rms: 0.01, count: seconds(2)), sampleRate: sampleRate)
        #expect(report.isSteady)
        // 4800-sample blocks of white noise vary by a few tenths of a dB.
        #expect(report.fluctuationDecibels < 1)
    }

    @Test func `someone talking over the floor makes it unsteady`() {
        // Half a second 20 dB above the rest, as a voice would be.
        var samples = whiteNoise(rms: 0.001, count: seconds(2))
        let burst = whiteNoise(rms: 0.01, count: seconds(0.5), seed: 99)
        samples.replaceSubrange(seconds(1)..<seconds(1.5), with: burst)
        let report = NoiseFloor.measure(samples, sampleRate: sampleRate)
        #expect(!report.isSteady)
        #expect(abs(report.fluctuationDecibels - 20) < 1)
    }

    @Test func `a recording too short to compare blocks is not called steady`() {
        let report = NoiseFloor.measure(whiteNoise(rms: 0.01, count: seconds(0.15)), sampleRate: sampleRate)
        #expect(!report.isSteady)
    }

    @Test func `digital silence reads as the floor in every band`() {
        let report = NoiseFloor.measure([Float](repeating: 0, count: seconds(1)), sampleRate: sampleRate)
        #expect(report.rmsDecibels == Decibels.floor)
        #expect(report.bandLevels.decibels.allSatisfy { $0 == Decibels.floor })
    }

    @Test func `bands above Nyquist are left out`() {
        // At 22.05 kHz the Nyquist frequency is 11.025 kHz: the 16 kHz band (11.2–22.4 kHz) cannot be measured.
        let report = NoiseFloor.measure(whiteNoise(rms: 0.01, count: 22050), sampleRate: 22050)
        #expect(abs(report.bandLevels.frequencies.last! - 7943.28) < 0.01)
    }
}

// MARK: - Signal to noise

@Suite struct SignalToNoiseTests {
    @Test func `ratio of two levels is the difference of their RMS in dB`() {
        let signal = LevelMeter.measure(sine(frequency: 1000, amplitude: 0.1, count: 4800))
        let noise = LevelMeter.measure(whiteNoise(rms: 0.0001, count: 48000))
        // −23.01 dBFS against −80 dBFS; the noise RMS of the seeded buffer is within 0.05 dB of its target.
        #expect(abs(SignalToNoise.ratio(signal: signal, noise: noise) - 56.99) < 0.05)
    }

    @Test func `ratio of two buffers matches the ratio of their levels`() {
        let signal = sine(frequency: 1000, amplitude: 0.1, count: 4800)
        let noise = whiteNoise(rms: 0.001, count: 4800)
        let fromBuffers = SignalToNoise.ratio(signal: signal, noise: noise)
        let fromLevels = SignalToNoise.ratio(signal: LevelMeter.measure(signal), noise: LevelMeter.measure(noise))
        #expect(fromBuffers == fromLevels)
    }

    @Test func `the same noise ten times louder is 20 dB up in every band`() {
        // Scaling a buffer by 10 scales every band's power by 100, exactly; only Float rounding remains.
        let noise = whiteNoise(rms: 0.001, count: seconds(2))
        let louder = noise.map { $0 * 10 }
        let ratios = SignalToNoise.bandRatios(signal: louder, noise: noise, sampleRate: sampleRate)
        #expect(ratios.count == 10)
        #expect(ratios.decibels.allSatisfy { abs($0 - 20) < 0.01 })
    }

    @Test func `a tone over noise stands out only in its band`() {
        let noise = whiteNoise(rms: 0.001, count: seconds(2))
        let tone = sine(frequency: 1000, amplitude: 0.1, count: seconds(2))
        let recording = zip(noise, tone).map { $0 + $1 }
        let ratios = SignalToNoise.bandRatios(signal: recording, noise: noise, sampleRate: sampleRate)
        #expect(ratios.decibels(at: 1000) > 30)
        // The tone's leakage is 30 dB under it, which still lifts the noise in the 500 Hz and 2 kHz bands a little.
        #expect(abs(ratios.decibels(at: 125)) < 0.5)
        #expect(abs(ratios.decibels(at: 8000)) < 0.5)
    }
}

// MARK: - Verdict

@Suite struct RecordingQualityTests {
    let quietRoom = NoiseFloor.measure(whiteNoise(rms: 0.0001, count: seconds(1)), sampleRate: sampleRate)

    @Test func `a loud clean recording in a quiet room is valid`() {
        let recording = sine(frequency: 1000, amplitude: 0.25, count: seconds(1))
        let verdict = RecordingQuality.assess(recording: recording, noiseFloor: quietRoom)
        guard case let .valid(level, signalToNoise) = verdict else {
            Issue.record("expected valid, got \(verdict)")
            return
        }
        #expect(abs(level.peakDecibels - decibels(0.25)) < 0.01)
        // −15.05 dBFS RMS against a −80 dBFS floor.
        #expect(abs(signalToNoise - 64.95) < 0.1)
    }

    @Test func `nothing from the microphone is silent`() {
        let verdict = RecordingQuality.assess(recording: [Float](repeating: 0, count: 48000), noiseFloor: quietRoom)
        #expect(kind(of: verdict) == "silent")
    }

    @Test func `a clipped recording is clipped`() {
        let recording = clamped(sine(frequency: 1000, amplitude: 2, count: seconds(1)), to: 1)
        guard case let .clipped(report) = RecordingQuality.assess(recording: recording, noiseFloor: quietRoom) else {
            Issue.record("expected clipped")
            return
        }
        #expect(report.clippedSampleCount > 0)
    }

    @Test func `a faint recording is too quiet`() {
        // Peak −50 dBFS: under the −40 dBFS minimum even though the room is quieter still.
        let recording = sine(frequency: 1000, amplitude: Decibels.toAmplitude(-50), count: seconds(1))
        guard case let .tooQuiet(level) = RecordingQuality.assess(recording: recording, noiseFloor: quietRoom) else {
            Issue.record("expected tooQuiet")
            return
        }
        #expect(abs(level.peakDecibels - -50) < 0.01)
    }

    @Test func `a recording barely above the room is too noisy`() {
        let loudRoom = NoiseFloor.measure(whiteNoise(rms: 0.01, count: seconds(1)), sampleRate: sampleRate)
        // −23 dBFS RMS against a −40 dBFS floor: 17 dB, under the 20 dB minimum.
        let recording = sine(frequency: 1000, amplitude: 0.1, count: seconds(1))
        guard case let .tooNoisy(signalToNoise, floor) = RecordingQuality.assess(recording: recording, noiseFloor: loudRoom) else {
            Issue.record("expected tooNoisy")
            return
        }
        #expect(abs(signalToNoise - 16.99) < 0.1)
        #expect(floor == loudRoom)
    }

    @Test func `a floor measured while someone talked makes the recording too noisy`() {
        var samples = whiteNoise(rms: 0.0001, count: seconds(2))
        samples.replaceSubrange(seconds(1)..<seconds(1.5), with: whiteNoise(rms: 0.01, count: seconds(0.5), seed: 3))
        let unsteady = NoiseFloor.measure(samples, sampleRate: sampleRate)
        let recording = sine(frequency: 1000, amplitude: 0.25, count: seconds(1))
        #expect(kind(of: RecordingQuality.assess(recording: recording, noiseFloor: unsteady)) == "tooNoisy")
    }

    @Test func `clipping wins over noise`() {
        let loudRoom = NoiseFloor.measure(whiteNoise(rms: 0.3, count: seconds(1)), sampleRate: sampleRate)
        let recording = clamped(sine(frequency: 1000, amplitude: 2, count: seconds(1)), to: 1)
        #expect(kind(of: RecordingQuality.assess(recording: recording, noiseFloor: loudRoom)) == "clipped")
    }

    @Test func `too quiet wins over too noisy, because turning it up fixes both`() {
        let loudRoom = NoiseFloor.measure(whiteNoise(rms: 0.01, count: seconds(1)), sampleRate: sampleRate)
        let recording = sine(frequency: 1000, amplitude: Decibels.toAmplitude(-50), count: seconds(1))
        #expect(kind(of: RecordingQuality.assess(recording: recording, noiseFloor: loudRoom)) == "tooQuiet")
    }

    @Test func `thresholds are a parameter`() {
        var strict = QualityThresholds.standard
        strict.minimumSignalToNoiseDecibels = 70
        let recording = sine(frequency: 1000, amplitude: 0.25, count: seconds(1))
        #expect(kind(of: RecordingQuality.assess(recording: recording, noiseFloor: quietRoom, thresholds: strict)) == "tooNoisy")
    }
}

// MARK: - Corrupt input

@Suite struct NonFiniteInputTests {
    static let corruptions: [Float] = [.nan, .infinity, -.infinity]

    /// A clean sweep-level tone with one sample replaced.
    static func recording(with value: Float, at index: Int = 5000) -> [Float] {
        var samples = sine(frequency: 1000, amplitude: 0.2, count: seconds(1))
        samples[index] = value
        return samples
    }

    @Test(arguments: corruptions)
    func `one corrupt sample makes the verdict corrupt, before anything else`(value: Float) {
        let floor = NoiseFloor.measure(whiteNoise(rms: 0.0001, count: seconds(1)), sampleRate: sampleRate)
        guard case let .corrupt(count) = RecordingQuality.assess(recording: Self.recording(with: value), noiseFloor: floor) else {
            Issue.record("expected corrupt for one \(value)")
            return
        }
        #expect(count == 1)
        // Even in an otherwise silent recording, corrupt comes first: silence would send the user to the
        // microphone permission, when the fault is in the data.
        var silent = [Float](repeating: 0, count: seconds(1))
        silent[10] = value
        #expect(kind(of: RecordingQuality.assess(recording: silent, noiseFloor: floor)) == "corrupt")
    }

    @Test(arguments: corruptions)
    func `the level of a corrupt buffer is not a number, not the floor`(value: Float) {
        let level = LevelMeter.measure(Self.recording(with: value))
        #expect(!level.isFinite)
        #expect(!level.peakDecibels.isFinite && !level.rmsDecibels.isFinite)
        #expect(LevelMeter.measure(sine(frequency: 1000, amplitude: 0.2, count: 4800)).isFinite)
    }

    @Test(arguments: corruptions)
    func `a corrupt quiet recording is neither steady nor a floor`(value: Float) {
        var quiet = whiteNoise(rms: 0.0001, count: seconds(1))
        quiet[1000] = value
        let report = NoiseFloor.measure(quiet, sampleRate: sampleRate)
        #expect(!report.isSteady)
        #expect(!report.rmsDecibels.isFinite)
        #expect(report.bandLevels.decibels.allSatisfy { !$0.isFinite })
    }

    @Test(arguments: corruptions)
    func `the gate pauses on a corrupt block and does not call it quiet`(value: Float) {
        var block = whiteNoise(rms: 0.0001, count: 4800)
        block[100] = value
        #expect(NoiseGate.isTooNoisy(block: block, baseline: -60))
        #expect(!NoiseGate.isQuietEnough(block: block, baseline: -60))
        // A corrupt baseline cannot vouch for a clean block either.
        let clean = whiteNoise(rms: 0.0001, count: 4800)
        #expect(!NoiseGate.isQuietEnough(block: clean, baseline: .nan))
        #expect(NoiseGate.isTooNoisy(block: clean, baseline: .nan))
    }

    @Test(arguments: corruptions)
    func `a spectrum of a corrupt buffer is not finite`(value: Float) {
        let spectrum = SpectrumAnalyzer.spectrum(of: Self.recording(with: value), sampleRate: sampleRate)
        #expect(spectrum.decibels.allSatisfy { !$0.isFinite })
    }
}

// MARK: - Live gate

@Suite struct NoiseGateTests {
    let baseline: Float = -60

    private func block(atDecibels level: Float) -> [Float] {
        // 100 ms of noise at the given RMS.
        whiteNoise(rms: Decibels.toAmplitude(level), count: 4800)
    }

    @Test(arguments: zip([-60, -55, -51, -49, -40] as [Float], [false, false, false, true, true]))
    func `a block is too noisy more than 10 dB over the baseline`(level: Float, expected: Bool) {
        // ±1 dB from the margin: a 4800-sample noise block reads within about 0.1 dB of its target RMS.
        #expect(NoiseGate.isTooNoisy(block: block(atDecibels: level), baseline: baseline) == expected)
    }

    @Test func `a block over the ceiling is too noisy whatever the baseline`() {
        #expect(NoiseGate.isTooNoisy(block: block(atDecibels: -25), baseline: -24))
    }

    @Test(arguments: zip([-60, -55, -53, -45] as [Float], [true, true, false, false]))
    func `quiet enough to resume means under 6 dB over the baseline`(level: Float, expected: Bool) {
        #expect(NoiseGate.isQuietEnough(block: block(atDecibels: level), baseline: baseline) == expected)
    }

    @Test func `resuming needs the block under the lower ceiling`() {
        // −32 dBFS is under the −30 dBFS pause ceiling but over the −34 dBFS resume ceiling: it stays paused.
        #expect(!NoiseGate.isTooNoisy(block: block(atDecibels: -32), baseline: -32))
        #expect(!NoiseGate.isQuietEnough(block: block(atDecibels: -32), baseline: -32))
    }

    @Test func `resume sits below pause so the gate cannot chatter`() {
        let standard = QualityThresholds.standard
        #expect(standard.resumeMarginDecibels < standard.pauseMarginDecibels)
        #expect(standard.resumeCeilingDecibels < standard.pauseCeilingDecibels)
    }
}
