import Foundation
import Testing
@testable import ResoniqDSP

@Suite struct HighOrderDistortionTests {
    static let sampleRate = 48000.0
    static let sweep = LogSweep.measurement(sampleRate: sampleRate)

    /// A floor measured from a second of white noise of `rms`, with a seed of its own, as the app measures it before
    /// the runs.
    static func floor(rms: Double) -> NoiseFloorReport {
        var generator = SeededGenerator(state: 0xF100)
        return NoiseFloor.measure(generator.noise(count: Int(sampleRate), rms: rms).map(Float.init), sampleRate: sampleRate)
    }

    static func analyse(_ recording: [Float], noiseRMS: Double) -> (high: SweepHighOrderDistortion, thd: SweepDistortion) {
        let response = Deconvolution.impulseResponse(recording: recording, sweep: sweep)
        let high = HighOrderDistortion.analyze(
            recording: recording, sweep: sweep, delay: response.delay, noise: floor(rms: noiseRMS),
            measuredBand: response.trustedBand
        )
        return (high, HarmonicDistortion.analyze(impulseResponse: response, sweep: sweep))
    }

    /// A healthy speaker: about 1 % THD from a square and a cube law, nothing above the third harmonic.
    static let clean = SimulatedSpeaker(
        delaySamples: 2400.5,
        filters: [Biquad.highPass(frequency: 45, q: 0.707, sampleRate: sampleRate)],
        quadratic: 0.08, cubic: 0.16, noiseRMS: 1e-5
    )

    static func rubbing(_ band: ClosedRange<Double> = 60...150, level: Double = 0.1) -> SimulatedSpeaker {
        var speaker = clean
        speaker.rub = Rub(band: band, level: level)
        return speaker
    }

    @Test func `it covers 40 Hz to under 2 kHz with the measurement sweep`() throws {
        let (high, _) = Self.analyse(Self.clean.record(Self.sweep), noiseRMS: 1e-5)
        let first = try #require(high.level.frequencies.first)
        let last = try #require(high.level.frequencies.last)
        #expect(first >= 40 && first < 42)
        #expect(last > 1500 && last < 2000, "\(last)")
        let upper = HighOrderDistortion.upperFrequency(sweep: Self.sweep, upper: Self.sweep.trustedBand!.upperBound)
        #expect(Double(last) <= upper)
        // Every frame's band stays above the tenth harmonic as it moves within the frame.
        let spread = HighOrderDistortion.spread(Self.sweep)
        #expect(HighOrderDistortion.band(frequency: 100, spread: spread, upper: 20000)!.lowerBound > 1000 * exp(spread))
    }

    @Test func `a clean speaker reads low, and nothing is a measurement`() {
        let (high, _) = Self.analyse(Self.clean.record(Self.sweep), noiseRMS: 1e-5)
        let worst = high.level.decibels.max() ?? 0
        print("clean speaker: worst level \(worst) dB re tone")
        #expect(worst < -70)
        #expect(!high.level.frequencies.contains { high.isMeasurable(at: $0) })
    }

    @Test func `with no noise at all a clean speaker reads under -80 dB: the tone barely leaks into the band`() {
        var speaker = Self.clean
        speaker.noiseRMS = 0
        let (high, _) = Self.analyse(speaker.record(Self.sweep), noiseRMS: 1e-7)
        let worst = high.level.decibels.max() ?? 0
        // The worst is at the bottom (−87 dB at 40 Hz), where the band starts nearest the tone's lobe; above 85 Hz
        // it is under −100 dB. Either is 30 dB or more under a good unit's reading.
        print("clean speaker, no noise: worst level \(worst) dB re tone")
        #expect(worst < -80)
        #expect(high.level.frequencies.indices.allSatisfy { high.level.frequencies[$0] < 85 || high.level.decibels[$0] < -100 })
    }

    @Test func `a rub with low THD reads high where it rubs, and low elsewhere`() throws {
        let (high, thd) = Self.analyse(Self.rubbing().record(Self.sweep), noiseRMS: 1e-5)
        for frequency: Float in [70, 90, 110, 130] {
            let level = high.levelDecibels(at: frequency)
            print("rub at \(frequency) Hz: \(level) dB re tone, floor \(high.noiseFloorDecibels(at: frequency) ?? .nan) dB, THD \(thd.thdPercent(at: max(frequency, 80))) %")
            #expect(level > -35, "\(frequency) Hz")
            #expect(high.isMeasurable(at: frequency), "\(frequency) Hz")
        }
        for frequency: Float in [90, 110, 130] {
            #expect(thd.thdPercent(at: frequency) < 10, "THD at \(frequency) Hz")
        }
        for frequency: Float in [300, 600, 1200] {
            #expect(high.levelDecibels(at: frequency) < -70, "\(frequency) Hz")
            #expect(!high.isMeasurable(at: frequency), "\(frequency) Hz")
        }
    }

    @Test(arguments: [0.001, 0.003, 0.01])
    func `steady broadband noise alone reads as its floor, never as a measurement`(rms: Double) {
        var speaker = Self.clean
        speaker.noiseRMS = rms
        speaker.seed = 77
        let (high, _) = Self.analyse(speaker.record(Self.sweep), noiseRMS: rms)
        let floor = high.noiseFloor!
        let differences = zip(high.level.decibels, floor.decibels).map { $0 - $1 }
        print("noise \(rms): level − floor from \(differences.min()!) to \(differences.max()!) dB")
        #expect(differences.allSatisfy { abs($0) < 3 })
        #expect(!high.level.frequencies.contains { high.isMeasurable(at: $0) })
    }

    @Test func `a reverberant room does not raise it: what it adds lies below the tone`() {
        let room = ReverberantRoom(directToReverberant: -6, reverberationTime: 0.6)
        var dry = Self.clean
        dry.noiseRMS = 0
        dry.tailSeconds = 1
        var generator = SeededGenerator(state: 31)
        let wet = room.apply(dry.record(Self.sweep), sampleRate: Self.sampleRate)
        let recording = zip(wet, generator.noise(count: wet.count, rms: 1e-5)).map { $0 + Float($1) }
        let (high, _) = Self.analyse(recording, noiseRMS: 1e-5)
        let worst = high.level.decibels.max() ?? 0
        print("reverberant room: worst level \(worst) dB re tone")
        #expect(worst < -65)
        #expect(!high.level.frequencies.contains { high.isMeasurable(at: $0) })
    }

    @Test func `a rub still reads in a reverberant room`() {
        let room = ReverberantRoom(directToReverberant: -6, reverberationTime: 0.6)
        var dry = Self.rubbing()
        dry.noiseRMS = 0
        dry.tailSeconds = 1
        var generator = SeededGenerator(state: 32)
        let wet = room.apply(dry.record(Self.sweep), sampleRate: Self.sampleRate)
        let recording = zip(wet, generator.noise(count: wet.count, rms: 1e-5)).map { $0 + Float($1) }
        let (high, _) = Self.analyse(recording, noiseRMS: 1e-5)
        #expect(high.levelDecibels(at: 100) > -40)
        #expect(high.isMeasurable(at: 100))
    }

    @Test(arguments: [0.03, 0.1, 0.3])
    func `on a steady tone it agrees with the tone's non-harmonic residue`(level: Double) {
        let rub = Rub(level: level)
        let tone = rub.tone(frequency: 100, amplitude: 0.25, seconds: 2, sampleRate: Self.sampleRate)
        let high = HighOrderDistortion.steadyTone(recording: tone, frequency: 100, sampleRate: Self.sampleRate)
        let residue = ToneDistortion.analyze(recording: tone, frequency: 100, sampleRate: Self.sampleRate).nonHarmonicResidue
        print("rub \(level) on a 100 Hz tone: high orders \(high) dB, tone residue \(residue) dB")
        #expect(abs(high - residue) < 2)
    }

    @Test func `the sweep reads what the steady tone reads`() {
        let rub = Rub(level: 0.1)
        var speaker = SimulatedSpeaker(delaySamples: 2400.5, noiseRMS: 1e-5)
        speaker.rub = rub
        let (high, _) = Self.analyse(speaker.record(Self.sweep), noiseRMS: 1e-5)
        for frequency in [80.0, 160, 400] {
            let tone = rub.tone(frequency: frequency, amplitude: Double(Self.sweep.amplitude), seconds: 2, sampleRate: Self.sampleRate)
            let steady = HighOrderDistortion.steadyTone(recording: tone, frequency: frequency, sampleRate: Self.sampleRate)
            let swept = Smoothing.fractionalOctave(high.level, fraction: 12).decibels(at: Float(frequency))
            print("rub at \(frequency) Hz: sweep \(swept) dB, steady tone \(steady) dB")
            #expect(abs(swept - steady) < 3, "\(frequency) Hz")
        }
    }

    @Test func `nothing is read from a recording that holds no sweep, or a corrupt one`() {
        let silent = [Float](repeating: 0, count: 1000)
        let none = HighOrderDistortion.analyze(recording: silent, sweep: Self.sweep, delay: 0, noise: Self.floor(rms: 1e-5))
        #expect(none.level.frequencies.isEmpty)
        #expect(!none.isMeasurable(at: 100))
        var corrupt = Self.clean.record(Self.sweep)
        corrupt[1000] = .nan
        let broken = HighOrderDistortion.analyze(recording: corrupt, sweep: Self.sweep, delay: 0.05, noise: Self.floor(rms: 1e-5))
        #expect(broken.level.frequencies.isEmpty)
        #expect(HighOrderDistortion.steadyTone(recording: silent, frequency: 100, sampleRate: Self.sampleRate).isNaN)
    }
}
