import Accelerate

/// What a recorded steady sine contains besides the sine.
///
/// When no tone was found (silence, noise alone, a recording too short to resolve the tone, or a corrupt one),
/// `fundamentalFrequency` is nil, every percentage and level is NaN, `harmonicLevels` is empty and nothing is
/// measurable: there is no figure to report, and none is made up.
public struct ToneDistortionResult: Sendable, Equatable {
    /// Total harmonic distortion, `100·√(Σ Pₙ / P₁)` over orders 2…`ToneDistortion.maximumOrder` below Nyquist.
    /// **Net**: each harmonic's power has the noise floor's expected share in its bins taken off, so steady hiss
    /// does not raise it. (`SweepDistortion.thd` is gross instead and carries its floor beside it.)
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
    /// The tone's frequency as found in the recording, in hertz: the interpolated peak near the nominal frequency,
    /// whose multiples place the harmonics. It differs from the nominal frequency by the playback and recording
    /// clocks' disagreement. Nil when no tone was found.
    public let fundamentalFrequency: Double?
    /// What THD would read from the noise alone: the noise floor's expected share in the harmonics' bins, as a
    /// percentage of the fundamental.
    public let noiseFloorPercent: Float

    public init(
        thdPercent: Float,
        thdPlusNoisePercent: Float,
        harmonicLevels: [Int: Float],
        nonHarmonicResidue: Float,
        fundamentalFrequency: Double?,
        noiseFloorPercent: Float
    ) {
        self.thdPercent = thdPercent
        self.thdPlusNoisePercent = thdPlusNoisePercent
        self.harmonicLevels = harmonicLevels
        self.nonHarmonicResidue = nonHarmonicResidue
        self.fundamentalFrequency = fundamentalFrequency
        self.noiseFloorPercent = noiseFloorPercent
    }

    /// Whether the recording held the tone at all.
    public var isToneFound: Bool { fundamentalFrequency != nil }

    /// Whether THD is a measurement: a tone was found and the harmonics' bins held at least
    /// `SweepDistortion.measurableMarginDecibels` more power than the noise floor's share of them. When false,
    /// all that is known is that THD is below `noiseFloorPercent` raised by the margin.
    public var isMeasurable: Bool {
        guard isToneFound, noiseFloorPercent.isFinite, thdPercent.isFinite else { return false }
        let gross = thdPercent * thdPercent + noiseFloorPercent * noiseFloorPercent
        return 10 * log10(gross / (noiseFloorPercent * noiseFloorPercent)) >= SweepDistortion.measurableMarginDecibels
    }

    /// The result that says no tone was found.
    static let noTone = ToneDistortionResult(
        thdPercent: .nan, thdPlusNoisePercent: .nan, harmonicLevels: [:], nonHarmonicResidue: .nan,
        fundamentalFrequency: nil, noiseFloorPercent: .nan
    )
}

/// Distortion of a recorded steady tone, from one windowed spectrum.
///
/// The recording is windowed with `Window.blackmanHarris` (side lobes below −92 dB) and transformed. The tone is
/// located as the interpolated peak within `lobeHalfWidth` resolution bins of the nominal frequency, so a clock
/// offset between playback and recording does not move the harmonics out of their bins; each harmonic owns the bins
/// within `lobeHalfWidth` of its multiple of the located frequency, and DC owns the lowest bins. Every other bin is
/// "elsewhere". The noise floor is estimated as the median power of the elsewhere bins divided by ln 2 (the mean of
/// an exponentially distributed bin power), which a few spurious lines do not move. A tone counts as found when its
/// lobe holds at least `minimumToneToNoiseDecibels` more than the noise floor's share of it.
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
/// a recording no longer than `2 · lobeHalfWidth / frequency` seconds finds no tone.
public enum ToneDistortion {
    /// The highest harmonic order counted as harmonic distortion.
    public static let maximumOrder = 10
    /// Half the width, in resolution bins (`sampleRate / recording.count`), of the band each spectral line owns.
    /// The Blackman–Harris main lobe is ±4; one more absorbs what is left of a frequency error.
    public static let lobeHalfWidth: Double = 5
    /// How far, in dB, the tone's lobe must stand above the noise floor's share of it for a tone to count as found:
    /// 20 dB. Noise alone stands about 0 dB above it.
    public static let minimumToneToNoiseDecibels: Float = 20

    /// The distortion of the tone near `frequency` hertz in `recording`. `frequency` must lie between 0 and Nyquist
    /// (a programmer's choice); any recording a microphone can deliver gives a result, one whose
    /// `fundamentalFrequency` is nil when there is no tone to measure.
    public static func analyze(recording: [Float], frequency: Double, sampleRate: Double) -> ToneDistortionResult {
        precondition(frequency > 0 && frequency < sampleRate / 2, "the tone is not below the Nyquist frequency")
        let length = recording.count
        guard Double(length) > 2 * lobeHalfWidth * sampleRate / frequency + 1,
              LevelMeter.nonFiniteCount(recording) == 0
        else { return .noTone }
        let size = FFT.nextPowerOfTwo(length)
        let spectrum = FFT.forward(Window.blackmanHarris.apply(to: recording), size: size)
        let nyquist = size / 2
        let power = vDSP.add(vDSP.square(spectrum.real[0...nyquist]), vDSP.square(spectrum.imaginary[0...nyquist]))
        let binsPerHertz = Double(size) / sampleRate
        let halfWidth = Int((lobeHalfWidth * Double(size) / Double(length)).rounded(.up))

        func lobe(centredOn lineFrequency: Double) -> ClosedRange<Int>? {
            let centre = Int((lineFrequency * binsPerHertz).rounded())
            guard centre - halfWidth > halfWidth, centre + halfWidth <= nyquist else { return nil }
            return (centre - halfWidth)...(centre + halfWidth)
        }
        guard let nominalLobe = lobe(centredOn: frequency),
              let located = peakFrequency(in: power, within: nominalLobe, binsPerHertz: binsPerHertz),
              let fundamentalLobe = lobe(centredOn: located)
        else { return .noTone }
        var harmonicLobes: [Int: ClosedRange<Int>] = [:]
        for order in 2...maximumOrder {
            guard let range = lobe(centredOn: located * Double(order)) else { break }
            harmonicLobes[order] = range
        }

        // The bins no line owns: the stretches between DC's bins, the fundamental's lobe and the harmonics' lobes.
        let lobes = ([0...halfWidth, fundamentalLobe] + Array(harmonicLobes.values)).sorted { $0.lowerBound < $1.lowerBound }
        var elsewhere: [Float] = []
        var next = 0
        for lobe in lobes {
            if lobe.lowerBound > next { elsewhere.append(contentsOf: power[next..<lobe.lowerBound]) }
            next = max(next, lobe.upperBound + 1)
        }
        if next <= nyquist { elsewhere.append(contentsOf: power[next...nyquist]) }
        let noisePerBin = elsewhere.isEmpty ? 0 : Statistics.median(elsewhere) / Float(M_LN2)

        func netPower(_ range: ClosedRange<Int>) -> Float {
            max(vDSP.sum(power[range]) - noisePerBin * Float(range.count), 0)
        }
        let fundamentalPower = netPower(fundamentalLobe)
        let fundamentalNoise = noisePerBin * Float(fundamentalLobe.count)
        guard fundamentalPower > 0,
              fundamentalNoise == 0 || Decibels.fromPower(fundamentalPower / fundamentalNoise) >= minimumToneToNoiseDecibels
        else { return .noTone }

        let harmonicPowers = harmonicLobes.mapValues(netPower)
        let harmonicSum = harmonicPowers.values.reduce(0, +)
        let harmonicNoise = noisePerBin * Float(harmonicLobes.values.reduce(0) { $0 + $1.count })
        let total = vDSP.sum(power[(halfWidth + 1)...nyquist])
        let residue = vDSP.sum(elsewhere) - noisePerBin * Float(elsewhere.count)

        return ToneDistortionResult(
            thdPercent: 100 * (harmonicSum / fundamentalPower).squareRoot(),
            thdPlusNoisePercent: 100 * (max(total - fundamentalPower, 0) / fundamentalPower).squareRoot(),
            harmonicLevels: harmonicPowers.mapValues { Decibels.fromPower($0 / fundamentalPower) },
            nonHarmonicResidue: Decibels.fromPower(max(residue, 0) / fundamentalPower),
            fundamentalFrequency: located,
            noiseFloorPercent: 100 * (harmonicNoise / fundamentalPower).squareRoot()
        )
    }

    /// The frequency, in hertz, of the largest bin in `range`, refined between bins by a parabola through the
    /// logarithms of its power and its neighbours' (exact for a Gaussian, within a few thousandths of a bin for the
    /// Blackman–Harris main lobe). Nil when the range holds no power.
    private static func peakFrequency(in power: [Float], within range: ClosedRange<Int>, binsPerHertz: Double) -> Double? {
        guard let peak = range.max(by: { power[$0] < power[$1] }), power[peak] > 0 else { return nil }
        var offset = 0.0
        if peak > 0, peak < power.count - 1, power[peak - 1] > 0, power[peak + 1] > 0 {
            let before = log(Double(power[peak - 1]))
            let centre = log(Double(power[peak]))
            let after = log(Double(power[peak + 1]))
            let curvature = before - 2 * centre + after
            if curvature < 0 { offset = 0.5 * (before - after) / curvature }
        }
        return (Double(peak) + offset) / binsPerHertz
    }
}
