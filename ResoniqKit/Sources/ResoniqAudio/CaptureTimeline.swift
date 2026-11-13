import Foundation
import ResoniqDSP

/// Cuts the microphone's blocks, whatever their size, into blocks of one fixed length, and notices lost samples.
struct Reblocker {
    let length: Int
    private var pending: [Float] = []
    private var pendingStart: Int64?

    init(length: Int) {
        precondition(length > 0, "a block needs samples")
        self.length = length
    }

    /// The whole blocks completed by `block`, and whether samples were lost before it. After a gap the partial block
    /// is dropped and counting starts again from `block`.
    mutating func append(_ block: CapturedBlock) -> (blocks: [CapturedBlock], gap: Bool) {
        var gap = false
        if let start = pendingStart, start + Int64(pending.count) != block.position {
            gap = true
            pending.removeAll(keepingCapacity: true)
            pendingStart = nil
        }
        if pendingStart == nil { pendingStart = block.position }
        pending += block.samples
        var blocks: [CapturedBlock] = []
        while pending.count >= length, let start = pendingStart {
            blocks.append(CapturedBlock(position: start, samples: Array(pending[0..<length])))
            pending.removeFirst(length)
            pendingStart = start + Int64(length)
        }
        return (blocks, gap)
    }
}

/// The route delay, estimated live from the sweep tone each block holds.
///
/// A block whose strongest tone is the sweep at frequency `f` heard the sweep sample `sweep.time(of: f)` at the
/// block's centre, so the delay is the centre's position minus the take's sweep origin minus that sample. The median
/// of the recent estimates is kept. The route is the same for every run of a test, so the tracker lives as long as
/// the session. The windowed spectrum weights the block's centre, so each estimate is good to a fraction of a block;
/// a speaker whose level tilts steeply inside one block biases it by at most half a block.
struct ArrivalTracker {
    /// Below this frequency a block's spectrum cannot place the sweep in time: a bin spans too much of it.
    static let minimumFrequency = 100.0
    /// The tone must stand this far above the floor for its estimate to count. *First guess*: 20 dB.
    static let minimumPresenceDecibels: Float = 20
    /// Estimates needed before the delay is known.
    static let minimumEstimates = 2
    /// Recent estimates kept.
    static let capacity = 64

    private(set) var estimates: [Int] = []

    /// The median estimate in samples, once there are enough.
    var delay: Int? {
        guard estimates.count >= Self.minimumEstimates else { return nil }
        let sorted = estimates.sorted()
        return sorted[sorted.count / 2]
    }

    /// Adds the estimate from one block, if its tone is clearly the sweep and the delay it gives is plausible.
    mutating func observe(
        _ assessment: SweepNoiseDetector.Assessment,
        noisy: Bool,
        blockCentre: Int64,
        sweepOrigin: Int64,
        sweep: LogSweep,
        maximumDelay: Int
    ) {
        guard !noisy,
              let frequency = assessment.sweepFrequency,
              assessment.sweepPresenceDecibels >= Self.minimumPresenceDecibels,
              frequency >= Self.minimumFrequency,
              frequency <= 0.9 * sweep.endFrequency
        else { return }
        let heard = Int((sweep.time(of: frequency) * sweep.sampleRate).rounded())
        let estimate = Int(blockCentre - sweepOrigin) - heard
        // A few milliseconds early is the estimate's own error; earlier than that is not this sweep.
        guard estimate >= -Int(0.02 * sweep.sampleRate), estimate <= maximumDelay else { return }
        estimates.append(max(estimate, 0))
        if estimates.count > Self.capacity { estimates.removeFirst() }
    }
}
