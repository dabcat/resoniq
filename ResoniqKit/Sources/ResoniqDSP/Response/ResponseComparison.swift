import Foundation

/// Comparing two frequency responses whose absolute levels mean nothing: left against right, before against after.
///
/// The microphone is uncalibrated and the playback volume is the user's, so two responses are first brought to
/// the same level in a band where speakers are usually well behaved, and then compared point by point.
public enum ResponseComparison {
    /// The band, in hertz, whose median level is matched: above the room's modes and below the treble's beaming.
    public static let defaultMatchBand: ClosedRange<Float> = 300...3000
    /// The density of the common log-frequency grid comparisons are made on.
    public static let pointsPerOctave = 48

    /// `response` shifted by a constant number of decibels so that its median level in `band` equals
    /// `reference`'s. Medians are taken on a common log-frequency grid, so a response sampled densely in the treble
    /// (a linear FFT grid) is not weighted towards it. Frequencies are unchanged.
    ///
    /// It cannot tell a level difference from a broadband shape difference inside the band: both become a shift.
    public static func levelMatched(
        _ response: MagnitudeResponse,
        to reference: MagnitudeResponse,
        band: ClosedRange<Float> = defaultMatchBand
    ) -> MagnitudeResponse {
        let low = max(band.lowerBound, response.frequencies.first ?? 0, reference.frequencies.first ?? 0)
        let high = min(band.upperBound, response.frequencies.last ?? 0, reference.frequencies.last ?? 0)
        precondition(low < high, "the responses do not both cover the matching band")
        let grid = logGrid(from: low, to: high)
        let shift = median(grid.map(reference.decibels(at:))) - median(grid.map(response.decibels(at:)))
        return MagnitudeResponse(frequencies: response.frequencies, decibels: response.decibels.map { $0 + shift })
    }

    /// `first − second`, in dB, on a log-frequency grid (`pointsPerOctave`) over the range both cover.
    /// Level-match first when only the shape matters.
    public static func difference(_ first: MagnitudeResponse, _ second: MagnitudeResponse) -> MagnitudeResponse {
        let low = max(first.frequencies.first ?? 0, second.frequencies.first ?? 0)
        let high = min(first.frequencies.last ?? 0, second.frequencies.last ?? 0)
        precondition(low > 0 && low < high, "the responses share no frequency range")
        let grid = logGrid(from: low, to: high)
        return MagnitudeResponse(
            frequencies: grid,
            decibels: grid.map { first.decibels(at: $0) - second.decibels(at: $0) }
        )
    }

    private static func logGrid(from low: Float, to high: Float) -> [Float] {
        MagnitudeResponse.logFrequencies(from: low, to: high, pointsPerOctave: pointsPerOctave)
    }

    private static func median(_ values: [Float]) -> Float {
        Statistics.median(values)
    }
}
