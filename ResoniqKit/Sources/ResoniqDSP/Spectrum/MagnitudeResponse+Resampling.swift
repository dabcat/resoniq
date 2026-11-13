import Foundation

extension MagnitudeResponse {
    /// The response at log-spaced frequencies `lower · 2^(k / pointsPerOctave)` Hz for `k = 0, 1, …` up to and
    /// including `upper` (when it falls on the grid), each level interpolated linearly in log frequency by
    /// `decibels(at:)` and held flat beyond the ends of the response.
    ///
    /// Points at or below 0 Hz, such as a spectrum's DC bin, have no place on a log axis and are ignored, so
    /// a frequency below the first positive point takes that point's level.
    public func resampledLogarithmically(from lower: Float, to upper: Float, pointsPerOctave: Int) -> MagnitudeResponse {
        precondition(lower > 0 && upper >= lower, "the range must be positive and rising")
        precondition(pointsPerOctave > 0, "pointsPerOctave must be positive")
        let positive = zip(frequencies, decibels).filter { $0.0 > 0 }
        let source = MagnitudeResponse(frequencies: positive.map(\.0), decibels: positive.map(\.1))
        // The tolerance keeps an `upper` that lies on the grid in exact arithmetic.
        let steps = Int((Double(pointsPerOctave) * log2(Double(upper) / Double(lower)) + 1e-9).rounded(.down))
        let grid = (0...steps).map { Float(Double(lower) * pow(2, Double($0) / Double(pointsPerOctave))) }
        return MagnitudeResponse(frequencies: grid, decibels: grid.map { source.decibels(at: $0) })
    }
}
