import Accelerate

/// What a recorded steady sine contains besides the sine.
public struct ToneDistortionResult: Sendable, Equatable {
    /// Total harmonic distortion, `100·√(Σ Pₙ / P₁)` over orders 2…`ToneDistortion.maximumOrder` below Nyquist,
    /// each harmonic's power net of the noise floor's share in its bins.
    public let thdPercent: Float
    /// Everything that is not the fundamental (harmonics, noise, hum, rattles), from just above DC to Nyquist,
    /// as a percentage of the fundamental's amplitude.
    public let thdPlusNoisePercent: Float
    /// Harmonic order → its level in dB relative to the fundamental (noise share removed; `Decibels.floor` when
    /// nothing is left).
    public let harmonicLevels: [Int: Float]
    /// The power that is neither the fundamental, nor a harmonic up to `maximumOrder`, nor the stationary noise
    /// floor's expected share, in dB relative to the fundamental; `Decibels.floor` when there is none.
    /// See `ToneDistortion` for what it does and does not distinguish.
    public let nonHarmonicResidue: Float
}

/// Distortion of a recorded steady tone, from one windowed spectrum.
///
/// The recording is windowed with a 4-term Blackman–Harris window (side lobes below −92 dB) and transformed. The
/// fundamental and each harmonic own the bins within `lobeHalfWidth` resolution bins of their frequency; DC owns
/// the lowest bins. Every other bin is "elsewhere". The noise floor is estimated as the median power of the
/// elsewhere bins divided by ln 2 (the mean of an exponentially distributed bin power), which a few spurious lines
/// do not move.
///
/// The non-harmonic residue is the elsewhere power minus the noise floor's expected share of it. It rises with
/// anything the speaker adds that is not a low-order harmonic and not steady broadband hiss: rattles, buzzes and
/// rub (which show as high-order harmonics above `maximumOrder`, sub-harmonics and impulsive broadband energy),
/// and also hum and any other tone in the room. It cannot tell a rattle in the speaker from one in the furniture,
/// a buzz from mains hum, or a defect from a passing noise (a door, a voice) during the recording; repeating the
/// measurement and comparing against a quiet recording are what separate those. A steady broadband noise is
/// subtracted, so it cannot raise the residue, but neither can a defect that only adds steady hiss.
///
/// Pass only the settled part of the tone (no fades), at least `2 · lobeHalfWidth` periods' worth of resolution:
/// the recording must be longer than `2 · lobeHalfWidth / frequency` seconds.
public enum ToneDistortion {
    /// The highest harmonic order counted as harmonic distortion.
    public static let maximumOrder = 10
    /// Half the width, in resolution bins (`sampleRate / recording.count`), of the band each spectral line owns.
    /// The Blackman–Harris main lobe is ±4; one more absorbs a slight frequency error.
    public static let lobeHalfWidth: Double = 5

    public static func analyze(recording: [Float], frequency: Double, sampleRate: Double) -> ToneDistortionResult {
        let length = recording.count
        precondition(frequency > 0 && frequency < sampleRate / 2, "the tone is not below the Nyquist frequency")
        precondition(
            Double(length) > 2 * lobeHalfWidth * sampleRate / frequency + 1,
            "the recording is too short to resolve the tone"
        )
        let size = FFT.nextPowerOfTwo(length)
        let spectrum = FFT.forward(vDSP.multiply(recording, blackmanHarris(count: length)), size: size)
        let nyquist = size / 2
        let power = vDSP.add(vDSP.square(spectrum.real[0...nyquist]), vDSP.square(spectrum.imaginary[0...nyquist]))
        let halfWidth = Int((lobeHalfWidth * Double(size) / Double(length)).rounded(.up))

        func lobe(_ lineFrequency: Double) -> ClosedRange<Int>? {
            let centre = Int((lineFrequency * Double(size) / sampleRate).rounded())
            guard centre - halfWidth > halfWidth, centre + halfWidth <= nyquist else { return nil }
            return (centre - halfWidth)...(centre + halfWidth)
        }
        guard let fundamentalLobe = lobe(frequency) else {
            preconditionFailure("the tone's lobe does not fit between DC and Nyquist")
        }
        var harmonicLobes: [Int: ClosedRange<Int>] = [:]
        for order in 2...maximumOrder {
            guard let range = lobe(frequency * Double(order)) else { break }
            harmonicLobes[order] = range
        }

        var owned = [Bool](repeating: false, count: nyquist + 1)
        for bin in 0...halfWidth { owned[bin] = true }
        for range in [fundamentalLobe] + Array(harmonicLobes.values) {
            for bin in range { owned[bin] = true }
        }
        let elsewhere = (0...nyquist).filter { !owned[$0] }.map { power[$0] }
        let noisePerBin = elsewhere.isEmpty ? 0 : median(elsewhere) / Float(M_LN2)

        func netPower(_ range: ClosedRange<Int>) -> Float {
            max(vDSP.sum(power[range]) - noisePerBin * Float(range.count), 0)
        }
        let fundamentalPower = netPower(fundamentalLobe)
        precondition(fundamentalPower > 0, "there is no tone at \(frequency) Hz in the recording")

        let harmonicPowers = harmonicLobes.mapValues(netPower)
        let harmonicSum = harmonicPowers.values.reduce(0, +)
        let total = vDSP.sum(power[(halfWidth + 1)...nyquist])
        let residue = vDSP.sum(elsewhere) - noisePerBin * Float(elsewhere.count)

        return ToneDistortionResult(
            thdPercent: 100 * (harmonicSum / fundamentalPower).squareRoot(),
            thdPlusNoisePercent: 100 * (max(total - fundamentalPower, 0) / fundamentalPower).squareRoot(),
            harmonicLevels: harmonicPowers.mapValues { Decibels.fromPower($0 / fundamentalPower) },
            nonHarmonicResidue: Decibels.fromPower(max(residue, 0) / fundamentalPower)
        )
    }

    private static func blackmanHarris(count: Int) -> [Float] {
        let a: (Double, Double, Double, Double) = (0.35875, 0.48829, 0.14128, 0.01168)
        let denominator = Double(max(count - 1, 1))
        return (0..<count).map { index in
            let x = 2 * Double.pi * Double(index) / denominator
            return Float(a.0 - a.1 * cos(x) + a.2 * cos(2 * x) - a.3 * cos(3 * x))
        }
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
