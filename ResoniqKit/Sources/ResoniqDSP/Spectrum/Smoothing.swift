import Foundation

/// Smoothing of a response along the frequency axis.
public enum Smoothing {
    /// How far past a window's edge, as a fraction of the edge frequency, a point still counts as inside: so
    /// a point that falls on the edge in exact arithmetic is not dropped on one side by rounding.
    public static let edgeTolerance: Double = 1e-5

    /// `response` smoothed to `1/fraction` octave: each point becomes the power average (the mean of
    /// `10^(dB/10)`, back in dB) of every point within ±`1/(2·fraction)` octave of it, edges included. The
    /// frequencies are unchanged. A point at or below 0 Hz, where an octave has no width, is kept as it is.
    ///
    /// The average is over points, not over hertz, so on a linear grid (a spectrum) the upper half of each
    /// window carries more points than the lower; on a log-spaced grid it is symmetric. A flat response stays
    /// flat, and a single spike is spread over its window and lowered by the number of points in it.
    public static func fractionalOctave(_ response: MagnitudeResponse, fraction: Int) -> MagnitudeResponse {
        precondition(fraction > 0, "fraction must be positive")
        let count = response.count
        guard count > 1 else { return response }
        let frequencies = response.frequencies.map(Double.init)
        // Running sums of power, so each window's average costs two lookups.
        var cumulative = [Double](repeating: 0, count: count + 1)
        for (index, level) in response.decibels.enumerated() {
            cumulative[index + 1] = cumulative[index] + pow(10, Double(level) / 10)
        }
        let factor = pow(2, 1 / (2 * Double(fraction)))
        var smoothed = response.decibels
        var low = 0
        var high = 0
        for index in 0..<count where frequencies[index] > 0 {
            let lowerEdge = frequencies[index] / factor * (1 - edgeTolerance)
            let upperEdge = frequencies[index] * factor * (1 + edgeTolerance)
            // Both edges only rise with the frequency, so the window slides forward.
            while low < count && frequencies[low] < lowerEdge { low += 1 }
            high = max(high, index + 1)
            while high < count && frequencies[high] <= upperEdge { high += 1 }
            let power = (cumulative[high] - cumulative[low]) / Double(high - low)
            smoothed[index] = Decibels.fromPower(Float(power))
        }
        return MagnitudeResponse(frequencies: response.frequencies, decibels: smoothed)
    }
}
