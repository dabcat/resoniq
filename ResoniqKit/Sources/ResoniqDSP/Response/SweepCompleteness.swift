import Foundation

/// Whether the sweep was there through its whole duration, and how far several runs of it agree: for a recording of
/// a sweep that someone else's player plays, which can be stopped or paused part-way.
///
/// `ImpulseResponse.capturesWholeSweep` says only whether the recording is long enough to hold the sweep. A player
/// stopped 3 s into a 4 s sweep leaves a recording just as long, whose response reads 70 dB down above 3.2 kHz; a
/// pause does the same and resumes too late to count. What sets that apart from a speaker that does not play the top
/// (a dead tweeter) is how sharply the response falls: a sweep that stops takes every frequency above it away at
/// once, while a speaker's own roll-off, even an eighth-order crossover's 48 dB an octave, falls 16 dB in a third of
/// an octave at most. So a sweep is taken to have stopped where its response falls `cliffDecibels` within
/// `cliffWidth` and never comes back up within the octave after (a room's notch does).
///
/// **What it cannot see.** A stop above `checkedBand` (the last 0.4 s of the sweep), where a lossy copy's low-pass
/// (11 kHz and up) would look the same, and a stop under it, where a speaker's own bass roll-off and the room's
/// modes are steep. The listening sessions also compare the runs with each other (`disagreement(_:)`), which catches
/// those against the other runs.
public enum SweepCompleteness {
    /// The frequencies, hertz, where a stop is looked for. *First guess*.
    public static let checkedBand: ClosedRange<Double> = 200...10000
    /// How far the response must fall within `cliffWidth` for the sweep to have stopped, dB: half again an
    /// eighth-order crossover's slope. *First guess*.
    public static let cliffDecibels: Float = 24
    /// Octaves.
    public static let cliffWidth: Double = 1.0 / 3
    /// The smoothing the response is read at, fractions of an octave: fine enough to keep a stop sharp, coarse enough
    /// to take out the comb of a room's reflections.
    public static let smoothingFraction = 12

    /// The frequency, hertz, at which the sweep in `response` stopped; nil when it was there throughout
    /// `checkedBand` (or the part of it the response trusts).
    public static func stopFrequency(of response: ImpulseResponse) -> Double? {
        guard let trusted = response.trustedBand else { return nil }
        let low = max(checkedBand.lowerBound, trusted.lowerBound)
        let high = min(checkedBand.upperBound, trusted.upperBound)
        let width = pow(2, cliffWidth)
        guard high > low * width else { return nil }
        let smoothed = Smoothing.fractionalOctave(response.frequencyResponse(), fraction: smoothingFraction)
        func level(_ frequency: Double) -> Float { smoothed.decibels(at: Float(frequency)) }
        let step = pow(2, 1.0 / 24)
        var frequency = low
        while frequency * width <= high {
            let before = level(frequency)
            if before - level(frequency * width) >= cliffDecibels {
                // Down, and staying down for an octave (or to the top of the band).
                var above = frequency * width
                var highest = -Float.infinity
                while above <= min(high, frequency * width * 2) {
                    highest = max(highest, level(above))
                    above *= step
                }
                // The middle of the fall.
                if before - highest >= cliffDecibels { return frequency * width.squareRoot() }
            }
            frequency *= step
        }
        return nil
    }

    /// For each response, how far it strays from the others, dB: the largest difference, over the band all of them
    /// trust (within 100 Hz to 16 kHz), between its third-octave-smoothed response and the median of all of them at
    /// that frequency, after each is level-matched to that median. Nil for fewer than two responses or no shared band.
    public static func disagreement(_ responses: [ImpulseResponse]) -> [Float]? {
        guard responses.count >= 2 else { return nil }
        let bands = responses.compactMap(\.trustedBand)
        guard bands.count == responses.count,
              let low = bands.map(\.lowerBound).max().map({ max($0, 100) }),
              let high = bands.map(\.upperBound).min().map({ min($0, 16000) }),
              high > low * 2 else { return nil }
        let smoothed = responses.map { Smoothing.fractionalOctave($0.frequencyResponse(), fraction: 3) }
        var frequencies: [Float] = []
        var frequency = low
        while frequency <= high {
            frequencies.append(Float(frequency))
            frequency *= pow(2, 1.0 / 12)
        }
        var levels = smoothed.map { response in frequencies.map { response.decibels(at: $0) } }
        // Level-matched: each shifted so its median difference from the median curve is zero, twice.
        for _ in 0..<2 {
            let median = frequencies.indices.map { index in Statistics.median(levels.map { $0[index] }) }
            levels = levels.map { curve in
                let shift = Statistics.median(zip(curve, median).map { $0 - $1 })
                return curve.map { $0 - shift }
            }
        }
        let median = frequencies.indices.map { index in Statistics.median(levels.map { $0[index] }) }
        return levels.map { curve in zip(curve, median).map { abs($0 - $1) }.max() ?? 0 }
    }
}
