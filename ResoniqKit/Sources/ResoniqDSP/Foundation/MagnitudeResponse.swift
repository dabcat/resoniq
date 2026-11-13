import Foundation

/// A level in decibels at each of a rising list of frequencies in hertz: a spectrum, a frequency response,
/// a distortion curve.
public struct MagnitudeResponse: Sendable, Equatable {
    public var frequencies: [Float]
    public var decibels: [Float]

    public init(frequencies: [Float], decibels: [Float]) {
        precondition(frequencies.count == decibels.count, "frequencies and decibels differ in length")
        self.frequencies = frequencies
        self.decibels = decibels
    }

    public var count: Int { frequencies.count }

    /// The level at `frequency`, interpolated linearly in log frequency; held flat outside the range.
    public func decibels(at frequency: Float) -> Float {
        guard let first = frequencies.first, let last = frequencies.last else { return Decibels.floor }
        if frequency <= first { return decibels[0] }
        if frequency >= last { return decibels[count - 1] }
        // First index whose frequency is above the target.
        var low = 0
        var high = count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if frequencies[middle] <= frequency { low = middle } else { high = middle }
        }
        // A point at 0 Hz has no logarithm; interpolate linearly up from it.
        let fraction = frequencies[low] > 0
            ? log(frequency / frequencies[low]) / log(frequencies[high] / frequencies[low])
            : (frequency - frequencies[low]) / (frequencies[high] - frequencies[low])
        return decibels[low] + fraction * (decibels[high] - decibels[low])
    }
}
