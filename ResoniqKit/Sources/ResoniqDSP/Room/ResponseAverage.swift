import Foundation

/// Several responses of one system made one: the seat's curve from the spots around it, and how far they disagree.
///
/// Both work on the module's one log-frequency grid (`ResponseComparison.pointsPerOctave` to the octave) over the
/// range every response covers, each response interpolated onto it by `MagnitudeResponse.decibels(at:)`; points at
/// or below 0 Hz are ignored. No responses, or responses that share no range, give an empty response, never a trap.
/// A NaN level makes that point NaN.
public enum ResponseAverage {
    /// The power average: at each frequency, the mean of `10^(dB/10)` over the responses, back in dB. Energy adds,
    /// so a dip at one spot pulls the average down less than the mean of the decibels would, and a deep notch at one
    /// spot, which is position, not system, does not dominate. Level-match first when the levels mean nothing.
    public static func power(_ responses: [MagnitudeResponse]) -> MagnitudeResponse {
        combine(responses) { levels in
            let mean = levels.reduce(0) { $0 + pow(10, Double($1) / 10) } / Double(levels.count)
            return Decibels.fromPower(Float(mean))
        }
    }

    /// The spread: at each frequency, the loudest response less the quietest, in dB. Zero where they all agree;
    /// large where the response changes from spot to spot, as a room's modes and reflections do and a speaker's
    /// own response does not.
    public static func spread(_ responses: [MagnitudeResponse]) -> MagnitudeResponse {
        combine(responses) { levels in
            levels.contains(where: \.isNaN) ? .nan : levels.max()! - levels.min()!
        }
    }

    /// The common grid, and `reduce` of the responses' levels at each point of it.
    private static func combine(_ responses: [MagnitudeResponse], _ reduce: ([Float]) -> Float) -> MagnitudeResponse {
        let empty = MagnitudeResponse(frequencies: [], decibels: [])
        let ranges = responses.map { response in
            (response.frequencies.first { $0 > 0 }, response.frequencies.last)
        }
        guard !ranges.isEmpty,
              let low = ranges.map({ $0.0 ?? .infinity }).max(),
              let high = ranges.map({ $0.1 ?? 0 }).min(),
              low.isFinite, low < high else { return empty }
        let resampled = responses.map {
            $0.resampledLogarithmically(from: low, to: high, pointsPerOctave: ResponseComparison.pointsPerOctave)
        }
        let grid = resampled[0].frequencies
        return MagnitudeResponse(
            frequencies: grid,
            decibels: grid.indices.map { index in reduce(resampled.map { $0.decibels[index] }) }
        )
    }
}
