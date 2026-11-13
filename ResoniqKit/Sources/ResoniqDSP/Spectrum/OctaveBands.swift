import Foundation

/// Fractional-octave bands with exact base-ten centres (IEC 61260-1): band `n` of fraction `b` is centred on
/// `1000 · G^(n/b)` Hz with `G = 10^(3/10)`, so 1 kHz is always a centre and the nominal 31.5 Hz octave is
/// 31.62 Hz. For even fractions the standard offsets the centres by half a band; these do not, so that 1 kHz
/// stays a centre for every fraction.
public enum OctaveBands {
    /// The base-ten octave ratio G = 10^(3/10) ≈ 1.9953.
    public static let octaveRatio: Double = pow(10, 0.3)

    /// The frequency every band series is anchored to, in hertz.
    public static let referenceFrequency: Double = 1000

    /// The exact centres, in hertz and rising, of every `1/fraction`-octave band that overlaps `from…to` Hz
    /// (fraction 1 is octaves, 3 is third-octaves). Overlap rather than containment, so `from: 20, to: 20000`
    /// gives the 31 third-octaves whose nominal centres are 20 Hz to 20 kHz, the first exactly 19.95 Hz.
    public static func centres(fraction: Int, from lower: Float, to upper: Float) -> [Float] {
        precondition(fraction > 0, "fraction must be positive")
        precondition(lower > 0 && upper >= lower, "the range must be positive and rising")
        let halfBand = 1 / (2 * Double(fraction))
        // Band n overlaps the range when its upper edge reaches `lower` and its lower edge `upper`.
        let first = Int((Double(fraction) * logG(Double(lower) / referenceFrequency) - 0.5).rounded(.up))
        let last = Int((Double(fraction) * logG(Double(upper) / referenceFrequency) + 0.5).rounded(.down))
        guard first <= last else { return [] }
        return (first...last).compactMap { index in
            let centre = referenceFrequency * pow(octaveRatio, Double(index) / Double(fraction))
            // Drop a band that only touches the range at its edge.
            guard centre * pow(octaveRatio, halfBand) > Double(lower),
                  centre / pow(octaveRatio, halfBand) < Double(upper) else { return nil }
            return Float(centre)
        }
    }

    /// The lower and upper edges, in hertz, of the `1/fraction`-octave band centred on `centre`:
    /// `centre · G^(∓1/(2·fraction))`. Adjacent bands share an edge.
    public static func edges(ofCentre centre: Float, fraction: Int) -> (lower: Float, upper: Float) {
        precondition(fraction > 0, "fraction must be positive")
        let factor = pow(octaveRatio, 1 / (2 * Double(fraction)))
        return (Float(Double(centre) / factor), Float(Double(centre) * factor))
    }

    /// The level of each band in `centres(fraction:from:to:)`, in dBFS RMS: the band's share of the signal's mean
    /// square. A sine of amplitude `A` inside a band reads its RMS, `20·log10(A/√2)`, in that band, and the bands of
    /// a signal add up (in power) to its broadband `Level.rmsDecibels` over the range they cover. This is the
    /// module's one band level; `NoiseFloor` uses it.
    ///
    /// The level is the power sum of the points of `spectrum` (a `SpectrumAnalyzer` spectrum, DC to Nyquist) whose
    /// frequency lies in the band, lower edge included and upper excluded, divided by the number of bins a line is
    /// spread over. That number is the window's `equivalentNoiseBandwidth` times the zero padding `size /
    /// frameLength`: name the `window` the spectrum was made with, and when the transform was longer than the frame
    /// (`spectrum(of:)` of a buffer whose length is not a power of two, or `averagedSpectrum` of one shorter than a
    /// segment) the `frameLength` too. Left out, the window is rectangular and there is no padding. Points at
    /// `Decibels.floor` hold nothing; a band holding no point, or only such points, reads `Decibels.floor`.
    public static func levels(
        of spectrum: MagnitudeResponse,
        fraction: Int,
        from lower: Float,
        to upper: Float,
        window: Window = .rectangular,
        frameLength: Int? = nil
    ) -> MagnitudeResponse {
        let centres = centres(fraction: fraction, from: lower, to: upper)
        let size = 2 * max(spectrum.count - 1, 1)
        let padding = frameLength.map { Double(size) / Double(min(max($0, 1), size)) } ?? 1
        let correction = Double(window.equivalentNoiseBandwidth) * padding
        let levels = centres.map { centre -> Float in
            let edges = edges(ofCentre: centre, fraction: fraction)
            var power = 0.0
            for (frequency, level) in zip(spectrum.frequencies, spectrum.decibels)
            where frequency >= edges.lower && frequency < edges.upper && !(level <= Decibels.floor) {
                power += pow(10, Double(level) / 10)
            }
            // NaN levels poison the sum, so a corrupt spectrum gives NaN bands.
            return power > 0 || power.isNaN ? Decibels.fromPower(Float(power / correction)) : Decibels.floor
        }
        return MagnitudeResponse(frequencies: centres, decibels: levels)
    }

    private static func logG(_ value: Double) -> Double {
        log(value) / log(octaveRatio)
    }
}
