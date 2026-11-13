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

    /// The level of each band in `centres(fraction:from:to:)`: the power sum of the points of `spectrum` whose
    /// frequency lies in the band (lower edge included, upper edge excluded), in decibels on the spectrum's
    /// scale. A band holding no point reads `Decibels.floor`.
    ///
    /// A window spreads each tone over `equivalentNoiseBandwidth` bins, so a raw power sum reads that much
    /// high. Name the window the spectrum was made with and the sum is divided by it: a full-scale tone then
    /// reads 0 dB, and noise reads its true power in the band. The default, rectangular, divides by 1.
    public static func levels(
        of spectrum: MagnitudeResponse,
        fraction: Int,
        from lower: Float,
        to upper: Float,
        window: Window = .rectangular
    ) -> MagnitudeResponse {
        let centres = centres(fraction: fraction, from: lower, to: upper)
        let correction = Double(window.equivalentNoiseBandwidth)
        let levels = centres.map { centre -> Float in
            let edges = edges(ofCentre: centre, fraction: fraction)
            var power = 0.0
            var found = false
            for (frequency, level) in zip(spectrum.frequencies, spectrum.decibels)
            where frequency >= edges.lower && frequency < edges.upper {
                power += pow(10, Double(level) / 10)
                found = true
            }
            return found ? Decibels.fromPower(Float(power / correction)) : Decibels.floor
        }
        return MagnitudeResponse(frequencies: centres, decibels: levels)
    }

    private static func logG(_ value: Double) -> Double {
        log(value) / log(octaveRatio)
    }
}
