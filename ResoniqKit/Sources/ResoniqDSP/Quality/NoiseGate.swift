import Foundation

/// The live decision during a measurement: has the room got too loud to carry on, and is it quiet enough again?
///
/// Pure functions of one block (about 100 ms) and a baseline RMS in dBFS. The block and the baseline must be the
/// same kind of thing: a room-only block against the room's measured floor, or a block with the sweep in it against
/// the level the sweep is expected to produce there. The gate cannot tell sweep from noise, and the ceilings only
/// make sense for room-only blocks. Hysteresis and timing (how many blocks before pausing, where to resume the
/// sweep) belong to the audio session; the pause and resume thresholds are in `QualityThresholds`.
///
/// A block holding a sample that is not a finite number, or a baseline that is not one, is too noisy and never
/// quiet enough: the gate pauses rather than carry on with data it cannot read.
public enum NoiseGate {
    /// Whether `block` is more than `pauseMarginDecibels` above `baseline` (RMS, dBFS) or above
    /// `pauseCeilingDecibels`, or is not finite. One RMS and two comparisons: cheap on every block.
    public static func isTooNoisy(block: [Float], baseline: Float, thresholds: QualityThresholds = .standard) -> Bool {
        let level = LevelMeter.measure(block)
        guard level.isFinite, baseline.isFinite else { return true }
        return level.rmsDecibels - baseline > thresholds.pauseMarginDecibels
            || level.rmsDecibels > thresholds.pauseCeilingDecibels
    }

    /// Whether `block` is back within `resumeMarginDecibels` of `baseline` and under `resumeCeilingDecibels`:
    /// the "quiet enough" mark. Stricter than `isTooNoisy` by design, so a block can be neither. Never true for a
    /// block or baseline that is not finite.
    public static func isQuietEnough(block: [Float], baseline: Float, thresholds: QualityThresholds = .standard) -> Bool {
        let level = LevelMeter.measure(block)
        guard level.isFinite, baseline.isFinite else { return false }
        return level.rmsDecibels - baseline <= thresholds.resumeMarginDecibels
            && level.rmsDecibels <= thresholds.resumeCeilingDecibels
    }
}
