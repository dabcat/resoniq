import Foundation
import ResoniqDSP

// The listening machinery both listening sessions share: keeping the audio, following the file as it is heard
// (`SweepFollower`), reading the player's clock from the tone, telling which file and which of its sweeps is heard,
// and cutting each sweep out once its tail is in. The sessions own the stream, the states, the progress and what is
// kept; these types decide nothing about screens.

/// Which file, and which of its sweeps, a heard sweep is.
struct SweepIdentity: Sendable, Equatable {
    var kind: TestSoundFile.Kind
    /// 0-based, in the file's order.
    var index: Int
}

/// The audio around one heard sweep, ready to be inspected.
struct SweepCut: Sendable {
    var window: [Float]
    /// The capture position of `window[0]`.
    var windowStart: Int64
    /// The follower's estimate of the sweep's start, a capture position.
    var estimate: Int64
    /// The play it belongs to, and its place there.
    var play: Int
    var identity: SweepIdentity?
    /// Whether the phone moved while it played.
    var phoneMoved: Bool
}

/// Follows the audio after the noise floor, block by block.
struct ExternalListener {
    /// Something heard that the session acts on.
    enum Event: Equatable {
        /// The clock tone has started.
        case toneStarted
        /// The clock tone ended and was read: the player's clock against the phone's (nil when it could not be read).
        case toneRead(ratio: Double?)
        /// A sweep is arriving; `identity` when its file and place are known.
        case sweepStarted(play: Int, identity: SweepIdentity?)
        /// A heard sweep belongs to another file than the one listened for.
        case wrongFile(play: Int, heard: TestSoundFile.Kind)
        /// A sweep and its tail are in.
        case cutReady
        /// Nothing more has come of play `play` for `ExternalListening.playTimeout`.
        case playOver(play: Int)
    }

    /// One play of the file, as heard.
    struct Play {
        var id: Int
        /// The capture position at which the clock tone began, and the clock it gave.
        var toneOnset: Double?
        var ratio: Double?
        /// The sweeps heard, by the follower's estimate of their start.
        var sweeps: [(estimate: Int64, identity: SweepIdentity?)] = []
        /// The kind of the other file this play turned out to be.
        var wrongFile: TestSoundFile.Kind?
        /// The latest capture position at which something of it was heard.
        var lastHeard: Int64
        var isOver = false
    }

    let sampleRate: Double
    let sweep: LogSweep
    let expected: TestSoundFile.Kind
    let leadIn: Int
    let tail: Int
    private(set) var follower: SweepFollower
    private var buffer: [Float] = []
    private var bufferStart: Int64 = 0
    private(set) var plays: [Play] = []
    /// The latest clock read from a tone, for plays whose tone was missed.
    private(set) var knownRatio: Double?
    /// The capture position of the latest sound of the file (or of "Press play").
    private(set) var lastHeard: Int64 = 0
    /// Cuts waiting for their tail: the sweep's estimated start, its play and identity, and whether the phone moved.
    private var waiting: [(estimate: Int64, play: Int, identity: SweepIdentity?, phoneMoved: Bool)] = []
    private var movedDuringSweep = false
    /// Cuts whose tail is in, in order.
    private(set) var ready: [SweepCut] = []

    init(sampleRate: Double, sweep: LogSweep, expected: TestSoundFile.Kind, configuration: MeasurementConfiguration) {
        self.sampleRate = sampleRate
        self.sweep = sweep
        self.expected = expected
        leadIn = configuration.samples(ExternalListening.leadIn(configuration), at: sampleRate)
        tail = configuration.samples(TestSoundFile.recordedTail(for: configuration), at: sampleRate)
        follower = SweepFollower(sweep: sweep)
    }

    var currentPlay: Play? { plays.last.flatMap { $0.isOver ? nil : $0 } }
    var isHearingTone: Bool { follower.isHearingTone }
    var isHearingSweep: Bool { follower.activeSweepStart != nil }
    var heardFrequency: Double? { follower.heardFrequency }
    var sweepFraction: Double? { follower.sweepFraction }
    /// Whether nothing is being heard or waited for: no tone, no sweep, no tail.
    var isQuiet: Bool { !isHearingTone && !isHearingSweep && waiting.isEmpty && ready.isEmpty }

    /// Starts counting silence afresh from `position` (when the screen says "Press play").
    mutating func markListening(at position: Int64) {
        lastHeard = position
    }

    /// Samples were lost: what was heard so far cannot be joined to what follows.
    mutating func restartAfterGap(at position: Int64) {
        follower.reset()
        buffer = []
        bufferStart = position
        waiting = []
        ready = []
        if let index = plays.indices.last { plays[index].isOver = true }
    }

    /// Takes the next block; `steady` is whether the phone is held still.
    mutating func consume(_ block: CapturedBlock, steady: Bool) -> [Event] {
        if buffer.isEmpty { bufferStart = block.position }
        buffer += block.samples
        let horizon = Int(ExternalListening.bufferHorizon * sampleRate)
        if buffer.count > horizon + horizon / 4 {
            let drop = buffer.count - horizon
            buffer.removeFirst(drop)
            bufferStart += Int64(drop)
        }
        var events: [Event] = []
        if follower.activeSweepStart != nil, !steady { movedDuringSweep = true }
        for heard in follower.feed(block.samples, at: block.position) {
            switch heard {
            case .toneStarted:
                lastHeard = block.end
                events.append(.toneStarted)
            case .toneEnded(let start, let end):
                lastHeard = block.end
                events += toneEnded(start: start, end: end, at: block.end)
            case .sweepStarted(let start):
                lastHeard = block.end
                movedDuringSweep = !steady
                events += sweepStarted(start, at: block.end)
            case .sweepEnded(let start):
                lastHeard = block.end
                if let index = plays.indices.last { plays[index].lastHeard = block.end }
                let play = plays.last { play in play.sweeps.contains { $0.estimate == start } }
                let identity = play?.sweeps.first { $0.estimate == start }?.identity
                waiting.append((start, play?.id ?? -1, identity, movedDuringSweep))
                movedDuringSweep = false
            }
        }
        // A cut is ready once the sweep's end and its tail are in, with a little room for the estimate.
        let length = Int64(sweep.sampleCount)
        let margin = Int64((SweepFollower.startTolerance + 0.1) * sampleRate)
        while let first = waiting.first, block.end >= first.estimate + length + Int64(tail) + margin {
            waiting.removeFirst()
            let from = max(bufferStart, first.estimate - Int64(leadIn) - 2 * margin)
            let to = min(bufferStart + Int64(buffer.count), first.estimate + length + Int64(tail) + margin)
            guard to > from else { continue }
            let window = Array(buffer[Int(from - bufferStart)..<Int(to - bufferStart)])
            ready.append(SweepCut(
                window: window, windowStart: from, estimate: first.estimate, play: first.play,
                identity: first.identity, phoneMoved: first.phoneMoved
            ))
            events.append(.cutReady)
        }
        // A play nothing more has come of.
        if let index = plays.indices.last, !plays[index].isOver, waiting.isEmpty, !isHearingSweep, !isHearingTone,
           block.end - plays[index].lastHeard > Int64(ExternalListening.playTimeout * sampleRate) {
            plays[index].isOver = true
            events.append(.playOver(play: plays[index].id))
        }
        return events
    }

    /// Takes the first ready cut.
    mutating func takeCut() -> SweepCut? {
        ready.isEmpty ? nil : ready.removeFirst()
    }

    /// Marks play `id` over now (the session has all it needs from it).
    mutating func endPlay(_ id: Int) {
        if let index = plays.firstIndex(where: { $0.id == id }) { plays[index].isOver = true }
    }

    /// The clock for play `id`: its tone's, else the latest tone's.
    func ratio(forPlay id: Int) -> Double? {
        plays.first { $0.id == id }?.ratio ?? knownRatio
    }

    // MARK: - What was heard

    private mutating func toneEnded(start: Int64, end: Int64, at position: Int64) -> [Event] {
        var events: [Event] = []
        // A tone starts a new play.
        if let index = plays.indices.last, !plays[index].isOver {
            plays[index].isOver = true
            events.append(.playOver(play: plays[index].id))
        }
        let margin = Int64(0.2 * sampleRate)
        let from = max(bufferStart, start - margin)
        let to = min(bufferStart + Int64(buffer.count), end + margin)
        var reading: (ratio: Double, onset: Double)?
        if to > from {
            reading = SweepFinder.readClockTone(Array(buffer[Int(from - bufferStart)..<Int(to - bufferStart)]), sampleRate: sampleRate)
        }
        if let ratio = reading?.ratio { knownRatio = ratio }
        plays.append(Play(
            id: plays.count + 1,
            toneOnset: reading.map { Double(from) + $0.onset } ?? Double(start),
            ratio: reading?.ratio,
            lastHeard: position
        ))
        events.append(.toneRead(ratio: reading?.ratio))
        return events
    }

    private mutating func sweepStarted(_ estimate: Int64, at position: Int64) -> [Event] {
        var events: [Event] = []
        var identity: SweepIdentity?
        if let index = plays.indices.last, !plays[index].isOver {
            let play = plays[index]
            let ratio = play.ratio ?? knownRatio ?? 1
            if let onset = play.toneOnset,
               let found = TestSoundFile.identify(secondsAfterTone: (Double(estimate) - onset) / sampleRate * ratio) {
                identity = SweepIdentity(kind: found.kind, index: found.index)
            } else if let previous = play.sweeps.last {
                identity = Self.identifyBySpacing(previous, estimate: estimate, ratio: ratio, sampleRate: sampleRate)
                if identity == nil {
                    // Not this play's timing: a new play whose tone was missed.
                    plays[index].isOver = true
                    events.append(.playOver(play: play.id))
                } else if previous.identity == nil, let identity {
                    plays[index].sweeps[plays[index].sweeps.count - 1].identity = SweepIdentity(
                        kind: identity.kind, index: identity.index - Self.steps(previous.estimate, estimate, kind: identity.kind, ratio: ratio, sampleRate: sampleRate)
                    )
                }
            }
        }
        if currentPlay == nil {
            plays.append(Play(id: plays.count + 1, toneOnset: nil, ratio: nil, lastHeard: position))
        }
        let index = plays.count - 1
        plays[index].sweeps.append((estimate, identity))
        plays[index].lastHeard = position
        events.append(.sweepStarted(play: plays[index].id, identity: identity))
        if let identity, identity.kind != expected, plays[index].wrongFile == nil {
            plays[index].wrongFile = identity.kind
            events.append(.wrongFile(play: plays[index].id, heard: identity.kind))
        }
        return events
    }

    /// The identity of a sweep heard `estimate` after `previous`, from their spacing; nil when the spacing is no
    /// file's.
    static func identifyBySpacing(
        _ previous: (estimate: Int64, identity: SweepIdentity?),
        estimate: Int64,
        ratio: Double,
        sampleRate: Double
    ) -> SweepIdentity? {
        let seconds = Double(estimate - previous.estimate) / sampleRate * ratio
        guard let kind = TestSoundFile.kind(forSpacing: seconds) else { return nil }
        if let known = previous.identity, known.kind != kind { return nil }
        let steps = steps(previous.estimate, estimate, kind: kind, ratio: ratio, sampleRate: sampleRate)
        let index = (previous.identity?.index ?? 0) + steps
        guard index < TestSoundFile(kind: kind).layout.sweeps.count else { return nil }
        return SweepIdentity(kind: kind, index: index)
    }

    /// How many of `kind`'s spacings lie between two sweeps.
    static func steps(_ first: Int64, _ second: Int64, kind: TestSoundFile.Kind, ratio: Double, sampleRate: Double) -> Int {
        guard let spacing = TestSoundFile(kind: kind).layout.spacing else { return 0 }
        return max(1, Int((Double(second - first) / sampleRate * ratio / spacing).rounded()))
    }
}

/// What the check of one cut found.
struct SweepInspection: Sendable {
    /// Where the sweep began, a capture position, from `SweepFinder.find`; nil when the finder found no sweep there
    /// (the follower was fooled), and then nothing else is set.
    var start: Double?
    /// Nil when the run can be kept.
    var problem: RunProblem?
    var verdict: RecordingVerdict?
    /// The cut from `leadIn` before the sweep to `tail` after it, as recorded, and the sweep's start in it.
    var raw: [Float] = []
    var rawLeadIn: Double = 0
    /// `raw` corrected by `ratio` (or `raw` when there is none), its lead-in in samples and the response's delay.
    var samples: [Float] = []
    var leadIn: Int = 0
    var measuredDelay: Double?
    var ratio: Double?

    /// Checks `cut`: finds the sweep exactly, cuts it with `leadIn` before and `tail` after, corrects the player's
    /// clock when `ratio` is known, and checks the recording as a normal run is checked (`RunPerformer.inspect`:
    /// `RecordingQuality.assess`, then the whole sweep in the deconvolved response). Between the two, since nothing
    /// paused the sweep for noise, every block of the sweep is put to `detector` (`SweepNoiseDetector`, the normal
    /// test's pause rule): a block too noisy makes the run `tooNoisy`, with the sweep's level over the room's in that
    /// block as its ratio. Off the main actor: a cut is several seconds of audio and is deconvolved.
    @concurrent nonisolated static func inspect(
        _ cut: SweepCut,
        sweep: LogSweep,
        floor: NoiseFloorReport,
        detector: SweepNoiseDetector?,
        thresholds: QualityThresholds,
        ratio: Double?,
        leadIn: Int,
        tail: Int
    ) async -> SweepInspection {
        guard let found = SweepFinder.find(in: cut.window, sampleRate: sweep.sampleRate, sweep: sweep, expectedCount: 1).first else {
            return SweepInspection(start: nil)
        }
        var inspection = SweepInspection(start: Double(cut.windowStart) + found.start)
        let first = Int(found.start.rounded(.down)) - leadIn
        let length = Int((Double(sweep.sampleCount) / (ratio ?? 1)).rounded(.up))
        let last = Int(found.start.rounded(.up)) + length + tail
        guard found.isComplete, first >= 0, last <= cut.window.count else {
            inspection.problem = .didNotArrive
            return inspection
        }
        inspection.raw = Array(cut.window[first..<last])
        inspection.rawLeadIn = found.start - Double(first)
        inspection.apply(ratio: ratio, sweep: sweep)
        let verdict = RecordingQuality.assess(recording: inspection.samples, noiseFloor: floor, thresholds: thresholds)
        inspection.verdict = verdict
        guard case .valid = verdict else {
            inspection.problem = .unusable(verdict)
            return inspection
        }
        if let detector, let noisy = noisyBlock(in: inspection.raw, from: Int(inspection.rawLeadIn), count: sweep.sampleCount, detector: detector) {
            let tooNoisy = RecordingVerdict.tooNoisy(signalToNoise: noisy.blockLevel.dBFS - noisy.roomLevel.dBFS, noiseFloor: floor)
            inspection.verdict = tooNoisy
            inspection.problem = .unusable(tooNoisy)
            return inspection
        }
        let response = Deconvolution.impulseResponse(recording: inspection.samples, sweep: sweep)
        inspection.measuredDelay = response.delay
        if !response.capturesWholeSweep { inspection.problem = .didNotArrive }
        return inspection
    }

    /// The first block of `samples` from `start` over `count` samples that `detector` finds too noisy.
    nonisolated static func noisyBlock(in samples: [Float], from start: Int, count: Int, detector: SweepNoiseDetector) -> SweepNoiseDetector.Assessment? {
        let length = detector.blockLength
        var position = max(0, start)
        let end = min(samples.count, start + count)
        while position + length <= end {
            let assessment = detector.assess(Array(samples[position..<(position + length)]))
            if assessment.isTooNoisy { return assessment }
            position += length
        }
        return nil
    }

    /// `raw` corrected by `ratio`: `samples`, `leadIn` and `ratio` set.
    mutating func apply(ratio: Double?, sweep: LogSweep) {
        self.ratio = ratio
        samples = ratio.map { SweepFinder.corrected(raw, ratio: $0) } ?? raw
        leadIn = Int((rawLeadIn * (ratio ?? 1)).rounded())
    }

    /// The inspection corrected afresh by `ratio`, with the response's delay measured again. Off the main actor.
    @concurrent nonisolated static func recorrected(_ inspection: SweepInspection, ratio: Double, sweep: LogSweep) async -> SweepInspection {
        var corrected = inspection
        corrected.apply(ratio: ratio, sweep: sweep)
        corrected.measuredDelay = Deconvolution.impulseResponse(recording: corrected.samples, sweep: sweep).delay
        return corrected
    }
}
