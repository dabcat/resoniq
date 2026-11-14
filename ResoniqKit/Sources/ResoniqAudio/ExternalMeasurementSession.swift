import Foundation
import Observation
import ResoniqDSP

/// A speaker test whose sound another device plays: the user plays a `TestSoundFile` (`speakerTest(channel)`) on
/// their own system while the phone only listens. It measures the room's floor, says "Press play now", finds the
/// file's clock tone and sweeps in what it hears by itself, cuts each sweep out once its tail is in, corrects the
/// player's clock, checks each run as a normal test checks it, and ends with three runs or a reason.
///
/// **What differs from `MeasurementSession`.** Nothing is played by the phone and its output route is not checked.
/// It cannot pause someone else's player, so a run spoiled by noise is not paused for and not spliced: it is simply
/// not kept, and when the play ends with fewer than `runCount` runs the state asks for the file to be played again
/// (`needsAnotherPlay`) while it keeps listening. A run is kept only once its file and place are known (from the
/// tone, or the spacing of two sweeps): a sweep of another file is never mixed in (`ExternalPlayProblem.wrongFile`).
/// Which speaker played cannot be told from one microphone; which file played can.
///
/// **The result** is a `MeasurementResult` of the same shape as a normal test's, so `RunAnalyzer` reads its runs
/// unchanged: each `RunRecording` starts `leadIn` before the sweep and ends `TestSoundFile.recordedTail(for:)` after
/// it, already corrected for the player's clock (`clockRatio`), with `source` `.anotherDevice`.
///
/// **Isolation: the main actor**, as `MeasurementSession`: per block one transform and a few comparisons; reading the
/// tone is a few milliseconds; each cut is checked off the main actor (`SweepInspection.inspect`). Every wait is
/// counted in captured samples, so on `SimulatedAudioIO` a test runs as fast as the arithmetic. Every read of the
/// capture stream yields after each block.
@MainActor
@Observable
public final class ExternalMeasurementSession {
    /// Where a listening test is.
    public enum State: Sendable, Equatable {
        case idle
        /// Listening to the room before the sound.
        case measuringNoiseFloor
        /// The floor is known: "Press play now". The progress says how long nothing has been heard.
        case waitingForSound
        /// The file is being heard: its clock tone, a sweep that will be run `run` if it is usable, or the silence
        /// between two of its sweeps.
        case hearing(run: Int)
        /// The sweep just heard is being checked.
        case checking(run: Int)
        /// The play ended, or went wrong, with fewer than `runCount` runs in hand (`have`): the file must be played
        /// again. The session keeps listening; `reason` is why, when there is one.
        case needsAnotherPlay(have: Int, reason: ExternalPlayProblem?)
        case finished(MeasurementResult)
        case failed(ExternalMeasurementFailure)

        /// Whether the test has ended, one way or the other.
        public var isFinal: Bool {
            switch self {
            case .finished, .failed: true
            default: false
            }
        }
    }

    public let channel: SpeakerChannel
    public let configuration: MeasurementConfiguration
    public let thresholds: QualityThresholds
    /// The file the user plays.
    public var file: TestSoundFile { TestSoundFile(kind: .speakerTest(channel)) }
    public var runCount: Int { configuration.runCount }

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// Live readings for the screen; nil until the first block arrives.
    public private(set) var progress: ExternalMeasurementProgress? {
        didSet {
            guard let progress else { return }
            for continuation in progressContinuations.values { continuation.yield(progress) }
        }
    }

    /// Whether the test's task is still running. False once `run()` has returned.
    public var isRunning: Bool { task != nil }

    @ObservationIgnored private let io: any AudioIO
    @ObservationIgnored private let permission: any MicrophonePermission
    @ObservationIgnored private let stillness: any StillnessMonitor
    @ObservationIgnored private var task: Task<State, Never>?
    @ObservationIgnored private var progressContinuations: [UUID: AsyncStream<ExternalMeasurementProgress>.Continuation] = [:]
    /// Called on every state change, synchronously; for tests.
    @ObservationIgnored var onStateChange: ((State) -> Void)?

    /// - Parameters:
    ///   - channel: The speaker tested; the user plays `TestSoundFile(kind: .speakerTest(channel))`.
    ///   - configuration: `runCount` runs are needed; the recording's lead-in and tail come from it.
    public init(
        io: any AudioIO,
        channel: SpeakerChannel,
        permission: any MicrophonePermission,
        stillness: any StillnessMonitor,
        configuration: MeasurementConfiguration = .standard,
        thresholds: QualityThresholds = .standard
    ) {
        precondition(configuration.runCount <= TestSoundFile.speakerTestSweepCount, "a speaker test file holds three sweeps")
        self.io = io
        self.channel = channel
        self.permission = permission
        self.stillness = stillness
        self.configuration = configuration
        self.thresholds = thresholds
    }

    /// Starts the test in its own task. Does nothing if it has already started.
    public func start() {
        guard task == nil, state == .idle else { return }
        task = Task { await self.perform() }
    }

    /// Starts the test if needed and waits for it to end; returns the final state. Cancelling the calling task
    /// cancels the test.
    @discardableResult
    public func run() async -> State {
        start()
        guard let task else { return state }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Stops listening: the audio is released and the state becomes `failed(.measurement(.cancelled))`. Safe in any
    /// state and more than once (after the end it does nothing).
    public func cancel() {
        if let task {
            task.cancel()
        } else if state == .idle {
            state = .failed(.measurement(.cancelled))
        }
    }

    /// Every progress update from now until the test ends.
    public func progressUpdates() -> AsyncStream<ExternalMeasurementProgress> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ExternalMeasurementProgress>.makeStream(bufferingPolicy: .unbounded)
        if state.isFinal {
            continuation.finish()
            return stream
        }
        progressContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.progressContinuations[id] = nil }
        }
        return stream
    }

    // MARK: - The test

    private func perform() async -> State {
        let final = await measure()
        state = final
        for continuation in progressContinuations.values { continuation.finish() }
        progressContinuations = [:]
        task = nil
        return final
    }

    private func measure() async -> State {
        guard await MeasurementOpening.hasAccess(permission) else { return .failed(.measurement(.permissionDenied)) }
        guard !Task.isCancelled else { return .failed(.measurement(.cancelled)) }

        state = .measuringNoiseFloor
        let stream: CaptureStream
        do {
            stream = try await io.start()
        } catch {
            return .failed(.measurement(.audioUnavailable(String(describing: error))))
        }
        guard stream.sampleRate >= MeasurementConfiguration.minimumSampleRate else {
            await io.stop()
            return .failed(.measurement(.audioUnavailable("the input runs at \(Int(stream.sampleRate)) Hz")))
        }
        stillness.start()
        defer { stillness.stop() }

        var test = Listening(sampleRate: stream.sampleRate, kind: file.kind, configuration: configuration, thresholds: thresholds)
        var outcome: State?
        do {
            blocks: for try await captured in stream.blocks {
                if Task.isCancelled { break }
                let (blocks, gap) = test.reblocker.append(captured)
                if gap {
                    if test.floor == nil { test.floorListener.reset() } else { test.listener.restartAfterGap(at: captured.position) }
                }
                for block in blocks {
                    if let final = await handle(block, in: &test) {
                        outcome = final
                        break blocks
                    }
                    if Task.isCancelled { break blocks }
                }
                // A backlog of blocks must not hold the main actor for more than one block's work.
                await Task.yield()
            }
        } catch {
            outcome = .failed(.measurement(MeasurementFailure(streamError: error)))
        }
        await io.stop()
        if Task.isCancelled, outcome?.isFinished != true { return .failed(.measurement(.cancelled)) }
        return outcome ?? .failed(.measurement(.interrupted))
    }

    /// One run heard and checked, kept until its file is known and the test can finish.
    private struct Candidate {
        var play: Int
        var identity: SweepIdentity?
        var inspection: SweepInspection
        var phoneMoved: Bool
        /// `valid`, with its level and ratio.
        var verdict: RecordingVerdict
        /// For `SweepTiedNoise`: the run's number in the session, and where in the sweep, hertz, it heard noise that
        /// came back at the same place in another run (`RunRecording.sweepTiedSound`).
        var id = 0
        var sweepTied: ClosedRange<Double>?
    }

    /// Everything one test keeps between blocks.
    private struct Listening {
        let sampleRate: Double
        let sweep: LogSweep
        let configuration: MeasurementConfiguration
        var reblocker: Reblocker
        var floorListener: FloorListener
        var floor: NoiseFloorReport?
        var detector: SweepNoiseDetector?
        var listener: ExternalListener
        /// Valid runs heard, in order.
        var kept: [Candidate] = []
        /// Why the latest play fell short.
        var lastProblem: ExternalPlayProblem?
        /// Capture positions: where listening began (after the floor).
        var listeningSince: Int64 = 0
        /// What the latest play that fell short says was heard (`ExternalListener.hearing(after:)`); nil while a play
        /// is under way and before the first.
        var latestHearing: ExternalHearing?
        /// Where the finder found each play's sweeps, usable or not: their spacing gives the clock without the tone.
        var foundStarts: [Int: [Double]] = [:]
        /// Cuts the finder did not take while their place in the file was unknown: checked again, anchored, once a
        /// later sweep's spacing places them (a speaker that plays only part of the range whose tone was not heard).
        var deferred: [SweepCut] = []
        /// Runs too noisy so far, waiting for their noise to come back at the same place in another run
        /// (`SweepTiedNoise`), and where noise was heard in every run.
        var noisy: [Candidate] = []
        var tiedNoise: SweepTiedNoise
        var checkedRuns = 0

        init(sampleRate: Double, kind: TestSoundFile.Kind, configuration: MeasurementConfiguration, thresholds: QualityThresholds) {
            self.sampleRate = sampleRate
            self.configuration = configuration
            tiedNoise = SweepTiedNoise(tolerance: configuration.sweepTiedTolerance)
            sweep = configuration.sweep(sampleRate: sampleRate)
            let blockLength = configuration.samples(configuration.blockDuration, at: sampleRate)
            reblocker = Reblocker(length: blockLength)
            floorListener = FloorListener(sampleRate: sampleRate, sweep: sweep, blockLength: blockLength, configuration: configuration, thresholds: thresholds)
            listener = ExternalListener(sampleRate: sampleRate, sweep: sweep, expected: kind, configuration: configuration)
        }

        func seconds(_ samples: Int64) -> Double { Double(samples) / sampleRate }

        /// Runs whose file is known to be the expected one.
        var confirmed: [Candidate] { kept.filter { $0.identity != nil } }
    }

    /// Takes one block; returns the final state when the test has ended.
    private func handle(_ block: CapturedBlock, in test: inout Listening) async -> State? {
        let steady = stillness.isSteady
        let clipped = ClippingDetector.detect(block.samples, thresholds: thresholds).isClipped
        guard let floor = test.floor else {
            report(block, test: test, steady: steady, clipped: clipped)
            if let (floor, detector) = test.floorListener.listen(block) {
                test.detector = detector
                test.floor = floor
                test.listeningSince = block.end
                test.listener.markListening(at: block.end)
                state = .waitingForSound
            } else if test.floorListener.hasTimedOut {
                return .failed(.measurement(.tooNoisy))
            }
            return nil
        }

        let loud = SoundLevel(of: block.samples).dBFS > floor.rmsDecibels + thresholds.pauseMarginDecibels
        for event in test.listener.consume(block, steady: steady, loud: loud) {
            switch event {
            case .toneStarted:
                test.latestHearing = nil
                state = .hearing(run: min(test.confirmed.count + 1, runCount))
            case .toneRead(let ratio):
                if let ratio, !SweepFinder.isCorrectable(ratio) { return .failed(.playerClockOff(ratio: ratio)) }
            case .sweepStarted(let play, _):
                test.latestHearing = nil
                state = .hearing(run: min(test.confirmed.count + 1, runCount))
                if let final = await recheckDeferred(play: play, floor: floor, in: &test) { return final }
            case .wrongFile(let play, let heard):
                test.kept.removeAll { $0.play == play }
                test.noisy.removeAll { $0.play == play }
                test.lastProblem = .wrongFile(heard: heard)
                test.latestHearing = .notTheTestSound
                state = .needsAnotherPlay(have: test.confirmed.count, reason: test.lastProblem)
            case .cutReady:
                while let cut = test.listener.takeCut() {
                    if let final = await check(cut, floor: floor, in: &test) { return final }
                }
            case .playOver(let play):
                if let final = await playEnded(play, in: &test) { return final }
            }
        }
        report(block, test: test, steady: steady, clipped: clipped)

        if let failure = test.listener.silenceFailure(at: block.end) { return .failed(failure) }
        if test.seconds(block.end - test.listeningSince) >= ExternalListening.maximumListeningTime {
            return .failed(.listeningTimeUp(lastProblem: test.lastProblem))
        }
        return nil
    }

    /// Checks one cut; keeps it when it is usable and of the right file.
    private func check(_ cut: SweepCut, floor: NoiseFloorReport, in test: inout Listening) async -> State? {
        let run = min(test.confirmed.count + 1, runCount)
        state = .checking(run: run)
        let inspection = await SweepInspection.inspect(
            cut, sweep: test.sweep, floor: floor, detector: test.detector, thresholds: thresholds,
            ratio: test.listener.ratio(forPlay: cut.play),
            leadIn: test.listener.leadIn, tail: test.listener.tail
        )
        guard !Task.isCancelled else { return nil }
        if let start = inspection.start { test.foundStarts[cut.play, default: []].append(start) }
        // The follower was fooled, or the play turned out to be another file: nothing to keep. A cut not yet placed
        // in the file may be a speaker that plays part of the range: it waits to be placed.
        let wrong = test.listener.plays.first { $0.id == cut.play }?.wrongFile
        if inspection.start == nil, wrong == nil, cut.identity == nil { test.deferred.append(cut) }
        guard inspection.start != nil, wrong == nil else {
            if wrong == nil {
                state = test.listener.currentPlay == nil ? .waitingForSound : .hearing(run: run)
            } else {
                state = .needsAnotherPlay(have: test.confirmed.count, reason: test.lastProblem)
            }
            return nil
        }
        // The identity may have become known since the cut (a later sweep's spacing).
        let identity = test.listener.plays.first { $0.id == cut.play }?.sweeps.first { $0.estimate == cut.estimate }?.identity ?? cut.identity
        test.checkedRuns += 1
        if case .unusable(.tooNoisy) = inspection.problem, !inspection.noise.isEmpty, let clean = inspection.cleanVerdict {
            // Too noisy, unless the noise comes back at the same place in another run.
            test.noisy.append(Candidate(
                play: cut.play, identity: identity, inspection: inspection, phoneMoved: cut.phoneMoved, verdict: clean, id: test.checkedRuns
            ))
            test.tiedNoise.record(id: test.checkedRuns, stretches: inspection.noise)
            if !keepTied(&test, now: test.checkedRuns), let problem = inspection.problem { test.lastProblem = .run(problem) }
        } else if let problem = inspection.problem {
            test.lastProblem = inspection.stoppedAt != nil ? .stoppedPartWay : .run(problem)
        } else if case .valid = inspection.verdict {
            test.kept.append(Candidate(
                play: cut.play, identity: identity, inspection: inspection, phoneMoved: cut.phoneMoved,
                verdict: inspection.verdict ?? .valid(level: LevelMeter.measure(inspection.samples), signalToNoise: 0)
            ))
        }
        if test.confirmed.count >= runCount {
            if let final = await finish(&test) { return final }
            // A run was dropped (its clock unknown, or it strayed from the others); with the play over, the file has
            // been asked for again.
            if test.listener.currentPlay == nil { return nil }
        }
        state = test.listener.currentPlay == nil ? .waitingForSound : .hearing(run: min(test.confirmed.count + 1, runCount))
        // Every sweep of the file has been heard: no need to wait for the play to time out.
        if let play = test.listener.plays.first(where: { $0.id == cut.play }),
           play.sweeps.count >= TestSoundFile.speakerTestSweepCount, test.listener.isQuiet {
            test.listener.endPlay(cut.play)
            return await playEnded(cut.play, in: &test)
        }
        return nil
    }

    /// Moves the runs waiting for their noise to come back (`Listening.noisy`) whose noise has now been heard at the
    /// same place in another run to the kept runs, marked with where (`SweepTiedNoise`). Returns whether run `now` was
    /// among them.
    @discardableResult
    private func keepTied(_ test: inout Listening, now: Int) -> Bool {
        var keptNow = false
        for candidate in test.noisy where test.tiedNoise.isTied(candidate.id) {
            var tied = candidate
            tied.sweepTied = SweepTiedNoise.frequencies(of: candidate.inspection.noise, sweep: test.sweep)
            test.kept.append(tied)
            if candidate.id == now { keptNow = true }
        }
        test.noisy.removeAll { test.tiedNoise.isTied($0.id) }
        return keptNow
    }

    /// A play is over: runs that never got a file are dropped, and the file is asked for again if runs are missing.
    private func playEnded(_ play: Int, in test: inout Listening) async -> State? {
        test.deferred.removeAll { $0.play == play }
        test.noisy.removeAll { $0.play == play && $0.identity == nil }
        refreshIdentities(&test)
        let unknown = test.kept.contains { $0.play == play && $0.identity == nil }
        test.kept.removeAll { $0.play == play && $0.identity == nil }
        if test.confirmed.count >= runCount, let final = await finish(&test) { return final }
        if unknown, test.lastProblem == nil { test.lastProblem = .missedSweeps }
        let reason = test.lastProblem ?? .missedSweeps
        if test.latestHearing != .notTheTestSound { test.latestHearing = ExternalListener.hearing(after: reason) }
        state = .needsAnotherPlay(have: test.confirmed.count, reason: reason)
        test.lastProblem = nil
        test.listener.markListening(at: test.listener.lastHeard)
        return nil
    }

    /// Identities learned after a run was kept (from a later sweep of its play).
    private func refreshIdentities(_ test: inout Listening) {
        for index in test.kept.indices where test.kept[index].identity == nil {
            let candidate = test.kept[index]
            guard let start = candidate.inspection.start else { continue }
            let tolerance = 0.2 * test.sampleRate
            test.kept[index].identity = test.listener.plays.first { $0.id == candidate.play }?
                .sweeps.first { abs(Double($0.estimate) - start) < tolerance }?
                .identity
        }
    }

    /// Three runs of the right file: each corrected for its play's clock (from the tone, else the spacing of the
    /// play's sweeps, else the latest tone), checked against each other (`ExternalListening.runAgreementDecibels`: a
    /// run that strays from the others is dropped and another play asked for), then the result.
    private func finish(_ test: inout Listening) async -> State? {
        guard let floor = test.floor else { return nil }
        var corrected: [(candidate: Candidate, inspection: SweepInspection, clock: (ratio: Double, source: ClockSource, disagreement: Double?))] = []
        for candidate in test.confirmed.prefix(runCount) {
            var inspection = candidate.inspection
            guard let clock = clockEstimate(forPlay: candidate.play, in: test) else {
                test.kept.removeAll { $0.play == candidate.play }
                test.lastProblem = .clockUnknown
                state = .needsAnotherPlay(have: test.confirmed.count, reason: .clockUnknown)
                return nil
            }
            if !SweepFinder.isCorrectable(clock.ratio) { return .failed(.playerClockOff(ratio: clock.ratio)) }
            if inspection.ratio != clock.ratio {
                inspection = await SweepInspection.recorrected(inspection, ratio: clock.ratio, sweep: test.sweep)
                guard !Task.isCancelled else { return nil }
            }
            corrected.append((candidate, inspection, clock))
        }
        if let disagreement = await SweepInspection.disagreement(corrected.map(\.inspection), sweep: test.sweep) {
            guard !Task.isCancelled else { return nil }
            let strays = zip(corrected, disagreement).filter { $0.1 > ExternalListening.runAgreementDecibels }.map { $0.0.candidate.inspection.start }
            if !strays.isEmpty {
                test.kept.removeAll { strays.contains($0.inspection.start) }
                test.lastProblem = .runsDisagree
                state = test.listener.currentPlay == nil
                    ? .needsAnotherPlay(have: test.confirmed.count, reason: .runsDisagree)
                    : .hearing(run: min(test.confirmed.count + 1, runCount))
                return nil
            }
        }
        var runs: [RunRecording] = []
        for (number, (candidate, inspection, clock)) in corrected.enumerated() {
            var run = RunRecording(
                run: number + 1,
                samples: inspection.samples,
                sampleRate: test.sampleRate,
                leadIn: inspection.leadIn,
                arrivalDelay: Double(inspection.leadIn) / test.sampleRate,
                verdict: candidate.verdict,
                spliceCount: 0,
                phoneMoved: candidate.phoneMoved,
                attempt: min(candidate.play, 2),
                sweepTiedSound: candidate.sweepTied,
                measuredDelay: inspection.measuredDelay,
                clockRatio: clock.ratio
            )
            run.clockSource = clock.source
            run.clockDisagreementPPM = clock.disagreement
            runs.append(run)
        }
        return .finished(MeasurementResult(channel: channel, sweep: test.sweep, noiseFloor: floor, runs: runs, source: .anotherDevice))
    }

    /// Cuts deferred from play `play` that a later sweep's spacing has now placed, checked again, anchored.
    private func recheckDeferred(play: Int, floor: NoiseFloorReport, in test: inout Listening) async -> State? {
        guard let record = test.listener.plays.first(where: { $0.id == play }) else { return nil }
        let placed = test.deferred.filter { cut in
            cut.play == play && record.sweeps.contains { $0.estimate == cut.estimate && $0.identity != nil }
        }
        test.deferred.removeAll { cut in placed.contains { $0.estimate == cut.estimate } }
        for var cut in placed {
            cut.identity = record.sweeps.first { $0.estimate == cut.estimate }?.identity
            if let final = await check(cut, floor: floor, in: &test) { return final }
        }
        return nil
    }

    /// The clock of play `play`, where it came from, and how far the tone and the sweeps' spacing disagreed when both
    /// gave one (ppm).
    ///
    /// Its tone's, unless the spacing of three of its sweeps as found (usable or not: one speaker, one path, two
    /// baselines of 7 s or more) differs from it by more than `ExternalListening.clockAgreementPPM`: a phone drifting
    /// during the 3 s tone reads 30 ppm per cm/s, while the spacing barely moves, so the spacing is used then. Without
    /// a tone, the spacing of two or more sweeps (the fallback for a speaker that cannot play the 1 kHz tone); else the
    /// latest still tone's.
    private func clockEstimate(forPlay play: Int, in test: Listening) -> (ratio: Double, source: ClockSource, disagreement: Double?)? {
        let tone = test.listener.plays.first { $0.id == play }?.ratio
        let starts = test.foundStarts[play] ?? []
        let fit = file.layout.spacing.flatMap { SweepFinder.clockFit(starts: starts, expectedSpacing: $0, sampleRate: test.sampleRate) }
        switch (tone, fit) {
        case let (tone?, fit?) where starts.count >= 3 && fit.residual <= ExternalListening.maximumSpacingResidual:
            let apart = abs(tone - fit.ratio) * 1e6
            return apart <= ExternalListening.clockAgreementPPM ? (tone, .tone, apart) : (fit.ratio, .sweepSpacing, apart)
        case let (tone?, _):
            return (tone, .tone, nil)
        case let (nil, fit?):
            return (fit.ratio, .sweepSpacing, nil)
        case (nil, nil):
            return test.listener.knownRatio.map { ($0, .earlierPlay, nil) }
        }
    }

    private func report(_ block: CapturedBlock, test: Listening, steady: Bool, clipped: Bool) {
        let level = SoundLevel(of: block.samples)
        let mark = test.floor.map {
            SoundLevel(dBFS: min($0.rmsDecibels + thresholds.resumeMarginDecibels, thresholds.resumeCeilingDecibels))
        }
        let listener = test.listener
        let waiting: Bool = switch state {
        case .waitingForSound, .needsAnotherPlay: listener.isQuiet
        default: false
        }
        let silence = test.seconds(block.end - listener.lastHeard)
        // The clock as the result would take it, for the current or latest play.
        let play = listener.currentPlay ?? listener.plays.last
        let clock = play.flatMap { clockEstimate(forPlay: $0.id, in: test) }
        let ratio = clock?.ratio ?? listener.knownRatio
        // Said as soon as two sweeps' spacing disagrees with the tone, before the third confirms it.
        var disagreement = clock?.disagreement
        if disagreement == nil, let play, let tone = play.ratio, let spacing = file.layout.spacing,
           let fit = SweepFinder.clockFit(starts: test.foundStarts[play.id] ?? [], expectedSpacing: spacing, sampleRate: test.sampleRate) {
            disagreement = abs(tone - fit.ratio) * 1e6
        }
        // While the test sound is heard, the room without it, as the normal test's progress reads it.
        let room = !listener.isQuiet ? test.detector.map { $0.assess(block.samples).roomLevel } ?? level : level
        progress = ExternalMeasurementProgress(
            runsInHand: test.confirmed.count,
            runsNeeded: runCount,
            hearingRun: listener.isHearingSweep ? min(test.confirmed.count + 1, runCount) : nil,
            frequency: listener.heardFrequency,
            sweepFraction: listener.sweepFraction,
            isHearingTone: listener.isHearingTone,
            clockOffsetPPM: ratio.map { ($0 - 1) * 1e6 },
            roomLevel: room,
            quietEnoughLevel: mark,
            isRoomQuiet: room.dBFS <= (mark?.dBFS ?? .infinity),
            inputLevel: level,
            inputPeakDecibels: LevelMeter.measure(block.samples).peakDecibels,
            isClipping: clipped,
            isPhoneSteady: steady,
            silentFor: waiting && test.floor != nil ? silence : nil,
            isSilenceLong: waiting && test.floor != nil && silence >= ExternalListening.nothingHeardHint,
            hearing: test.floor == nil ? .nothing : listener.hearing(latest: test.latestHearing),
            clockDisagreementPPM: disagreement.flatMap { $0 > ExternalListening.clockDisagreementLimitPPM ? $0 : nil }
        )
    }
}

private extension ExternalMeasurementSession.State {
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}
