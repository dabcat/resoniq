import Accelerate

/// What `ClippingDetector` found in a recording.
public struct ClippingReport: Sendable, Equatable {
    /// Samples that belong to a clipped run.
    public var clippedSampleCount: Int
    /// `clippedSampleCount` over the buffer's length; 0 for an empty buffer.
    public var clippedFraction: Float
    /// The longest clipped run, in samples; 0 when nothing is clipped.
    public var longestRun: Int

    public init(clippedSampleCount: Int, clippedFraction: Float, longestRun: Int) {
        self.clippedSampleCount = clippedSampleCount
        self.clippedFraction = clippedFraction
        self.longestRun = longestRun
    }

    /// Whether any run of samples was clipped. One clipped run already bends the waveform the analysis relies on,
    /// so there is no allowance.
    public var isClipped: Bool { clippedSampleCount > 0 }
}

/// Finds clipping: runs of samples pinned at one value where the waveform should have kept rising.
///
/// Two kinds are caught. Hard clipping is a run of samples at digital full scale. A flat top is a run at the
/// buffer's own most positive or most negative value, the mark of an input limiter that clipped below full scale;
/// it is looked for only when that extreme is loud enough for a limiter to act.
///
/// It cannot tell a limiter from a waveform that is genuinely flat (a constant offset, a square wave from a test
/// rig); a buffer with a few spikes above a limited stretch hides that stretch, because the spikes set the extreme;
/// and a soft limiter that rounds the crest instead of flattening it is not caught.
public enum ClippingDetector {
    /// Finds the clipped runs in `samples`.
    public static func detect(_ samples: [Float], thresholds: QualityThresholds = .standard) -> ClippingReport {
        guard !samples.isEmpty else { return ClippingReport(clippedSampleCount: 0, clippedFraction: 0, longestRun: 0) }

        var clipped = [Bool](repeating: false, count: samples.count)
        var longest = 0

        func markRuns(minimumLength: Int, where isMember: (Float) -> Bool) {
            var start = 0
            while start < samples.count {
                guard isMember(samples[start]) else { start += 1; continue }
                var end = start + 1
                while end < samples.count, isMember(samples[end]) { end += 1 }
                let length = end - start
                if length >= minimumLength {
                    for index in start..<end { clipped[index] = true }
                    longest = max(longest, length)
                }
                start = end
            }
        }

        let fullScale = thresholds.fullScaleLevel
        markRuns(minimumLength: thresholds.fullScaleRun) { $0 >= fullScale }
        markRuns(minimumLength: thresholds.fullScaleRun) { $0 <= -fullScale }

        let keep = 1 - thresholds.flatTopTolerance
        let highest = vDSP.maximum(samples)
        if highest >= thresholds.flatTopMinimumLevel {
            let edge = highest * keep
            markRuns(minimumLength: thresholds.flatTopRun) { $0 >= edge }
        }
        let lowest = vDSP.minimum(samples)
        if -lowest >= thresholds.flatTopMinimumLevel {
            let edge = lowest * keep
            markRuns(minimumLength: thresholds.flatTopRun) { $0 <= edge }
        }

        let count = clipped.reduce(0) { $1 ? $0 + 1 : $0 }
        return ClippingReport(
            clippedSampleCount: count,
            clippedFraction: Float(count) / Float(samples.count),
            longestRun: longest
        )
    }
}
