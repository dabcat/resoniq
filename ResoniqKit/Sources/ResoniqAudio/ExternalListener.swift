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
        /// The capture position at which the clock tone ended: the files are told apart by the time from it to a
        /// sweep (`TestSoundFile.identify(secondsAfterToneEnd:)`), which a player muting the tone's start does not move.
        var toneEnd: Double?
        /// Whether the stillness monitor reported the phone moving while the tone played: its clock reading then
        /// carries the phone's Doppler shift (30 ppm per cm/s).
        var toneMoved = false
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
    private(set) var lastHeard: Int64 = 0 {
        didSet { loudSinceHeard = 0 }
    }
    /// Samples since `lastHeard` in blocks louder than the room (`consume`'s `loud`) while nothing of the file was
    /// being recognised: sound that is not the test sound (music, a broken copy, a subwoofer alone).
    private(set) var loudSinceHeard = 0
    /// Cuts waiting for their tail: the sweep's estimated start, its play and identity, and whether the phone moved.
    private var waiting: [(estimate: Int64, play: Int, identity: SweepIdentity?, phoneMoved: Bool)] = []
    private var movedDuringSweep = false
    /// The blocks in which the phone was not held still, as capture ranges, the last `bufferHorizon` of them.
    private var unsteady: [Range<Int64>] = []
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

    /// What is heard now (`ExternalHearing`): the test sound while a play is under way; sound that is not the test
    /// sound once `ExternalListening.unrecognisedSoundMinimum` of it has been heard with nothing recognised; else what
    /// the latest play was (`latest`, from `hearing(after:)`), or nothing.
    func hearing(latest: ExternalHearing?) -> ExternalHearing {
        if !isQuiet || currentPlay != nil { return .testSound }
        if Double(loudSinceHeard) >= ExternalListening.unrecognisedSoundMinimum * sampleRate { return .notTheTestSound }
        return latest ?? .nothing
    }

    /// What a play that fell short for `problem` says about what was heard: another file is not the test sound; a run
    /// too quiet, missed or cut short, or a missed tone, is the test sound incomplete; a run clipped or drowned was the
    /// test sound, heard.
    static func hearing(after problem: ExternalPlayProblem?) -> ExternalHearing {
        switch problem {
        case .wrongFile: .notTheTestSound
        case .run(.unusable(.tooQuiet)), .run(.didNotArrive), .missedSweeps, .clockUnknown, .stoppedPartWay, nil: .testSoundIncomplete
        case .run, .runsDisagree, .phoneMovedDuringTone: .testSound
        }
    }

    /// Whether the silence after the latest sound has lasted `ExternalListening.nothingHeardLimit`, and if so how the
    /// session ends: `soundNotRecognised` when enough sound was heard that was not the test sound, else `nothingHeard`.
    func silenceFailure(at position: Int64) -> ExternalMeasurementFailure? {
        guard isQuiet, currentPlay == nil, Double(position - lastHeard) >= ExternalListening.nothingHeardLimit * sampleRate else { return nil }
        return Double(loudSinceHeard) >= ExternalListening.unrecognisedSoundMinimum * sampleRate ? .soundNotRecognised : .nothingHeard
    }

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
    mutating func consume(_ block: CapturedBlock, steady: Bool, loud: Bool = false) -> [Event] {
        if loud, isQuiet, currentPlay == nil { loudSinceHeard += block.samples.count }
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
        if !steady {
            unsteady.append(block.position..<block.end)
            unsteady.removeAll { $0.upperBound < block.end - Int64(ExternalListening.bufferHorizon * sampleRate) }
        }
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
        var reading: (ratio: Double, onset: Double, end: Double)?
        if to > from {
            reading = SweepFinder.readClockToneSpan(Array(buffer[Int(from - bufferStart)..<Int(to - bufferStart)]), sampleRate: sampleRate)
        }
        let moved = unsteady.contains { $0.overlaps(start..<end) }
        // A tone read while the phone moved carries its Doppler shift: it stays its play's, never the session's.
        if let ratio = reading?.ratio, !moved { knownRatio = ratio }
        var play = Play(
            id: plays.count + 1,
            toneOnset: reading.map { Double(from) + $0.onset } ?? Double(start),
            ratio: reading?.ratio,
            lastHeard: position
        )
        play.toneEnd = reading.map { Double(from) + $0.end } ?? Double(end)
        play.toneMoved = moved
        plays.append(play)
        events.append(.toneRead(ratio: reading?.ratio))
        return events
    }

    private mutating func sweepStarted(_ estimate: Int64, at position: Int64) -> [Event] {
        var events: [Event] = []
        var identity: SweepIdentity?
        if let index = plays.indices.last, !plays[index].isOver {
            let play = plays[index]
            let ratio = play.ratio ?? knownRatio ?? 1
            let fromTone = play.toneEnd.flatMap { end in
                TestSoundFile.identify(secondsAfterToneEnd: (Double(estimate) - end) / sampleRate * ratio)
            }
            let spacingKind = play.sweeps.last.flatMap { previous in
                TestSoundFile.kind(forSpacing: Double(estimate - previous.estimate) / sampleRate * ratio)
            }
            // What the tone's timing says this play is: from this sweep, or from the play's earlier ones.
            let toneKind = fromTone?.kind ?? (play.toneEnd != nil ? play.sweeps.last?.identity?.kind : nil)
            if let fromTone, spacingKind == nil || spacingKind == fromTone.kind {
                identity = SweepIdentity(kind: fromTone.kind, index: fromTone.index)
            } else if let toneKind, let spacingKind, toneKind != spacingKind {
                // The tone's timing and the sweeps' spacing disagree: the spacing, two sweeps of the file on the same
                // clock, overrules. The sweeps heard so far are this kind's, the first of them its first sweep.
                identity = relabel(play: index, as: spacingKind, estimate: estimate, ratio: ratio)
                if spacingKind == expected { plays[index].wrongFile = nil }
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

    /// Play `index`'s sweeps relabelled as `kind`'s, counting from its first sweep and its spacing; the identity of the
    /// sweep at `estimate`. Nil when it does not fit in that kind of file.
    private mutating func relabel(play index: Int, as kind: TestSoundFile.Kind, estimate: Int64, ratio: Double) -> SweepIdentity? {
        let count = TestSoundFile(kind: kind).layout.sweeps.count
        guard let first = plays[index].sweeps.first else { return nil }
        for sweep in plays[index].sweeps.indices {
            let position = plays[index].sweeps[sweep].estimate
            let place = position == first.estimate ? 0 : Self.steps(first.estimate, position, kind: kind, ratio: ratio, sampleRate: sampleRate)
            plays[index].sweeps[sweep].identity = place < count ? SweepIdentity(kind: kind, index: place) : nil
        }
        let place = Self.steps(first.estimate, estimate, kind: kind, ratio: ratio, sampleRate: sampleRate)
        return place < count ? SweepIdentity(kind: kind, index: place) : nil
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
    /// Where in the sweep, seconds from its start, blocks were too noisy (`SweepNoiseDetector`), merged; empty when
    /// none were. With them `verdict` is `tooNoisy` and `cleanVerdict` what `RecordingQuality.assess` said.
    var noise: [ClosedRange<Double>] = []
    var cleanVerdict: RecordingVerdict?
    /// Where the sweep stopped part-way, hertz (`SweepCompleteness.stopFrequency(of:)`); `problem` is then
    /// `didNotArrive`. Nil when it did not.
    var stoppedAt: Double?

    /// Checks `cut`: finds the sweep exactly, cuts it with `leadIn` before and `tail` after, corrects the player's
    /// clock when `ratio` is known, and checks the recording as a normal run is checked (`RunPerformer.inspect`:
    /// `RecordingQuality.assess`, then the whole sweep in the deconvolved response). Between the two, since nothing
    /// paused the sweep for noise, every block of the sweep is put to `detector` (`SweepNoiseDetector`, the normal
    /// test's pause rule): a block too noisy makes the run `tooNoisy`, with the sweep's level over the room's in that
    /// block as its ratio, and every noisy block's place in the sweep is kept (`noise`) so the session can tell noise
    /// tied to the sweep from the room's (`SweepTiedNoise`). Off the main actor: a cut is several seconds of audio and
    /// is deconvolved.
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
        // A sweep the file's timing placed (by the tone, or by another sweep's spacing) is anchored: a speaker that
        // plays only part of the range is still found. One not placed must span the range (`SweepFinder.find`).
        let anchored = cut.identity != nil
        guard let found = SweepFinder.find(in: cut.window, sampleRate: sweep.sampleRate, sweep: sweep, expectedCount: 1, anchored: anchored).first else {
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
        if let detector {
            let noisy = noisyBlocks(in: inspection.raw, from: Int(inspection.rawLeadIn), count: sweep.sampleCount, detector: detector)
            if let worst = noisy.first {
                // Too noisy for now; kept aside in case the same noise comes back at the same place of the sweep in
                // another run, which makes it sound tied to the sweep rather than the room's (`SweepTiedNoise`).
                let tooNoisy = RecordingVerdict.tooNoisy(signalToNoise: worst.assessment.blockLevel.dBFS - worst.assessment.roomLevel.dBFS, noiseFloor: floor)
                inspection.cleanVerdict = verdict
                inspection.verdict = tooNoisy
                inspection.problem = .unusable(tooNoisy)
                inspection.noise = SweepTiedNoise.merged(noisy.map { block in
                    let from = (Double(block.offset) - inspection.rawLeadIn) / sweep.sampleRate
                    return max(0, from)...min(sweep.duration, from + Double(detector.blockLength) / sweep.sampleRate)
                })
            }
        }
        let response = Deconvolution.impulseResponse(recording: inspection.samples, sweep: sweep)
        inspection.measuredDelay = response.delay
        if !response.capturesWholeSweep {
            inspection.problem = .didNotArrive
        } else if let stop = SweepCompleteness.stopFrequency(of: response) {
            // Long enough, but the sweep stopped part-way (the player stopped or paused): not a whole run.
            inspection.stoppedAt = stop
            inspection.problem = .didNotArrive
        }
        return inspection
    }

    /// How far each of `inspections`' responses strays from the others' (`SweepCompleteness.disagreement(_:)`), dB.
    /// Off the main actor: each is deconvolved.
    @concurrent nonisolated static func disagreement(_ inspections: [SweepInspection], sweep: LogSweep) async -> [Float]? {
        SweepCompleteness.disagreement(inspections.map { Deconvolution.impulseResponse(recording: $0.samples, sweep: sweep) })
    }

    /// The first block of `samples` from `start` over `count` samples that `detector` finds too noisy.
    nonisolated static func noisyBlock(in samples: [Float], from start: Int, count: Int, detector: SweepNoiseDetector) -> SweepNoiseDetector.Assessment? {
        noisyBlocks(in: samples, from: start, count: count, detector: detector, all: false).first?.assessment
    }

    /// Every block of `samples` from `start` over `count` samples that `detector` finds too noisy (only the first when
    /// `all` is false), with its offset in `samples`.
    nonisolated static func noisyBlocks(
        in samples: [Float], from start: Int, count: Int, detector: SweepNoiseDetector, all: Bool = true
    ) -> [(offset: Int, assessment: SweepNoiseDetector.Assessment)] {
        let length = detector.blockLength
        var position = max(0, start)
        let end = min(samples.count, start + count)
        var noisy: [(offset: Int, assessment: SweepNoiseDetector.Assessment)] = []
        while position + length <= end {
            let assessment = detector.assess(Array(samples[position..<(position + length)]))
            if assessment.isTooNoisy {
                noisy.append((position, assessment))
                if !all { break }
            }
            position += length
        }
        return noisy
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

/// Tells noise tied to the sweep from the room's in the listening sessions, which cannot pause the player to find out
/// as the normal test does (`RunRecorder`, `RunRecording.sweepTiedSound`): noise heard at the same place of the sweep
/// in two or more runs, within a play or across plays, follows the sweep (a rattle, a buzz, the room's reverberation
/// beyond the detector's allowance), while the room's noise does not come back where it was.
///
/// Every run with noisy blocks is recorded with where in the sweep they were (`SweepInspection.noise`). A run is tied
/// once every one of its noisy stretches overlaps, within `MeasurementConfiguration.sweepTiedTolerance`, a noisy
/// stretch of another recorded run: it is then kept, marked with the frequencies of those stretches. A run with a
/// stretch heard nowhere else (a door, a voice) stays room noise and is not kept.
struct SweepTiedNoise {
    struct Entry {
        var id: Int
        var stretches: [ClosedRange<Double>]
    }

    let tolerance: Double
    private(set) var entries: [Entry] = []

    init(tolerance: Double) {
        self.tolerance = tolerance
    }

    mutating func record(id: Int, stretches: [ClosedRange<Double>]) {
        guard !stretches.isEmpty else { return }
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, stretches: stretches))
    }

    /// Whether every noisy stretch of run `id` was heard at the same place in another run.
    func isTied(_ id: Int) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        return entry.stretches.allSatisfy { stretch in
            entries.contains { other in
                other.id != id && other.stretches.contains { $0.lowerBound - tolerance <= stretch.upperBound && stretch.lowerBound - tolerance <= $0.upperBound }
            }
        }
    }

    /// The frequencies the sweep passes through over `stretches`, hertz: from the first's start to the last's end, as
    /// `RunRecording.sweepTiedSound` holds them.
    static func frequencies(of stretches: [ClosedRange<Double>], sweep: LogSweep) -> ClosedRange<Double>? {
        guard let low = stretches.map(\.lowerBound).min(), let high = stretches.map(\.upperBound).max() else { return nil }
        return sweep.frequency(at: max(0, low))...sweep.frequency(at: min(sweep.duration, high))
    }

    /// `stretches` joined where they touch or overlap, in order.
    static func merged(_ stretches: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for stretch in stretches.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, stretch.lowerBound <= last.upperBound + 1e-6 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, stretch.upperBound)
            } else {
                merged.append(stretch)
            }
        }
        return merged
    }
}
