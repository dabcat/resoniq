import Foundation
import Testing
@testable import ResoniqDSP

@Suite struct DecibelTests {
    @Test(arguments: zip([1.0, 0.5, 0.1, 10.0] as [Float], [0.0, -6.0206, -20.0, 20.0] as [Float]))
    func `amplitude converts to decibels`(amplitude: Float, expected: Float) {
        #expect(abs(Decibels.fromAmplitude(amplitude) - expected) < 0.001)
    }

    @Test func `zero amplitude is the floor, not minus infinity`() {
        #expect(Decibels.fromAmplitude(0) == Decibels.floor)
    }

    @Test func `decibels convert back to amplitude`() {
        #expect(abs(Decibels.toAmplitude(-6.0206) - 0.5) < 0.0001)
    }
}

@Suite struct FFTTests {
    @Test(arguments: zip([1, 2, 3, 1000, 1024, 1025], [1, 2, 4, 1024, 1024, 2048]))
    func `next power of two`(count: Int, expected: Int) {
        #expect(FFT.nextPowerOfTwo(count) == expected)
    }

    @Test func `a sine on a bin has all its energy in that bin`() {
        let size = 1024
        let bin = 37
        let signal = (0..<size).map { Float(sin(2 * Double.pi * Double(bin) * Double($0) / Double(size))) }
        let magnitudes = FFT.forward(signal).magnitudes
        // An unnormalised transform of a unit sine puts N/2 in the bin.
        #expect(abs(magnitudes[bin] - Float(size) / 2) < 0.01)
        let rest = magnitudes[0...size / 2].enumerated().filter { $0.offset != bin }.map(\.element).max() ?? 0
        #expect(rest < 0.01)
    }

    @Test func `inverse undoes forward`() {
        var generator = SystemRandomNumberGenerator()
        let signal = (0..<512).map { _ in Float.random(in: -1...1, using: &generator) }
        let back = FFT.inverse(FFT.forward(signal))
        #expect(zip(signal, back).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    @Test func `forward pads to a power of two`() {
        #expect(FFT.forward([Float](repeating: 1, count: 1000)).count == 1024)
        #expect(FFT.forward([Float](repeating: 1, count: 100), size: 4096).count == 4096)
    }

    @Test func `bin frequency`() {
        #expect(FFT.frequency(ofBin: 512, size: 1024, sampleRate: 48000) == 24000)
        #expect(FFT.bin(nearest: 1000, size: 4096, sampleRate: 48000) == 85)
    }
}

@Suite struct LogSweepTests {
    let sweep = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 2, sampleRate: 48000)

    @Test func `has the requested length and stays under the safe level`() {
        let samples = sweep.samples()
        #expect(samples.count == 96000)
        let peak = samples.map(abs).max() ?? 0
        #expect(peak <= LogSweep.maximumAmplitude)
        #expect(peak > LogSweep.maximumAmplitude * 0.95)
    }

    @Test func `an amplitude above the safe level is clamped`() {
        let loud = LogSweep(startFrequency: 20, endFrequency: 20000, duration: 1, sampleRate: 48000, amplitude: 1)
        #expect(loud.amplitude == LogSweep.maximumAmplitude)
    }

    @Test func `starts and ends in silence so it cannot click`() {
        let samples = sweep.samples()
        #expect(abs(samples[0]) < 1e-4)
        #expect(abs(samples[samples.count - 1]) < 1e-3)
    }

    @Test(arguments: [100.0, 1000.0, 10000.0])
    func `reaches each frequency at the time the formula gives`(frequency: Double) {
        // Count zero crossings in a short stretch around the predicted time.
        let samples = sweep.samples()
        let centre = Int(sweep.time(of: frequency) * sweep.sampleRate)
        let half = Int(sweep.sampleRate * 0.02)
        let stretch = samples[(centre - half)..<(centre + half)]
        let crossings = zip(stretch, stretch.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        let measured = Double(crossings) / 2 / (Double(2 * half) / sweep.sampleRate)
        #expect(abs(measured - frequency) / frequency < 0.05)
    }

    @Test func `instantaneous frequency runs from start to end`() {
        #expect(abs(sweep.frequency(at: 0) - 20) < 1e-6)
        #expect(abs(sweep.frequency(at: 2) - 20000) < 1e-3)
    }
}

@Suite struct MagnitudeResponseTests {
    @Test func `interpolates in log frequency`() {
        let response = MagnitudeResponse(frequencies: [100, 1000, 10000], decibels: [0, -10, -20])
        #expect(abs(response.decibels(at: 316.2278) - -5) < 0.01)
        #expect(response.decibels(at: 50) == 0)
        #expect(response.decibels(at: 20000) == -20)
    }

    @Test func `a point at zero hertz does not poison the interpolation`() {
        let response = MagnitudeResponse(frequencies: [0, 100, 200], decibels: [-10, 0, 0])
        #expect(response.decibels(at: 50) == -5)
    }
}
