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
        // 1171.875 Hz is bin 100 of a 4096-point transform at 48 kHz.
        let signal = TestSignal.sine(frequency: 1171.875, duration: 4096 / 48000, sampleRate: 48000, fadeDuration: 0)
        let spectrum = SpectrumAnalyzer.spectrum(of: signal, sampleRate: 48000, window: .rectangular)
        let peak = spectrum.decibels.indices.max { spectrum.decibels[$0] < spectrum.decibels[$1] }
        #expect(peak == 100)
        // On a bin, with no window and no fade, the level is exact: 20·log10(0.25).
        #expect(abs(spectrum.decibels[100] - Decibels.fromAmplitude(LogSweep.maximumAmplitude)) < 0.001)
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
