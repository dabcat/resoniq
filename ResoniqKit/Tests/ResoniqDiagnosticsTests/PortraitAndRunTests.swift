import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

@Suite struct DriverBandTests {
    @Test func `each frequency belongs to one driver, by limits defined once`() {
        #expect(DriverBand(frequency: 90) == .woofer)
        #expect(DriverBand(frequency: DriverBand.wooferUpperFrequency) == .middle)
        #expect(DriverBand(frequency: 1020) == .middle)
        #expect(DriverBand(frequency: DriverBand.tweeterLowerFrequency) == .tweeter)
        #expect(DriverBand(frequency: 16000) == .tweeter)
        #expect(DriverBand.allCases.map(\.displayName) == ["Woofer", "Middle driver", "Tweeter"])
        #expect(DriverBand.woofer.range.upper == DriverBand.middle.range.lower)
        #expect(DriverBand.middle.range.upper == DriverBand.tweeter.range.lower)
    }

    @Test func `evidence tags have the design system's names`() {
        #expect(EvidenceTag.allCases.map(\.displayName) == ["Measured", "Inferred", "Inconclusive", "Estimate"])
    }
}

@Suite struct ResponseGridTests {
    @Test func `the grid runs from 20 Hz to 20 kHz in equal log steps`() {
        let grid = ResponseGrid.frequencies
        #expect(grid.count == ResponseGrid.count)
        #expect(abs(grid[0] - 20) < 1e-3 && abs(grid[grid.count - 1] - 20000) < 0.1)
        let ratios = zip(grid.dropFirst(), grid).map { $0 / $1 }
        #expect(ratios.allSatisfy { abs($0 - ratios[0]) < 1e-4 })
    }
}

@Suite struct RunAnalyzerTests {
    static let run = Bench.analyze(Bench.healthy)

    @Test func `a valid recording gives a response, distortion, delay and band signal-to-noise`() throws {
        guard case .valid = Self.run.verdict else {
            Issue.record("expected a valid verdict, got \(Self.run.verdict)")
            return
        }
        let measurement = try #require(Self.run.measurement)
        #expect(measurement.response.count == ResponseGrid.count)
        #expect(abs(measurement.delay - Bench.healthy.delaySamples / Bench.sampleRate) < 0.001)
        // The healthy speaker is flat from 200 Hz to 15 kHz, so the smoothed response is too.
        let flat = zip(ResponseGrid.frequencies, measurement.response).filter { $0.0 >= 200 && $0.0 <= 15000 }.map(\.1)
        #expect((flat.max()! - flat.min()!) < 1, "\(flat.max()! - flat.min()!)")
        #expect(abs(measurement.referenceLevel - flat[flat.count / 2]) < 0.5)
        // THD is reported where the second harmonic is inside the sweep, and not above it.
        #expect(measurement.thdPercent(atIndex: ResponseGrid.nearestIndex(to: 1000)) ?? 100 < 3)
        #expect(measurement.thdPercent(atIndex: ResponseGrid.count - 1) == nil)
        // White noise 60 dB down leaves every band well above the floor.
        #expect(measurement.bandSignalToNoise.count == 10)
        #expect(measurement.bandSignalToNoise.allSatisfy { $0 > 20 }, "\(measurement.bandSignalToNoise)")
    }

    @Test func `an invalid recording keeps its verdict and nothing else`() {
        var quiet = Bench.healthy
        quiet.gain = 0.01
        let run = Bench.analyze(quiet)
        guard case .tooQuiet = run.verdict else {
            Issue.record("expected too quiet, got \(run.verdict)")
            return
        }
        #expect(run.measurement == nil)
        #expect(run.record.check.problem == .tooQuiet)
        #expect(!run.isValid)
    }
}

@Suite struct PortraitProfileTests {
    static func response(dip: Float = 0) -> MagnitudeResponse {
        let frequencies = ResponseGrid.frequencies
        return MagnitudeResponse(
            frequencies: frequencies,
            decibels: frequencies.map { $0 >= 800 && $0 <= 1600 ? -12 - dip : -12 }
        )
    }

    @Test func `an even speaker gives an even shape at the reference width`() {
        let profile = PortraitProfile(response: Self.response())
        #expect(profile.frequencies == ResponseGrid.frequencies)
        #expect(profile.widths.allSatisfy { abs($0 - PortraitProfile.referenceWidth) < 1e-5 })
        #expect(profile.deviations.isEmpty)
        #expect(profile.heardUpTo == ResponseGrid.upperFrequency)
    }

    @Test func `a 6 dB dip is visible but not exaggerated`() {
        let profile = PortraitProfile(response: Self.response(dip: 6), deviations: [FrequencyRange(lower: 800, upper: 1600)])
        let inside = profile.widths[ResponseGrid.nearestIndex(to: 1100)]
        let outside = profile.widths[ResponseGrid.nearestIndex(to: 5000)]
        // A fifth narrower: plain to see, and far from vanishing.
        #expect(abs(inside / outside - 0.8) < 0.01, "\(inside / outside)")
        #expect(profile.deviations == [FrequencyRange(lower: 800, upper: 1600)])
    }

    @Test func `widths stay within 0 and 1`() {
        let frequencies = ResponseGrid.frequencies
        let wild = MagnitudeResponse(frequencies: frequencies, decibels: frequencies.map { $0 < 100 ? -80 : ($0 > 10000 ? 30 : 0) })
        let profile = PortraitProfile(response: wild)
        #expect(profile.widths.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(profile.widths[0] == 0 && profile.widths[ResponseGrid.count - 1] == 1)
    }

    @Test func `the live portrait fills upward as the sweep is heard`() throws {
        let speaker = Bench.healthy(with: [Biquad.peaking(frequency: 1000, q: 1, gain: -9, sampleRate: Bench.sampleRate)])
        let recording = speaker.record(Bench.sweep)
        let delay = speaker.delaySamples / Bench.sampleRate
        let nothing = PortraitProfile.live(envelope: LevelEnvelope(samples: [], sampleRate: Bench.sampleRate), sweep: Bench.sweep, delay: delay)
        #expect(nothing.heardUpTo == nil && nothing.widths.allSatisfy { $0 == 0 })

        // Half way through the sweep it is playing about 630 Hz: the shape stops there.
        let halfway = Int((delay + Bench.sweep.duration / 2) * Bench.sampleRate)
        var envelope = LevelEnvelope(sampleRate: Bench.sampleRate)
        envelope.append(Array(recording[..<(halfway / 2)]))
        envelope.append(Array(recording[(halfway / 2)..<halfway]))
        #expect(envelope == LevelEnvelope(samples: Array(recording[..<halfway]), sampleRate: Bench.sampleRate))
        let partial = PortraitProfile.live(envelope: envelope, sweep: Bench.sweep, delay: delay)
        let heard = try #require(partial.heardUpTo)
        #expect(isNear(heard, 632, octaves: 0.05), "\(heard)")
        #expect(partial.widths[ResponseGrid.nearestIndex(to: 300)] > 0.6)
        #expect(partial.widths[ResponseGrid.nearestIndex(to: 2000)] == 0)

        // Once the whole sweep is in, the dip at 1 kHz shows as in the finished portrait.
        let full = PortraitProfile.live(envelope: LevelEnvelope(samples: recording, sampleRate: Bench.sampleRate), sweep: Bench.sweep, delay: delay)
        let dip = full.widths[ResponseGrid.nearestIndex(to: 1000)]
        let even = full.widths[ResponseGrid.nearestIndex(to: 5000)]
        #expect(dip < even * 0.85 && dip > even * 0.5, "\(dip) vs \(even)")
        #expect(full.heardUpTo == Float(Bench.sweep.endFrequency))
    }
}
