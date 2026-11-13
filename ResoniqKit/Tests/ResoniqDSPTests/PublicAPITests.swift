import Testing
import ResoniqDSP

/// Another module (ResoniqDiagnostics) builds fixtures of every result type. This file imports the module without
/// `@testable`, so it compiles only while each of these initialisers is public.
@Suite struct PublicAPITests {
    static let curve = MagnitudeResponse(frequencies: [100, 1000], decibels: [-40, -40])

    @Test func `every result type can be built from outside the module`() {
        let sweep = SweepDistortion(fundamental: Self.curve, harmonics: [2: Self.curve], thd: Self.curve, noiseFloor: Self.curve)
        #expect(abs(sweep.thdPercent(at: 500) - 1) < 1e-4)
        #expect(!sweep.isMeasurable(at: 500))

        let tone = ToneDistortionResult(
            thdPercent: 1,
            thdPlusNoisePercent: 1.2,
            harmonicLevels: [2: -40],
            nonHarmonicResidue: -90,
            fundamentalFrequency: 1000,
            noiseFloorPercent: 0.1
        )
        #expect(tone.isToneFound && tone.isMeasurable)

        let response = ImpulseResponse(
            samples: [1, 0, 0, 0], sampleRate: 48000, peakIndex: 0,
            band: 20...20000, capturedBand: 20...20000, trustedBand: 40...18000, recordingDuration: 1
        )
        #expect(response.capturesWholeSweep)

        let level = Level(peak: 0.5, rms: 0.3, dcOffset: 0)
        let clipping = ClippingReport(clippedSampleCount: 0, clippedFraction: 0, longestRun: 0)
        let floor = NoiseFloorReport(rmsDecibels: -60, bandLevels: Self.curve, fluctuationDecibels: 1, isSteady: true)
        let verdicts: [RecordingVerdict] = [
            .valid(level: level, signalToNoise: 30),
            .clipped(clipping),
            .tooQuiet(level: level),
            .tooNoisy(signalToNoise: 10, noiseFloor: floor),
            .silent(level: level),
            .corrupt(nonFiniteSampleCount: 1),
        ]
        #expect(verdicts.count == 6)
    }
}
