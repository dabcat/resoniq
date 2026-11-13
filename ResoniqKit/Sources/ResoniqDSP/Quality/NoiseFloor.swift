import Accelerate

/// The room's noise as the microphone heard it while nothing was playing.
public struct NoiseFloorReport: Sendable, Equatable {
    /// Broadband RMS of the quiet recording, dBFS. Uncalibrated: not a sound pressure level, and not weighted to
    /// hearing, so low-frequency rumble the ear barely notices counts in full.
    public var rmsDecibels: Float

    /// Level in each octave band from 31.5 Hz to 16 kHz, dBFS (the band's share of the broadband mean square).
    /// Bands that reach above the Nyquist frequency are left out. Below about 100 Hz an iPhone microphone rolls
    /// off, so a low reading there may be the microphone, not the room.
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
    /// Nominal octave-band centres (IEC 61260), the labels in `NoiseFloorReport.bandLevels`.
    static let nominalCentres: [Float] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Measures a quiet recording. A second or more gives stable band levels down to 31.5 Hz; under 200 ms the
    /// floor cannot be shown steady.
    public static func measure(
        _ quietRecording: [Float],
        sampleRate: Double,
        thresholds: QualityThresholds = .standard
    ) -> NoiseFloorReport {
        let blocks = blockLevels(quietRecording, sampleRate: sampleRate, blockDuration: thresholds.steadinessBlockDuration)
        var fluctuation: Float = 0
        if blocks.count >= 2 {
            let sorted = blocks.sorted()
            fluctuation = sorted[sorted.count - 1] - sorted[sorted.count / 2]
        }
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

    /// Octave-band levels in dBFS, from a Welch-averaged power spectrum (Hann window, 50 % overlap).
    ///
    /// Frames are about a quarter second (16384 samples at 48 kHz, 2.9 Hz a bin) so the 31.5 Hz band, 22–44 Hz,
    /// spans several bins. Band edges are the exact base-2 centres (1000 · 2ⁿ Hz) times 2^∓½; a bin belongs to the
    /// band its frequency falls in. Scaled so the bands of a signal add up to its mean square: a sine of amplitude A
    /// reads 20·log₁₀(A/√2) in its band.
    static func octaveBandLevels(_ samples: [Float], sampleRate: Double) -> MagnitudeResponse {
        let nyquist = sampleRate / 2
        let bands: [(nominal: Float, low: Double, high: Double)] = nominalCentres.enumerated().compactMap { index, nominal in
            let centre = 1000 * pow(2, Double(index - 5))
            let low = centre / 2.squareRoot()
            guard low < nyquist else { return nil }
            return (nominal, low, min(centre * 2.squareRoot(), nyquist))
        }
        let frequencies = bands.map(\.nominal)
        guard !samples.isEmpty else {
            return MagnitudeResponse(frequencies: frequencies, decibels: frequencies.map { _ in Decibels.floor })
        }

        let size = FFT.nextPowerOfTwo(max(Int(sampleRate / 4), 2))
        let frameLength = min(size, samples.count)
        let hop = max(frameLength / 2, 1)
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameLength, isHalfWindow: false)
        let windowEnergy = vDSP.sumOfSquares(window)

        let binCount = size / 2
        var power = [Float](repeating: 0, count: binCount)
        var frames = 0
        for start in stride(from: 0, through: samples.count - frameLength, by: hop) {
            let frame = vDSP.multiply(samples[start..<(start + frameLength)], window)
            let spectrum = FFT.forward(frame, size: size)
            let real = spectrum.real[0..<binCount]
            let imaginary = spectrum.imaginary[0..<binCount]
            power = vDSP.add(power, vDSP.add(vDSP.square(real), vDSP.square(imaginary)))
            frames += 1
        }
        // One-sided: each bin above DC stands for itself and its mirror, hence the 2. Parseval and the window's
        // energy turn |X|² into mean square.
        let scale = 2 / (Float(size) * windowEnergy * Float(frames))

        let binWidth = sampleRate / Double(size)
        let levels = bands.map { band -> Float in
            let first = max(Int((band.low / binWidth).rounded(.up)), 1)
            let last = min(Int((band.high / binWidth).rounded(.up)) - 1, binCount - 1)
            guard first <= last else { return Decibels.floor }
            return Decibels.fromPower(vDSP.sum(power[first...last]) * scale)
        }
        return MagnitudeResponse(frequencies: frequencies, decibels: levels)
    }
}
