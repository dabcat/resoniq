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
/// it is looked for only when that extreme is loud enough for a limiter to act, and a run counts only when it is
/// longer than the crest of a clean sine allows (`allowsCrest`): the crest of a slow sine, quantised to 16 bits,
/// repeats one value for many samples too.
///
/// It cannot tell a limiter from a waveform that is genuinely flat (a constant offset, a square wave from a test
/// rig); a buffer with a few spikes above a limited stretch hides that stretch, because the spikes set the extreme;
/// a limiter that adds ripple or noise to its flat top, and a soft limiter that rounds the crest instead of
/// flattening it, are not caught; and mild limiting of a tone above a few hundred hertz leaves flat tops too short
/// to tell from a crest.
public enum ClippingDetector {
    /// Finds the clipped runs in `samples`.
    public static func detect(_ samples: [Float], thresholds: QualityThresholds = .standard) -> ClippingReport {
        guard !samples.isEmpty else { return ClippingReport(clippedSampleCount: 0, clippedFraction: 0, longestRun: 0) }

        var clipped = [Bool](repeating: false, count: samples.count)
        var longest = 0

        func markRuns(minimumLength: Int, where isMember: (Float) -> Bool, accept: (Range<Int>) -> Bool = { _ in true }) {
            var start = 0
            while start < samples.count {
                guard isMember(samples[start]) else { start += 1; continue }
                var end = start + 1
                while end < samples.count, isMember(samples[end]) { end += 1 }
                let length = end - start
                if length >= minimumLength, accept(start..<end) {
                    for index in start..<end { clipped[index] = true }
                    longest = max(longest, length)
                }
                start = end
            }
        }

        let fullScale = thresholds.fullScaleLevel
        markRuns(minimumLength: thresholds.fullScaleRun, where: { $0 >= fullScale })
        markRuns(minimumLength: thresholds.fullScaleRun, where: { $0 <= -fullScale })

        let keep = 1 - thresholds.flatTopTolerance
        let highest = vDSP.maximum(samples)
        if highest >= thresholds.flatTopMinimumLevel {
            let edge = highest * keep
            markRuns(minimumLength: thresholds.flatTopRun, where: { $0 >= edge }) { !allowsCrest(samples, run: $0, sign: 1) }
        }
        let lowest = vDSP.minimum(samples)
        if -lowest >= thresholds.flatTopMinimumLevel {
            let edge = lowest * keep
            markRuns(minimumLength: thresholds.flatTopRun, where: { $0 <= edge }) { !allowsCrest(samples, run: $0, sign: -1) }
        }

        let count = clipped.reduce(0) { $1 ? $0 + 1 : $0 }
        return ClippingReport(
            clippedSampleCount: count,
            clippedFraction: Float(count) / Float(samples.count),
            longestRun: longest
        )
    }

    /// Whether a clean sine could hold the samples of `run` at its crest: the run is no longer than the span over
    /// which a sine of the run's level stays within the step that ends the run.
    ///
    /// The sine's frequency comes from the zero crossings either side of the run, half a period apart (or from one,
    /// a quarter period from the run's centre, when the other lies beyond the buffer); clipping keeps them where they
    /// were. The step is the larger drop from the run's level to the first sample past each end: one quantisation
    /// step on a clean 16-bit crest, a steep slope on a clipped one. A sine of amplitude `A` stays within `d` of its
    /// crest for `2·acos(1 − d/A)/ω` samples, plus one for where the samples fall. A run that touches the buffer's
    /// edge, or has no crossing on either side, is not given the benefit of the doubt.
    static func allowsCrest(_ samples: [Float], run: Range<Int>, sign: Float) -> Bool {
        guard run.lowerBound > 0, run.upperBound < samples.count else { return false }
        var left = run.lowerBound - 1
        while left > 0, sign * samples[left] > 0 { left -= 1 }
        var right = run.upperBound
        while right < samples.count - 1, sign * samples[right] > 0 { right += 1 }
        let centre = Double(run.lowerBound + run.upperBound - 1) / 2
        let halfPeriod: Double
        switch (sign * samples[left] <= 0, sign * samples[right] <= 0) {
        case (true, true): halfPeriod = Double(right - left)
        case (true, false): halfPeriod = 2 * (centre - Double(left))
        case (false, true): halfPeriod = 2 * (Double(right) - centre)
        case (false, false): return false
        }

        let level = Double(sign * samples[run.lowerBound])
        let step = Double(max(
            sign * (samples[run.lowerBound] - samples[run.lowerBound - 1]),
            sign * (samples[run.upperBound - 1] - samples[run.upperBound])
        ))
        guard level > 0, step > 0, halfPeriod > 0 else { return false }
        let angularFrequency = Double.pi / halfPeriod
        let span = 2 * acos(max(1 - step / level, -1)) / angularFrequency + 1
        return Double(run.count) <= span
    }
}
