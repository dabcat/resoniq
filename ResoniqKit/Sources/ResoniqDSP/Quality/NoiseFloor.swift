import Accelerate

/// The room's noise as the microphone heard it while nothing was playing.
public struct NoiseFloorReport: Sendable, Equatable {
    /// Broadband RMS of the quiet recording, dBFS. Uncalibrated: not a sound pressure level, and not weighted to
    /// hearing, so low-frequency rumble the ear barely notices counts in full.
    public var rmsDecibels: Float

    /// Level in each `OctaveBands` octave from the nominal 31.5 Hz to the nominal 16 kHz (exact centres 31.62 Hz
    /// to 15.85 kHz), dBFS RMS as `OctaveBands.levels` defines it: the band's share of the broadband mean square,
    /// so a sine reads its RMS in its band and the bands add up to `rmsDecibels` over the range they cover. A band
    /// whose lower edge is at or above the Nyquist frequency is left out. Below about 100 Hz an iPhone microphone
    /// rolls off, so a low reading there may be the microphone, not the room.
    public var bandLevels: MagnitudeResponse

    /// How far the loudest 100 ms block rose above the median block, in dB.
    public var fluctuationDecibels: Float

    /// Whether the level held still across the recording: at least two blocks were compared and none rose more
    /// than the threshold above the median. A floor measured while someone talked is not a floor. Steady is not
    /// quiet: a loud fan is steady.
    public var isSteady: Bool

    public init(rmsDecibels: Float, bandLevels: MagnitudeResponse, fluctuationDecibels: Float, isSteady: Bool) {
        self.rmsDecibels = rmsDecibels
        self.bandLevels = bandLevels
        self.fluctuationDecibels = fluctuationDecibels
        self.isSteady = isSteady
    }
}

/// Measures the noise floor from a recording of the room in silence, taken before a measurement.
public enum NoiseFloor {
    /// The nominal range of the octave bands reported, in hertz: `OctaveBands.centres(fraction: 1, from:to:)` of it
    /// gives the ten octaves 31.62 Hz to 15.85 kHz.
    static let bandRange: ClosedRange<Float> = 31.5...16000

    /// Measures a quiet recording. A second or more gives stable band levels down to 31.5 Hz; under 200 ms the
    /// floor cannot be shown steady. A recording holding a sample that is not a finite number has no floor: every
    /// level is NaN and it is not steady.
    public static func measure(
        _ quietRecording: [Float],
        sampleRate: Double,
        thresholds: QualityThresholds = .standard
    ) -> NoiseFloorReport {
        guard LevelMeter.nonFiniteCount(quietRecording) == 0 else {
            let bands = octaveBandLevels([], sampleRate: sampleRate)
            return NoiseFloorReport(
                rmsDecibels: .nan,
                bandLevels: MagnitudeResponse(frequencies: bands.frequencies, decibels: bands.decibels.map { _ in .nan }),
                fluctuationDecibels: .nan,
                isSteady: false
            )
        }
        let blocks = blockLevels(quietRecording, sampleRate: sampleRate, blockDuration: thresholds.steadinessBlockDuration)
        let fluctuation = blocks.count >= 2 ? (blocks.max() ?? 0) - Statistics.median(blocks) : 0
        return NoiseFloorReport(
            rmsDecibels: LevelMeter.measure(quietRecording).rmsDecibels,
            bandLevels: octaveBandLevels(quietRecording, sampleRate: sampleRate),
            fluctuationDecibels: fluctuation,
            isSteady: blocks.count >= 2 && fluctuation <= thresholds.maximumNoiseFluctuationDecibels
        )
    }

    /// RMS in dBFS of each whole block of `blockDuration` seconds; a trailing partial block is dropped.
    static func blockLevels(_ samples: [Float], sampleRate: Double, blockDuration: Double) -> [Float] {
        let length = max(Int((blockDuration * sampleRate).rounded()), 1)
        return stride(from: 0, through: samples.count - length, by: length).map { start in
            Decibels.fromAmplitude(vDSP.rootMeanSquare(samples[start..<(start + length)]))
        }
    }

    /// Octave-band levels in dBFS RMS (`OctaveBands.levels`) of `samples`, from `SpectrumAnalyzer`'s Welch average
    /// with a Hann window and 50 % overlap.
    ///
    /// Segments are about a quarter second (16384 samples at 48 kHz, 2.9 Hz a bin) so the 31.5 Hz band, 22–45 Hz,
    /// spans several bins. A recording shorter than a segment is one zero-padded segment, and the padding is divided
    /// out. Bands whose lower edge is at or above Nyquist are left out; an empty buffer reads `Decibels.floor`.
    static func octaveBandLevels(_ samples: [Float], sampleRate: Double) -> MagnitudeResponse {
        let segmentSize = FFT.nextPowerOfTwo(max(Int(sampleRate / 4), 16))
        let spectrum = SpectrumAnalyzer.averagedSpectrum(of: samples, sampleRate: sampleRate, segmentSize: segmentSize)
        let bands = OctaveBands.levels(
            of: spectrum,
            fraction: 1,
            from: bandRange.lowerBound,
            to: bandRange.upperBound,
            window: .hann,
            frameLength: min(max(samples.count, 1), segmentSize)
        )
        let nyquist = Float(sampleRate / 2)
        let kept = zip(bands.frequencies, bands.decibels).filter { OctaveBands.edges(ofCentre: $0.0, fraction: 1).lower < nyquist }
        return MagnitudeResponse(frequencies: kept.map(\.0), decibels: kept.map(\.1))
    }
}
