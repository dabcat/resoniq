import Foundation
import ResoniqDSP

/// One run of the sweep, block by block: plays it, pauses for noise, resumes and splices, keeps recording until the
/// sweep has arrived and died away, and hands back the recording. Pure apart from the two closures it is given to
/// schedule and stop playback; the session owns the stream and the state the screen sees.
struct RunRecorder {
    /// What a block changed.
    enum Event: Equatable {
        case none
        /// Noise stopped the sweep; it resumes from `resumeFrequency` (the start frequency when the run will
        /// start over) once the room is quiet.
        case paused(resumeFrequency: Double)
        /// The sweep plays again; `restarted` when it started over from the beginning, and why.
        case resumed(restarted: RestartReason?)
        /// The recording is complete.
        case finished(Recording)
        /// The sweep's end never arrived, or arrived and never died away, before the timeout.
        case didNotArrive
        /// The takes' positions did not line up for a splice; the run must start again.
        case spliceFailed
        /// The run stayed paused for `maximumPauseWait`: the room does not quieten.
        case tooNoisy
    }

    struct Recording: Equatable {
        /// From `leadIn` before the sweep's scheduled first sample to the end of its decay.
        var samples: [Float]
        /// Samples before the sweep's scheduled first sample.
        var leadIn: Int
        /// Times the run was spliced.
        var spliceCount: Int
        /// Where in the sweep, hertz, noise tied to the sweep was heard (`RunRecording.sweepTiedSound`).
        var sweepTiedSound: ClosedRange<Double>? = nil
        /// Each spliced take's misalignment against the one before, samples.
        var takeOffsets: [Double] = []
    }

    private enum Phase: Equatable {
        case playing
        case paused(Resume)
        case done
    }

    private enum Resume: Equatable {
        case splice(SweepSplicer.Plan)
        case restart(RestartReason)
    }

    private struct TakeRecord {
        var take: SweepSplicer.Take
        /// The sweep sample this take started from.
        var firstIndex: Int
        /// Where this take hands over to the next, on its own timeline.
        var crossfadeOut: Int64?
    }

    let sweep: LogSweep
    let sweepSamples: [Float]
    let configuration: MeasurementConfiguration
    private let sampleRate: Double
    private var phase: Phase = .playing
    private var takes: [TakeRecord] = []
    private var quietSamples = 0
    /// Samples spent in the current pause.
    private var pausedSamples = 0
    /// The sweep sample arriving when noise began, for every pause of this run.
    private var pauseIndices: [Int] = []
    /// The sweep samples over which noise tied to the sweep was heard.
    private var tied: ClosedRange<Int>?

    init(sweep: LogSweep, sweepSamples: [Float], configuration: MeasurementConfiguration) {
        self.sweep = sweep
        self.sweepSamples = sweepSamples
        self.configuration = configuration
        self.sampleRate = sweep.sampleRate
    }

    private func count(_ seconds: Double) -> Int { configuration.samples(seconds, at: sampleRate) }

    /// Whether the run is waiting for quiet.
    var isPaused: Bool {
        if case .paused = phase { return true }
        return false
    }

    /// The current take's sweep origin, for placing the sweep in time.
    var sweepOrigin: Int64? { takes.last?.take.sweepOrigin }

    /// Schedules the whole sweep and starts recording with `block`, the block just captured.
    mutating func begin(with block: CapturedBlock, schedule: ([Float]) throws -> Int64) throws {
        let position = try schedule(sweepSamples)
        takes = [TakeRecord(take: SweepSplicer.Take(samples: block.samples, start: block.position, sweepOrigin: position), firstIndex: 0)]
        phase = .playing
        quietSamples = 0
    }

    /// Takes the next block.
    ///
    /// - Parameters:
    ///   - noisy: The noise detector's verdict on the block (sweep taken out).
    ///   - quietEnough: `NoiseGate.isQuietEnough` on the whole block against the floor: the room-only test, used
    ///     while paused and after the sweep has arrived.
    ///   - delay: The route delay estimate in samples, when known.
    mutating func consume(
        _ block: CapturedBlock,
        noisy: Bool,
        quietEnough: Bool,
        delay: Int?,
        schedule: ([Float]) throws -> Int64,
        stopPlayback: () -> Void
    ) throws -> Event {
        switch phase {
        case .done:
            return .none
        case .paused(let resume):
            pausedSamples += block.samples.count
            if pausedSamples > count(configuration.maximumPauseWait) {
                phase = .done
                return .tooNoisy
            }
            quietSamples = quietEnough ? quietSamples + block.samples.count : 0
            guard quietSamples >= count(configuration.resumeHold) else { return .none }
            quietSamples = 0
            return try self.resume(resume, after: block, schedule: schedule)
        case .playing:
            return playing(block, noisy: noisy, quietEnough: quietEnough, delay: delay, stopPlayback: stopPlayback)
        }
    }

    private mutating func playing(
        _ block: CapturedBlock,
        noisy: Bool,
        quietEnough: Bool,
        delay: Int?,
        stopPlayback: () -> Void
    ) -> Event {
        guard let current = takes.last else { return .none }
        let sweepEnd = current.take.sweepOrigin + Int64(sweepSamples.count)
        let arrived = delay.map { sweepEnd + Int64($0 + count(configuration.minimumTail)) }

        var noisy = noisy
        if noisy {
            let onset = block.position - Int64(count(configuration.noiseGuard))
            // Noise after the sweep's end has arrived only shortens the decay: stop there.
            if let arrived, onset >= arrived {
                return finish(at: onset)
            }
            if let delay, !shouldPause(atSweepIndex: Int(onset - current.take.sweepOrigin) - delay) {
                noisy = false
            }
        }
        if noisy {
            let onset = block.position - Int64(count(configuration.noiseGuard))
            if let delay { pauseIndices.append(Int(onset - current.take.sweepOrigin) - delay) }
            pausedSamples = 0
            stopPlayback()
            if let delay, let plan = SweepSplicer.plan(
                noiseOnset: onset,
                sweepOrigin: current.take.sweepOrigin,
                firstIndex: current.firstIndex,
                delay: delay,
                sweepCount: sweepSamples.count,
                configuration: configuration,
                sampleRate: sampleRate
            ) {
                phase = .paused(.splice(plan))
                quietSamples = 0
                return .paused(resumeFrequency: sweep.frequency(at: Double(plan.resumeIndex) / sampleRate))
            }
            phase = .paused(.restart(.noiseTooEarly))
            quietSamples = 0
            return .paused(resumeFrequency: sweep.startFrequency)
        }

        takes[takes.count - 1].take.samples += block.samples
        guard block.end >= sweepEnd else { return .none }

        if let arrived, block.end >= arrived {
            quietSamples = quietEnough ? quietSamples + block.samples.count : 0
            if quietSamples >= count(configuration.decayHold) {
                return finish(at: block.end)
            }
        }
        if block.end >= sweepEnd + Int64(count(configuration.maximumRouteDelay + configuration.maximumDecay)) {
            if let arrived, block.end >= arrived { return finish(at: block.end) }
            phase = .done
            return .didNotArrive
        }
        return .none
    }

    /// Whether noise beginning at sweep sample `index` should pause the run. Not when it is tied to the sweep: it
    /// began again within `sweepTiedTolerance` of where it paused the run before, or it continues sound already found
    /// tied there. Not when the run has paused `maximumPauses` times: it is recorded through and the check decides.
    private mutating func shouldPause(atSweepIndex index: Int) -> Bool {
        let tolerance = count(configuration.sweepTiedTolerance)
        if let range = tied, index >= range.lowerBound - tolerance, index <= range.upperBound + tolerance {
            tied = min(range.lowerBound, index)...max(range.upperBound, index)
            return false
        }
        if let earlier = pauseIndices.first(where: { abs($0 - index) <= tolerance }) {
            tied = min(earlier, index)...max(earlier, index)
            return false
        }
        return pauseIndices.count < configuration.maximumPauses
    }

    /// `tied` in hertz, the sweep's frequencies over those samples (a block's worth on either side, where the noise was
    /// heard).
    private var tiedFrequencies: ClosedRange<Double>? {
        guard let tied else { return nil }
        let block = count(configuration.blockDuration)
        let low = sweep.frequency(at: Double(max(tied.lowerBound, 0)) / sampleRate)
        let high = sweep.frequency(at: Double(min(tied.upperBound + block, sweepSamples.count)) / sampleRate)
        return low...max(low, high)
    }

    private mutating func resume(_ resume: Resume, after block: CapturedBlock, schedule: ([Float]) throws -> Int64) throws -> Event {
        switch resume {
        case .splice(let plan):
            let samples = SweepSplicer.fadedIn(sweepSamples[plan.resumeIndex...], length: count(configuration.fadeIn))
            let position = try schedule(samples)
            takes[takes.count - 1].crossfadeOut = plan.crossfadeAt
            takes.append(TakeRecord(
                take: SweepSplicer.Take(samples: [], start: block.end, sweepOrigin: position - Int64(plan.resumeIndex)),
                firstIndex: plan.resumeIndex
            ))
            phase = .playing
            return .resumed(restarted: nil)
        case .restart(let reason):
            let position = try schedule(sweepSamples)
            takes = [TakeRecord(take: SweepSplicer.Take(samples: [], start: block.end, sweepOrigin: position), firstIndex: 0)]
            phase = .playing
            return .resumed(restarted: reason)
        }
    }

    /// Splices the takes and cuts the recording from `leadIn` before the sweep to `end` (on the last take's timeline).
    private mutating func finish(at end: Int64) -> Event {
        phase = .done
        guard let first = takes.first, let last = takes.last else { return .spliceFailed }
        var composite = first.take
        var offsets: [Double] = []
        do {
            for index in takes.indices.dropFirst() {
                guard let crossfadeAt = takes[index - 1].crossfadeOut else { return .spliceFailed }
                // The route's delay must not have changed between the takes: compare them where they overlap.
                if let offset = misalignment(of: takes[index].take, after: takes[index - 1].take, crossfadeAt: crossfadeAt) {
                    guard abs(offset) <= configuration.maximumSpliceMisalignment * sampleRate else { return .spliceFailed }
                    offsets.append(offset)
                }
                // The handover position on the composite's (the first take's) timeline.
                let shift = takes[index - 1].take.sweepOrigin - first.take.sweepOrigin
                composite = try SweepSplicer.splice(
                    composite,
                    takes[index].take,
                    crossfadeAt: crossfadeAt - shift,
                    crossfadeLength: count(configuration.crossfade)
                )
            }
        } catch {
            return .spliceFailed
        }
        let leadIn = count(configuration.leadIn)
        let from = Int(first.take.sweepOrigin - Int64(leadIn) - composite.start)
        let to = Int(end - (last.take.sweepOrigin - first.take.sweepOrigin) - composite.start)
        guard from >= 0, to > from, to <= composite.samples.count else { return .spliceFailed }
        return .finished(Recording(
            samples: Array(composite.samples[from..<to]),
            leadIn: leadIn,
            spliceCount: takes.count - 1,
            sweepTiedSound: tiedFrequencies,
            takeOffsets: offsets
        ))
    }
}

extension RunRecorder {
    /// The widest misalignment searched for between two takes, samples: 0.5 ms. A peak at the edge of the search
    /// counts as misaligned.
    static let misalignmentSearch = 24

    /// How far `next` lies from `previous` (samples, positive when later) over the stretch both hold of the same
    /// sound, the `resumeOverlap` before the crossfade less the guard, the crossfade, the fade in and the delay
    /// margin; nil when the takes do not hold enough of it to compare. Infinity when the best match is at the edge
    /// of the search.
    func misalignment(of next: SweepSplicer.Take, after previous: SweepSplicer.Take, crossfadeAt: Int64) -> Double? {
        let length = count(configuration.resumeOverlap - configuration.noiseGuard - configuration.crossfade
            - configuration.fadeIn - configuration.delayMargin)
        guard length >= count(0.05) else { return nil }
        let from = Int(crossfadeAt - previous.start) - length
        guard from >= 0, from + length <= previous.samples.count else { return nil }
        let shift = next.sweepOrigin - previous.sweepOrigin
        let nextFrom = Int(crossfadeAt + shift - next.start) - length
        let lag = Self.misalignment(previous.samples[from..<(from + length)], against: next.samples, at: nextFrom,
                                    searching: Self.misalignmentSearch)
        return lag
    }

    /// The lag `L`, to a fraction of a sample, at which `window[window.startIndex + j]` best matches
    /// `other[start + j + L]`, searched over ±`search` samples (cross-correlation with a parabola through the peak).
    /// Nil when `other` does not cover the search; infinity when the peak is at its edge.
    static func misalignment(_ window: ArraySlice<Float>, against other: [Float], at start: Int, searching search: Int) -> Double? {
        guard start - search >= 0, start + window.count + search <= other.count, !window.isEmpty else { return nil }
        let a = Array(window)
        var scores = [Double](repeating: 0, count: 2 * search + 1)
        // Plain `while` loops: about half a million products per splice, and range iterators are costly in debug.
        a.withUnsafeBufferPointer { a in
            other.withUnsafeBufferPointer { b in
                var lag = -search
                while lag <= search {
                    var sum = 0.0
                    let base = start + lag
                    var j = 0
                    while j < a.count {
                        sum += Double(a[j]) * Double(b[base + j])
                        j += 1
                    }
                    scores[lag + search] = sum
                    lag += 1
                }
            }
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        guard best > 0, best < scores.count - 1 else { return .infinity }
        let (before, centre, after) = (scores[best - 1], scores[best], scores[best + 1])
        let curvature = before - 2 * centre + after
        let fraction = curvature < 0 ? min(max(0.5 * (before - after) / curvature, -0.5), 0.5) : 0
        return Double(best - search) + fraction
    }
}

/// Why a run started again from the sweep's beginning instead of resuming where it stopped.
public enum RestartReason: Sendable, Hashable {
    /// The noise came before enough of the sweep had arrived to place a splice.
    case noiseTooEarly
    /// Samples were lost, so the positions a splice depends on cannot be trusted.
    case timelineUnreliable
}
