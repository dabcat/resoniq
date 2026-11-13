import Foundation
import Testing
@testable import ResoniqDSP

/// A seeded generator, so the noise tests see the same noise on every run.
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

/// Uniform noise in −0.5…0.5: variance 1/12.
private func whiteNoise(count: Int, seed: UInt64 = 1) -> [Float] {
    var generator = SplitMix64(state: seed)
    return (0..<count).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
}

private func sine(bin: Double, size: Int, count: Int? = nil, amplitude: Double = 1) -> [Float] {
    (0..<(count ?? size)).map { Float(amplitude * sin(2 * Double.pi * bin * Double($0) / Double(size))) }
}

private func meanPowerDecibels(_ decibels: ArraySlice<Float>) -> Float {
    let power = decibels.map { pow(10, Double($0) / 10) }.reduce(0, +) / Double(decibels.count)
    return Float(10 * log10(power))
}

@Suite struct SpectrumAnalyzerTests {
    @Test func `bins run from DC to Nyquist inclusive`() {
        let spectrum = SpectrumAnalyzer.spectrum(of: [Float](repeating: 0, count: 1024), sampleRate: 48000)
        #expect(spectrum.count == 513)
        #expect(spectrum.frequencies.first == 0)
        #expect(spectrum.frequencies.last == 24000)
        #expect(abs(spectrum.frequencies[1] - 46.875) < 1e-4)
    }

    @Test(arguments: Window.allCases)
    func `a full-scale sine on a bin reads 0 dB with any window`(window: Window) {
        // A periodic cosine-sum window has exact zeros at whole-bin offsets, so the mirror image adds nothing
        // and only float rounding is left.
        let spectrum = SpectrumAnalyzer.spectrum(of: sine(bin: 100, size: 4096), sampleRate: 48000, window: window)
        #expect(abs(spectrum.decibels[100]) < 0.001)
    }

    @Test func `level follows amplitude`() {
        let spectrum = SpectrumAnalyzer.spectrum(of: sine(bin: 50, size: 2048, amplitude: 0.25), sampleRate: 48000)
        #expect(abs(spectrum.decibels[50] - -12.0412) < 0.001)
    }

    @Test(arguments: Window.allCases)
    func `DC reads its value, not double`(window: Window) {
        let spectrum = SpectrumAnalyzer.spectrum(of: [Float](repeating: 0.5, count: 1024), sampleRate: 48000, window: window)
        #expect(abs(spectrum.decibels[0] - -6.0206) < 0.001)
    }

    @Test func `zero padding keeps the level`() {
        // Bin 100 of 2048 samples is bin 200 of a 4096-point transform.
        let spectrum = SpectrumAnalyzer.spectrum(
            of: sine(bin: 100, size: 2048), sampleRate: 48000, window: .hann, size: 4096
        )
        #expect(spectrum.count == 2049)
        #expect(abs(spectrum.decibels[200]) < 0.001)
    }

    @Test func `a sine half way between bins loses the Hann scalloping loss`() {
        // Hann's response half a bin off centre: (2/π)/(1 − 1/4) → −1.4236 dB (Harris 1978). The mirror image
        // 200 bins away adds well under 0.001 dB.
        let spectrum = SpectrumAnalyzer.spectrum(of: sine(bin: 100.5, size: 4096), sampleRate: 48000, window: .hann)
        #expect(abs(spectrum.decibels[100] - -1.4236) < 0.005)
        #expect(abs(spectrum.decibels[101] - -1.4236) < 0.005)
    }

    @Test func `the averaged spectrum of a steady sine reads its level`() {
        let signal = sine(bin: 100, size: 4096, count: 48000)
        let spectrum = SpectrumAnalyzer.averagedSpectrum(of: signal, sampleRate: 48000, segmentSize: 4096)
        #expect(spectrum.count == 2049)
        // Segments start at multiples of 2048 samples, so every one holds a whole number of cycles of bin 100.
        #expect(abs(spectrum.decibels[100]) < 0.001)
    }

    @Test func `the averaged spectrum of one segment is the plain spectrum`() {
        let signal = whiteNoise(count: 1024)
        let averaged = SpectrumAnalyzer.averagedSpectrum(of: signal, sampleRate: 48000, segmentSize: 1024)
        let single = SpectrumAnalyzer.spectrum(of: signal, sampleRate: 48000, window: .hann)
        #expect(zip(averaged.decibels, single.decibels).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    @Test func `the averaged spectrum of white noise sits at the analytic noise level`() {
        // Each bin's normalised power is 4·σ²·ENBW / N. With σ² = 1/12, ENBW = 1.5 (Hann) and N = 4096 that is
        // −39.13 dB. 2 s of noise gives 45 overlapping segments of 2047 bins; the mean over all of them has a
        // standard error far below the 0.2 dB allowed.
        let signal = whiteNoise(count: 96000)
        let spectrum = SpectrumAnalyzer.averagedSpectrum(of: signal, sampleRate: 48000, segmentSize: 4096)
        let expected = Float(10 * log10(4.0 / 12 * 1.5 / 4096))
        #expect(abs(meanPowerDecibels(spectrum.decibels[1..<2048]) - expected) < 0.2)
    }

    @Test func `averaging steadies the noise`() {
        // One segment's bins scatter by about 5.6 dB (an exponential distribution in power); 45 half-overlapped
        // Hann segments cut that by roughly √(45 · 0.9), so asking for less than half is a wide margin.
        let signal = whiteNoise(count: 96000, seed: 7)
        let single = SpectrumAnalyzer.spectrum(of: Array(signal[0..<4096]), sampleRate: 48000, window: .hann)
        let averaged = SpectrumAnalyzer.averagedSpectrum(of: signal, sampleRate: 48000, segmentSize: 4096)
        func spread(_ values: ArraySlice<Float>) -> Float {
            let mean = values.reduce(0, +) / Float(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
        }
        #expect(spread(averaged.decibels[1..<2048]) < spread(single.decibels[1..<2048]) / 2)
    }

    @Test func `a signal shorter than a segment is analysed as one padded segment`() {
        let signal = sine(bin: 25, size: 1024)
        let spectrum = SpectrumAnalyzer.averagedSpectrum(of: signal, sampleRate: 48000, segmentSize: 4096)
        #expect(spectrum.count == 2049)
        #expect(abs(spectrum.decibels[100]) < 0.001)
    }
}

@Suite struct OctaveBandTests {
    @Test func `third-octave centres from 20 Hz to 20 kHz`() {
        let centres = OctaveBands.centres(fraction: 3, from: 20, to: 20000)
        #expect(centres.count == 31)
        #expect(centres.contains(1000))
        // Exact base-ten centres: 10^(n/10) Hz, so the nominal 20 Hz band is 19.953 Hz.
        #expect(abs(centres[0] - 19.9526) < 0.001)
        #expect(abs(centres[30] - 19952.6) < 0.1)
        for (low, high) in zip(centres, centres.dropFirst()) {
            #expect(abs(high / low - Float(pow(10, 0.1))) < 1e-5)
        }
    }

    @Test func `octave centres from 31.5 Hz to 16 kHz`() {
        let centres = OctaveBands.centres(fraction: 1, from: 31.5, to: 16000)
        #expect(centres.count == 10)
        #expect(abs(centres[0] - 31.6228) < 0.001)
        #expect(centres[5] == 1000)
        #expect(abs(centres[9] - 15848.9) < 0.1)
    }

    @Test(arguments: [1, 3, 6, 12])
    func `edges are a band apart and centred geometrically`(fraction: Int) {
        let edges = OctaveBands.edges(ofCentre: 1000, fraction: fraction)
        let ratio = Float(pow(10, 0.3 / Double(fraction)))
        #expect(abs(edges.upper / edges.lower - ratio) < 1e-5)
        #expect(abs((edges.lower * edges.upper).squareRoot() - 1000) < 0.01)
        let next = OctaveBands.edges(ofCentre: 1000 * ratio, fraction: fraction)
        #expect(abs(next.lower - edges.upper) < 0.01)
    }

    @Test func `a tone on a bin fills its band and no other`() throws {
        // 40960 Hz over 4096 points: 10 Hz bins, so 1 kHz is bin 100.
        let spectrum = SpectrumAnalyzer.spectrum(of: sine(bin: 100, size: 4096), sampleRate: 40960, window: .rectangular)
        let bands = OctaveBands.levels(of: spectrum, fraction: 3, from: 500, to: 2000)
        let index = try #require(bands.frequencies.firstIndex(of: 1000))
        #expect(abs(bands.decibels[index]) < 0.001)
        #expect(bands.decibels.enumerated().filter { $0.offset != index }.allSatisfy { $0.element < -100 })
    }

    @Test func `with the window named, a Hann-windowed tone reads its level`() {
        // Hann spreads the tone over three bins whose powers sum to ENBW = 1.5 times the peak.
        let spectrum = SpectrumAnalyzer.spectrum(of: sine(bin: 100, size: 4096), sampleRate: 40960, window: .hann)
        let raw = OctaveBands.levels(of: spectrum, fraction: 3, from: 1000, to: 1000)
        let corrected = OctaveBands.levels(of: spectrum, fraction: 3, from: 1000, to: 1000, window: .hann)
        #expect(abs(raw.decibels[0] - 1.7609) < 0.001)
        #expect(abs(corrected.decibels[0]) < 0.001)
    }

    @Test func `two tones in one band add in power`() {
        // 1000 Hz and 1050 Hz, each −6.02 dB, both in the 1 kHz third octave (891–1122 Hz): −3.01 dB together.
        let signal = zip(sine(bin: 100, size: 4096, amplitude: 0.5), sine(bin: 105, size: 4096, amplitude: 0.5)).map(+)
        let spectrum = SpectrumAnalyzer.spectrum(of: signal, sampleRate: 40960, window: .rectangular)
        let bands = OctaveBands.levels(of: spectrum, fraction: 3, from: 1000, to: 1000)
        #expect(abs(bands.decibels[0] - -3.0103) < 0.001)
    }

    @Test func `white noise rises 3 dB an octave`() {
        // 10 Hz bins: the 1 kHz octave (707.9–1412.5 Hz) holds 71 bins, the 2 kHz octave (1412.5–2818.4 Hz) 140.
        // Each band's power is bins · 4σ² / N with σ² = 1/12, N = 4096. 4 s of noise averages 79 segments, so
        // a 71-bin band is known to well within the 0.25 dB allowed.
        let spectrum = SpectrumAnalyzer.averagedSpectrum(
            of: whiteNoise(count: 4 * 40960, seed: 3), sampleRate: 40960, segmentSize: 4096
        )
        let bands = OctaveBands.levels(of: spectrum, fraction: 1, from: 1000, to: 2000, window: .hann)
        #expect(bands.count == 2)
        let perBin = 4.0 / 12 / 4096
        #expect(abs(bands.decibels[0] - Float(10 * log10(71 * perBin))) < 0.25)
        #expect(abs(bands.decibels[1] - Float(10 * log10(140 * perBin))) < 0.25)
    }

    @Test func `a band with no bins reads the floor`() {
        let spectrum = MagnitudeResponse(frequencies: [0, 1000, 2000], decibels: [0, 0, 0])
        let bands = OctaveBands.levels(of: spectrum, fraction: 3, from: 1200, to: 1600)
        #expect(bands.decibels.allSatisfy { $0 == Decibels.floor })
    }
}

@Suite struct SmoothingTests {
    /// 0, 10, 20, … 20480 Hz: a spectrum's linear grid.
    let linearGrid = (0...2048).map { Float($0) * 10 }

    @Test(arguments: [1, 3, 6, 24])
    func `a flat response stays flat`(fraction: Int) {
        let flat = MagnitudeResponse(frequencies: linearGrid, decibels: [Float](repeating: -20, count: linearGrid.count))
        let smoothed = Smoothing.fractionalOctave(flat, fraction: fraction)
        #expect(smoothed.frequencies == flat.frequencies)
        #expect(smoothed.decibels.allSatisfy { abs($0 - -20) < 1e-4 })
    }

    @Test func `a single spike is spread and lowered`() {
        var decibels = [Float](repeating: -160, count: linearGrid.count)
        decibels[100] = 0  // 1 kHz
        let smoothed = Smoothing.fractionalOctave(MagnitudeResponse(frequencies: linearGrid, decibels: decibels), fraction: 3)
        // ±1/6 octave around 1 kHz is 890.9–1122.5 Hz: the 23 points 900…1120, one of them the spike.
        #expect(abs(smoothed.decibels[100] - Float(-10 * log10(23.0))) < 0.01)
        // 1100 Hz sees the spike (its window is 980–1235 Hz); 1300 Hz (1158–1459 Hz) does not.
        #expect(smoothed.decibels[110] > -20)
        #expect(smoothed.decibels[130] < -150)
    }

    @Test(arguments: [1, 3, 6])
    func `smoothing never moves the centre of a broad bump`(fraction: Int) {
        // A bump Gaussian in log frequency, half an octave standard deviation, centred on 1 kHz, on a grid of
        // 48 points an octave: symmetric about its centre, so the smoothed peak stays on it.
        let frequencies = (0...480).map { Float(20 * pow(2, Double($0) / 48)) }
        let centre = frequencies.firstIndex { abs($0 / 1000 - 1) < 0.007 }!
        let decibels = frequencies.map { frequency -> Float in
            let octaves = log2(Double(frequency) / Double(frequencies[centre]))
            return Float(10 * exp(-octaves * octaves / (2 * 0.25)))
        }
        let smoothed = Smoothing.fractionalOctave(MagnitudeResponse(frequencies: frequencies, decibels: decibels), fraction: fraction)
        let peak = smoothed.decibels.indices.max { smoothed.decibels[$0] < smoothed.decibels[$1] }
        #expect(peak == centre)
        #expect(smoothed.decibels[centre] < 10)
    }
}

@Suite struct ResamplingTests {
    @Test func `points are log-spaced from the start to the end`() {
        let response = MagnitudeResponse(frequencies: [10, 30000], decibels: [0, 0])
        let resampled = response.resampledLogarithmically(from: 20, to: 20480, pointsPerOctave: 3)
        #expect(resampled.count == 31)
        #expect(resampled.frequencies.first == 20)
        #expect(abs(resampled.frequencies.last! - 20480) < 0.01)
        for (low, high) in zip(resampled.frequencies, resampled.frequencies.dropFirst()) {
            #expect(abs(high / low - Float(pow(2, 1.0 / 3))) < 1e-5)
        }
    }

    @Test func `a response linear in log frequency is reproduced`() {
        // 6 dB an octave, sampled sparsely: interpolation in log frequency is exact for it.
        let frequencies: [Float] = [20, 200, 2000, 20000]
        let response = MagnitudeResponse(frequencies: frequencies, decibels: frequencies.map { 6 * log2($0 / 1000) })
        let resampled = response.resampledLogarithmically(from: 25, to: 16000, pointsPerOctave: 12)
        for (frequency, level) in zip(resampled.frequencies, resampled.decibels) {
            #expect(abs(level - 6 * log2(frequency / 1000)) < 1e-3)
        }
    }

    @Test func `a spectrum with a DC bin resamples below its first bin`() {
        // The DC bin sits at 0 Hz, where a log axis has no place; it must not turn the result into NaN.
        let spectrum = SpectrumAnalyzer.spectrum(of: [Float](repeating: 0.1, count: 4096), sampleRate: 48000)
        let resampled = spectrum.resampledLogarithmically(from: 5, to: 20000, pointsPerOctave: 6)
        #expect(resampled.decibels.allSatisfy { $0.isFinite })
    }
}
