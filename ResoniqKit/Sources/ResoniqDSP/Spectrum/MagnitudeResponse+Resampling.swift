import Foundation

extension MagnitudeResponse {
    /// The response at log-spaced frequencies from `lower` to `upper` inclusive (`logFrequencies`), each level
    /// interpolated linearly in log frequency by `decibels(at:)` and held flat beyond the ends of the response.
    ///
    /// Points at or below 0 Hz, such as a spectrum's DC bin, have no place on a log axis and are ignored, so
    /// a frequency below the first positive point takes that point's level.
    public func resampledLogarithmically(from lower: Float, to upper: Float, pointsPerOctave: Int) -> MagnitudeResponse {
        let positive = zip(frequencies, decibels).filter { $0.0 > 0 }
        let source = MagnitudeResponse(frequencies: positive.map(\.0), decibels: positive.map(\.1))
        let grid = Self.logFrequencies(from: lower, to: upper, pointsPerOctave: pointsPerOctave)
        return MagnitudeResponse(frequencies: grid, decibels: grid.map { source.decibels(at: $0) })
    }

    /// The module's one log-frequency grid: `lower · (upper/lower)^(k/n)` for `k = 0…n`, with `n` the number of
    /// octaves times `pointsPerOctave` rounded up. Both ends are on the grid and the points are evenly spaced in log
    /// frequency, at most `1 / pointsPerOctave` octave apart and exactly that when the range is a whole number of
    /// steps. A range of zero width is the one point `lower`.
    static func logFrequencies(from lower: Float, to upper: Float, pointsPerOctave: Int) -> [Float] {
        precondition(lower > 0 && upper >= lower, "the range must be positive and rising")
        precondition(pointsPerOctave > 0, "pointsPerOctave must be positive")
        let octaves = log2(Double(upper) / Double(lower))
        // The tolerance keeps a range that is a whole number of steps in exact arithmetic from gaining one.
        let steps = Int((octaves * Double(pointsPerOctave) - 1e-9).rounded(.up))
        guard steps > 0 else { return [lower] }
        return (0...steps).map { Float(Double(lower) * pow(2, octaves * Double($0) / Double(steps))) }
    }
}
