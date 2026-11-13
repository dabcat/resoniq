import Foundation

/// Joins two takes of the same sweep into the recording one uninterrupted take would have given.
///
/// The sweep is deterministic and the speaker and route are the same in both takes, so the sound that sweep sample
/// `k` makes at the microphone arrives at capture position `origin + k + D` in either take, where `origin` is where
/// the take's sweep sample 0 was (or would have been) scheduled and `D` is the route's delay. `D` is unknown, but it
/// is the same in both takes, so a position `p` in the first take and `p + Δ` in the second hold the same sound, with
/// `Δ = second.sweepOrigin − first.sweepOrigin`. The splice needs no delay estimate; only the choice of where to
/// splice does (`plan`).
public enum SweepSplicer {
    /// One take of the sweep as captured.
    public struct Take: Sendable, Equatable {
        /// Captured samples, mono.
        public var samples: [Float]
        /// The capture-timeline position of `samples[0]`.
        public var start: Int64
        /// The capture-timeline position at which the sweep's sample 0 was scheduled, or would have been for a take
        /// that starts partway in: the scheduled position of its first sample minus that sample's index in the sweep.
        public var sweepOrigin: Int64

        public init(samples: [Float], start: Int64, sweepOrigin: Int64) {
            self.samples = samples
            self.start = start
            self.sweepOrigin = sweepOrigin
        }

        public var end: Int64 { start + Int64(samples.count) }
    }

    public enum SpliceError: Error, Sendable, Equatable {
        /// The crossfade does not lie inside the first take's samples.
        case crossfadeOutsideFirstTake
        /// The second take's samples do not cover the crossfade.
        case secondTakeDoesNotCover
    }

    /// The first take up to `crossfadeAt`, a raised-cosine crossfade of `crossfadeLength` samples, then the second
    /// take to its end, all on the first take's timeline: the result has the first take's `start` and `sweepOrigin`.
    ///
    /// `crossfadeAt` is a position on the first take's timeline. It must lie before any noise in the first take and,
    /// mapped into the second, after the second take's fade in has finished and its sound has settled.
    public static func splice(
        _ first: Take,
        _ second: Take,
        crossfadeAt: Int64,
        crossfadeLength: Int
    ) throws(SpliceError) -> Take {
        precondition(crossfadeLength >= 0, "the crossfade cannot be negative")
        let firstIndex = Int(crossfadeAt - first.start)
        guard firstIndex >= 0, firstIndex + crossfadeLength <= first.samples.count else {
            throw .crossfadeOutsideFirstTake
        }
        let shift = second.sweepOrigin - first.sweepOrigin
        let secondIndex = Int(crossfadeAt + shift - second.start)
        guard secondIndex >= 0, secondIndex + crossfadeLength <= second.samples.count else {
            throw .secondTakeDoesNotCover
        }

        var samples = Array(first.samples[0..<firstIndex])
        samples.reserveCapacity(firstIndex + second.samples.count - secondIndex)
        for offset in 0..<crossfadeLength {
            // Equal gain: the two takes carry the same coherent signal, so the gains sum to one.
            let outgoing = Float(0.5 * (1 + cos(Double.pi * (Double(offset) + 0.5) / Double(crossfadeLength))))
            samples.append(outgoing * first.samples[firstIndex + offset] + (1 - outgoing) * second.samples[secondIndex + offset])
        }
        samples += second.samples[(secondIndex + crossfadeLength)...]
        return Take(samples: samples, start: first.start, sweepOrigin: first.sweepOrigin)
    }

    /// Where to resume and where to splice after noise stopped a take.
    public struct Plan: Sendable, Equatable {
        /// The sweep sample the resumed take starts from (with a fade in).
        public var resumeIndex: Int
        /// The crossfade's first position, on the interrupted take's timeline.
        public var crossfadeAt: Int64
    }

    /// The resume point and splice position for noise that began at `noiseOnset`, or nil when no splice is possible
    /// and the run must start again from the beginning.
    ///
    /// The sweep sample arriving at the onset is `onset − take.sweepOrigin − delay`. The resumed take starts
    /// `resumeOverlap` before it; the crossfade ends `noiseGuard` before the onset. The splice is refused when the
    /// resume point would be before the sweep's start, or when the crossfade would fall within `fadeIn + delayMargin`
    /// of where the interrupted take itself began (it was a resumed take that the noise caught early).
    ///
    /// - Parameters:
    ///   - noiseOnset: The capture position the noise is taken to begin at.
    ///   - take: The interrupted take: its `sweepOrigin`, and `firstIndex`, the sweep sample it started from.
    ///   - delay: The route delay estimate, samples.
    ///   - sweepCount: The sweep's length, samples.
    static func plan(
        noiseOnset: Int64,
        sweepOrigin: Int64,
        firstIndex: Int,
        delay: Int,
        sweepCount: Int,
        configuration: MeasurementConfiguration,
        sampleRate: Double
    ) -> Plan? {
        func count(_ seconds: Double) -> Int { configuration.samples(seconds, at: sampleRate) }
        let noiseIndex = Int(noiseOnset - sweepOrigin) - delay
        let crossfadeEnd = noiseIndex - count(configuration.noiseGuard)
        let crossfadeIndex = crossfadeEnd - count(configuration.crossfade)
        let resumeIndex = min(noiseIndex, sweepCount) - count(configuration.resumeOverlap)
        guard resumeIndex >= 0,
              crossfadeIndex >= resumeIndex + count(configuration.fadeIn) + count(configuration.delayMargin),
              crossfadeIndex >= firstIndex + count(configuration.fadeIn) + count(configuration.delayMargin)
        else { return nil }
        return Plan(resumeIndex: resumeIndex, crossfadeAt: noiseOnset - Int64(noiseIndex - crossfadeIndex))
    }

    /// `samples` with a raised-cosine fade in over the first `length` samples.
    static func fadedIn(_ samples: ArraySlice<Float>, length: Int) -> [Float] {
        var result = Array(samples)
        let length = min(length, result.count)
        for index in 0..<length {
            result[index] *= Float(0.5 * (1 - cos(Double.pi * Double(index) / Double(length))))
        }
        return result
    }
}
