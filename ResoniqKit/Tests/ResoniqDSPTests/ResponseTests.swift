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

    @Test func `the response of an unchanged sweep is flat at 0 dB in band`() {
        let magnitude = Deconvolution.impulseResponse(recording: Self.sweep.samples(), sweep: Self.sweep).frequencyResponse()
        #expect(magnitude.frequencies.first! >= 20 && magnitude.frequencies.last! <= 20000)
        // 0.05 dB: what is left is the low cut's tail beyond the window near 40 Hz and the band edge's ringing
        // beyond the pre window near 18 kHz, both a few thousandths of the level.
        for frequency in checkFrequencies(from: 40, to: 18000) {
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
        for frequency in checkFrequencies(from: 40, to: 18000) {
            #expect(abs(magnitude.decibels(at: frequency)) < 0.05, "at \(frequency) Hz")
        }
    }

    @Test func `a quieter recording gives a proportionally lower response`() {
        let quiet = Self.sweep.samples().map { $0 * 0.1 }
        let magnitude = Deconvolution.impulseResponse(recording: quiet, sweep: Self.sweep).frequencyResponse()
        for frequency in checkFrequencies(from: 40, to: 18000, perOctave: 1) {
            #expect(abs(magnitude.decibels(at: frequency) + 20) < 0.05, "at \(frequency) Hz")
        }
    }

    @Test func `a known filter's magnitude response is recovered`() {
        let filter = Biquad.peaking(frequency: 1000, q: 2, gain: -9, sampleRate: 48000)
        let speaker = SimulatedSpeaker(delaySamples: 300.25, filters: [filter])
        let magnitude = Deconvolution.impulseResponse(recording: speaker.record(Self.sweep), sweep: Self.sweep)
            .frequencyResponse()
        for frequency in checkFrequencies(from: 40, to: 18000, perOctave: 12) {
            let expected = Float(20 * log10(filter.magnitude(at: Double(frequency), sampleRate: 48000)))
            // 0.1 dB: interpolating the 2.9 Hz linear grid across the notch's curvature, plus the window effects above.
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

    @Test func `negative time wraps to the end of the buffer`() {
        let response = ImpulseResponse(samples: [Float](repeating: 0, count: 8).enumerated().map { $0.offset == 2 ? 1 : 0 }, sampleRate: 8)
        #expect(response.peakIndex == 2)
        #expect(response.index(atTime: -0.25) == 6)
        #expect(response.index(atOffset: -0.5) == 6)
        #expect(response.index(atOffset: 0.25) == 4)
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
