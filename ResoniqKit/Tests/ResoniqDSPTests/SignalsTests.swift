import Foundation
import Testing
@testable import ResoniqDSP

@Suite struct TestSignalTests {
    @Test func `a sine has the requested length`() {
        #expect(TestSignal.sine(frequency: 1000, duration: 0.5, sampleRate: 48000).count == 24000)
    }

    @Test func `a sine plays at the safe level by default and never above it`() {
        let quiet = TestSignal.sine(frequency: 1000, duration: 0.5, sampleRate: 48000)
        let loud = TestSignal.sine(frequency: 1000, duration: 0.5, sampleRate: 48000, amplitude: 1)
        for signal in [quiet, loud] {
            let peak = signal.map(abs).max() ?? 0
            #expect(peak <= LogSweep.maximumAmplitude)
            // 1 kHz at 48 kHz samples the crest within cos(π/48) of its peak: 0.2 % low at worst.
            #expect(peak > LogSweep.maximumAmplitude * 0.997)
        }
    }

    @Test func `a quieter amplitude is kept`() {
        let signal = TestSignal.sine(frequency: 1000, duration: 0.5, sampleRate: 48000, amplitude: 0.1)
        let peak = signal.map(abs).max() ?? 0
        #expect(abs(peak - 0.1) < 0.1 * 0.003)
    }

    @Test func `starts and ends in silence so it cannot click`() {
        let signal = TestSignal.sine(frequency: 1000, duration: 0.5, sampleRate: 48000)
        #expect(signal[0] == 0)
        #expect(abs(signal[signal.count - 1]) < 1e-6)
    }

    @Test(arguments: [100.0, 1000.0, 5000.0])
    func `no step between samples is larger than the sine and the fade allow`(frequency: Double) {
        let sampleRate = 48000.0
        let fade = 0.01
        let signal = TestSignal.sine(frequency: frequency, duration: 0.2, sampleRate: sampleRate, fadeDuration: fade)
        let amplitude = Double(LogSweep.maximumAmplitude)
        // |d/dn (g·sin)| ≤ A·(2πf/fs) + A·max|g'|, and the raised cosine's slope peaks at π/(2·fadeSamples).
        let bound = amplitude * (2 * Double.pi * frequency / sampleRate + Double.pi / (2 * fade * sampleRate))
        let largestStep = zip(signal, signal.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(Double(largestStep) <= bound * 1.001)
    }

    @Test func `a sine is at the frequency asked for`() {
        // 1171.875 Hz is bin 1600 of a 65536-point transform at 48 kHz.
        let count = 65536
        let signal = TestSignal.sine(frequency: 1171.875, duration: Double(count) / 48000, sampleRate: 48000, fadeDuration: 0)
        let spectrum = SpectrumAnalyzer.spectrum(of: signal, sampleRate: 48000, window: .rectangular)
        let peak = spectrum.decibels.indices.max { spectrum.decibels[$0] < spectrum.decibels[$1] }
        #expect(peak == 1600)
        // On a bin with no window, the line is the sine's RMS times the mean gain of the fades: a fade of 0 is
        // raised to the 5 ms minimum, 240 samples a side, and a raised cosine averages one half over its length.
        let meanGain = 1 - Double(2 * 240) * 0.5 / Double(count)
        let expected = Float(20 * log10(0.25 / 2.squareRoot() * meanGain))
        #expect(abs(spectrum.decibels[1600] - expected) < 0.002)
    }

    // MARK: Hostile parameters

    static let hostileAmplitudes: [Float] = [.nan, .infinity, -.infinity, -1, 0, 0.1, 1, 1e9, .leastNonzeroMagnitude]
    static let hostileFades: [Double] = [.nan, .infinity, -.infinity, -1, 0, 1e-5, 0.02, 100]

    /// Every sample finite, none above the safe level, and the first and last exactly zero.
    static func expectSafe(_ samples: [Float], _ label: String) {
        #expect(samples.allSatisfy { $0.isFinite }, "\(label): a sample is not finite")
        #expect(samples.allSatisfy { abs($0) <= LogSweep.maximumAmplitude }, "\(label): a sample is above the safe level")
        #expect(samples.first == 0 && samples.last == 0, "\(label): starts at \(samples.first ?? 0), ends at \(samples.last ?? 0)")
    }

    // Durations: a few samples, shorter than two minimum fades, and long enough for a full fade at each end.
    @Test(arguments: hostileAmplitudes, [0.0003, 0.008, 0.06])
    func `no amplitude or fade makes an unsafe sine`(amplitude: Float, duration: Double) {
        for fade in Self.hostileFades {
            let signal = TestSignal.sine(frequency: 997, duration: duration, sampleRate: 48000, amplitude: amplitude, fadeDuration: fade)
            Self.expectSafe(signal, "sine amplitude \(amplitude) fade \(fade) duration \(duration)")
        }
    }

    @Test(arguments: hostileAmplitudes, [0.0003, 0.008, 0.06])
    func `no amplitude or fade makes an unsafe sweep`(amplitude: Float, duration: Double) {
        for fade in Self.hostileFades {
            let sweep = LogSweep(startFrequency: 20, endFrequency: 20000, duration: duration, sampleRate: 48000, amplitude: amplitude, fadeDuration: fade)
            Self.expectSafe(sweep.samples(), "sweep amplitude \(amplitude) fade \(fade) duration \(duration)")
        }
    }

    @Test func `a non-finite amplitude is silence`() {
        for amplitude in [Float.nan, .infinity, -.infinity] {
            #expect(LogSweep(startFrequency: 20, endFrequency: 20000, duration: 1, sampleRate: 48000, amplitude: amplitude).amplitude == 0)
            #expect(TestSignal.sine(frequency: 1000, duration: 0.1, sampleRate: 48000, amplitude: amplitude).allSatisfy { $0 == 0 })
        }
    }

    @Test(arguments: [0.0, 1e-5, -1, Double.nan])
    func `a fade shorter than 5 ms is raised to it`(fade: Double) {
        let sweep = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 1, sampleRate: 48000, fadeDuration: fade)
        #expect(sweep.fadeDuration >= LogSweep.minimumFadeDuration)
        // A 5 ms raised cosine at 0.25 rises at most 0.25·π/(2·240) a sample; the sweep's own slope at 20 Hz is far
        // less, so the steps at both ends stay under that bound. Without a fade the last step was 0.13.
        let samples = sweep.samples()
        let bound = Float(0.25 * Double.pi / (2 * 240)) * 1.05
        let head = zip(samples.prefix(480), samples.prefix(480).dropFirst()).map { abs($1 - $0) }.max() ?? 0
        let tail = zip(samples.suffix(480), samples.suffix(480).dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(head <= bound)
        // At the top end the sweep plays 20 kHz, so its step is set by the tone, not the fade; the fade only has to
        // bring the last sample to zero.
        #expect(samples.last == 0)
        #expect(tail <= 2 * 0.25)
    }

    @Test func `the default fade is 20 ms`() {
        #expect(LogSweep.defaultFadeDuration == 0.02)
        #expect(LogSweep(startFrequency: 20, endFrequency: 20000, duration: 1, sampleRate: 48000).fadeDuration == 0.02)
    }

    @Test func `silence is zeros of the requested length`() {
        let silence = TestSignal.silence(duration: 0.25, sampleRate: 44100)
        #expect(silence.count == 11025)
        #expect(silence.allSatisfy { $0 == 0 })
    }
}

@Suite struct WindowTests {
    @Test(arguments: Window.allCases)
    func `coherent gain is the mean of the samples`(window: Window) {
        let samples = window.samples(count: 4096)
        let mean = samples.reduce(0, +) / Float(samples.count)
        #expect(abs(window.coherentGain - mean) < 1e-5)
    }

    @Test(arguments: Window.allCases)
    func `equivalent noise bandwidth matches its definition`(window: Window) {
        let samples = window.samples(count: 4096).map(Double.init)
        let sum = samples.reduce(0, +)
        let sumOfSquares = samples.reduce(0) { $0 + $1 * $1 }
        let enbw = Double(samples.count) * sumOfSquares / (sum * sum)
        #expect(abs(Double(window.equivalentNoiseBandwidth) - enbw) < 1e-4)
    }

    @Test(arguments: zip(Window.allCases, [1.0, 1.5, 1.3628, 2.0044] as [Float]))
    func `equivalent noise bandwidth has the published value`(window: Window, published: Float) {
        // Harris (1978), table 1, to the four places it gives.
        #expect(abs(window.equivalentNoiseBandwidth - published) < 1e-4)
    }

    @Test func `rectangular is all ones`() {
        #expect(Window.rectangular.samples(count: 64).allSatisfy { $0 == 1 })
    }

    @Test func `hann rises from zero to one at the middle`() {
        let samples = Window.hann.samples(count: 64)
        #expect(samples.count == 64)
        #expect(abs(samples[0]) < 1e-7)
        #expect(abs(samples[32] - 1) < 1e-7)
        // Periodic: symmetric about the middle, so sample n equals sample N − n.
        #expect(abs(samples[1] - samples[63]) < 1e-6)
    }

    @Test func `apply multiplies sample by sample`() {
        let signal = [Float](repeating: 2, count: 16)
        let windowed = Window.hamming.apply(to: signal)
        let expected = Window.hamming.samples(count: 16).map { $0 * 2 }
        #expect(zip(windowed, expected).allSatisfy { abs($0 - $1) < 1e-6 })
    }
}
