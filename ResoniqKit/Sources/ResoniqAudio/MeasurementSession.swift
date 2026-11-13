import Foundation
import Observation
import ResoniqDSP

/// One speaker test: measures the room's floor, plays the sweep `runCount` times on one channel, pauses for noise and
/// splices, checks each recording, and ends with every run's recording or a reason.
///
/// **Isolation: the main actor.** The screens observe `state` and `progress` directly, and the work done per 100 ms
/// block (one 8192-point transform, a level, a few comparisons) costs well under a millisecond, so there is nothing
/// to gain from a separate actor and a stream of states to mirror back. The two heavier steps leave the main actor:
/// capture runs on the IO's own threads, and checking a finished recording runs off it (`assess`). The capture
/// timeline is the session's only clock: every wait (the floor, the quiet before resuming, the decay) is counted in
/// captured samples, so a test driven by `SimulatedAudioIO` runs as fast as the arithmetic and gives the same answer
/// as one in real time.
@MainActor
@Observable
public final class MeasurementSession {
    /// Where a test is.
    public enum State: Sendable, Equatable {
        case idle
        /// Listening to the room before the first run.
        case measuringNoiseFloor
        /// The sweep is playing, or its end is still arriving and dying away.
        case playing(run: Int, note: RunNote?)
        /// Noise stopped the sweep; it picks up at `resumeFrequency` once the room is quiet.
        case paused(run: Int, resumeFrequency: Double)
        /// The run's recording is being checked.
        case checking(run: Int)
        case finished(MeasurementResult)
        case failed(MeasurementFailure)

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

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// Live readings for the screen; nil until the first block arrives.
    public private(set) var progress: MeasurementProgress? {
        didSet {
            guard let progress else { return }
            for continuation in progressContinuations.values { continuation.yield(progress) }
        }
    }

    public var runCount: Int { configuration.runCount }

    /// Whether the test's task is still running. False once `run()` has returned.
    public var isRunning: Bool { task != nil }

    /// The audio to classify when noise ended the test or spoiled a recording: the latest audio kept while the run
    /// was paused when the room never quietened (`failed(.tooNoisy)`, `sweepPlaying` false), or the recording itself
    /// when its check judged it too noisy (repeated, or failed as `recordingUnusable`; `sweepPlaying` true). Nil when
    /// neither happened. The latest one wins.
    public private(set) var noisyRecording: CapturedAudio?

    /// While the test is `paused` for noise: the latest captured audio of the pause, at most
    /// `CapturedAudio.pausedDuration`, for naming the noise. Nil in any other state.
    public func pausedAudio() -> CapturedAudio? {
        guard case .paused = state else { return nil }
        return paused?.audio
    }

    @ObservationIgnored private var paused: PausedAudioKeeper?
    @ObservationIgnored private let io: any AudioIO
    @ObservationIgnored private let permission: any MicrophonePermission
    @ObservationIgnored private let stillness: any StillnessMonitor
    @ObservationIgnored private var task: Task<State, Never>?
    @ObservationIgnored private var progressContinuations: [UUID: AsyncStream<MeasurementProgress>.Continuation] = [:]
    /// Called on every state change, synchronously; for tests.
    @ObservationIgnored var onStateChange: ((State) -> Void)?

    public init(
        io: any AudioIO,
        channel: SpeakerChannel,
        permission: any MicrophonePermission,
        stillness: any StillnessMonitor,
        configuration: MeasurementConfiguration = .standard,
        thresholds: QualityThresholds = .standard
    ) {
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

    /// Stops the test: playback stops at once, the audio is released, and the state becomes `failed(.cancelled)`.
    /// Safe in any state and more than once (after the end it does nothing), so the app calls it when the scene
    /// leaves the foreground.
    public func cancel() {
        if let task {
            task.cancel()
        } else if state == .idle {
            state = .failed(.cancelled)
        }
    }

    /// Every progress update from now until the test ends.
    public func progressUpdates() -> AsyncStream<MeasurementProgress> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MeasurementProgress>.makeStream(bufferingPolicy: .unbounded)
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
        guard await MeasurementOpening.hasAccess(permission) else { return .failed(.permissionDenied) }
        guard !Task.isCancelled else { return .failed(.cancelled) }

        state = .measuringNoiseFloor
        let stream: CaptureStream
        switch await MeasurementOpening.open(io) {
        case .success(let opened): stream = opened
        case .failure(let failure): return .failed(failure)
        }
        stillness.start()
        defer { stillness.stop() }
        paused = PausedAudioKeeper(sampleRate: stream.sampleRate)

        var test = TestRun(
            sampleRate: stream.sampleRate,
            channel: channel,
            configuration: configuration,
            thresholds: thresholds
        )
        var outcome: State?
        do {
            blocks: for try await captured in stream.blocks {
                if Task.isCancelled { break }
                let (blocks, gap) = test.reblocker.append(captured)
                if gap { restartAfterGap(&test) }
                for block in blocks {
                    if let final = try await handle(block, in: &test) {
                        outcome = final
                        break blocks
                    }
                    if Task.isCancelled { break blocks }
                }
                // Blocks already waiting in the stream arrive without a suspension; give the main actor back after
                // each one, so a backlog cannot hold it (the screen, a cancel) for longer than one block's work.
                await Task.yield()
            }
        } catch {
            outcome = .failed(MeasurementFailure(streamError: error))
        }
        io.stopPlayback()
        await io.stop()
        if Task.isCancelled, outcome?.isFinished != true { return .failed(.cancelled) }
        // The stream ended on its own: the audio went away under the test.
        return outcome ?? .failed(.interrupted)
    }

    /// Everything one test keeps between blocks.
    private struct TestRun {
        let sampleRate: Double
        let sweep: LogSweep
        let sweepSamples: [Float]
        let channel: SpeakerChannel
        let configuration: MeasurementConfiguration
        var reblocker: Reblocker
        var listener: FloorListener
        var floor: NoiseFloorReport?
        var detector: SweepNoiseDetector?
        var tracker = ArrivalTracker()
        var performer: RunPerformer
        var run = 1
        var recordings: [RunRecording] = []

        init(sampleRate: Double, channel: SpeakerChannel, configuration: MeasurementConfiguration, thresholds: QualityThresholds) {
            self.sampleRate = sampleRate
            self.channel = channel
            self.configuration = configuration
            sweep = configuration.sweep(sampleRate: sampleRate)
            sweepSamples = sweep.samples()
            let blockLength = configuration.samples(configuration.blockDuration, at: sampleRate)
            reblocker = Reblocker(length: blockLength)
            listener = FloorListener(
                sampleRate: sampleRate,
                sweep: sweep,
                blockLength: blockLength,
                configuration: configuration,
                thresholds: thresholds
            )
            performer = RunPerformer(channel: channel, sweep: sweep, sweepSamples: sweepSamples, configuration: configuration)
        }

        /// The next run starts afresh: first attempt, no note, no restarts.
        mutating func nextRun() {
            run += 1
            performer = RunPerformer(channel: channel, sweep: sweep, sweepSamples: sweepSamples, configuration: configuration)
        }
    }

    private func restartAfterGap(_ test: inout TestRun) {
        if test.floor == nil {
            test.listener.reset()
        } else {
            test.performer.restartAfterGap(io: io)
        }
    }

    /// Takes one block; returns the final state when the test has ended.
    private func handle(_ block: CapturedBlock, in test: inout TestRun) async throws -> State? {
        guard let floor = test.floor, let detector = test.detector else {
            measureFloor(block, in: &test)
            // No floor within the longest wait: the room is too loud or never steady.
            return test.floor == nil && test.listener.hasTimedOut ? .failed(.tooNoisy) : nil
        }

        let assessment = detector.assess(block.samples)
        let quiet = NoiseGate.isQuietEnough(block: block.samples, baseline: floor.rmsDecibels, thresholds: thresholds)
        let steady = stillness.isSteady
        let clipped = ClippingDetector.detect(block.samples, thresholds: thresholds).isClipped

        guard test.performer.isRecording else {
            // A new run (or a repeated or restarted one) starts with this block.
            switch try test.performer.begin(with: block, clipped: clipped, io: io) {
            case .playing(let note):
                state = .playing(run: test.run, note: note)
                report(block, assessment: assessment, quiet: quiet, steady: steady, clipped: clipped, test: test)
                return nil
            case .failed(let problem):
                return .failed(.recordingUnusable(problem))
            default:
                return nil
            }
        }

        let step = try test.performer.consume(
            block,
            assessment: assessment,
            quiet: quiet,
            steady: steady,
            clipped: clipped,
            tracker: &test.tracker,
            sampleRate: test.sampleRate,
            io: io
        )
        if case .paused = step { paused?.pauseBegan(skipping: sweepArrival(block, delay: test.tracker.delay, sampleRate: test.sampleRate)) }
        if test.performer.isPaused { paused?.keep(block.samples) }
        report(block, assessment: assessment, quiet: quiet, steady: steady, clipped: clipped, test: test)

        switch step {
        case .none, .repeating:
            return nil
        case .paused(let frequency):
            state = .paused(run: test.run, resumeFrequency: frequency)
            return nil
        case .playing(let note):
            state = .playing(run: test.run, note: note)
            return nil
        case .failed(let problem):
            return .failed(.recordingUnusable(problem))
        case .tooNoisy:
            noisyRecording = paused?.audio
            return .failed(.tooNoisy)
        case .recorded(let recording):
            return await check(recording, in: &test)
        }
    }

    /// Samples from `block`, where a pause began, until the sweep stopped at the speakers can no longer be heard.
    private func sweepArrival(_ block: CapturedBlock, delay: Int?, sampleRate: Double) -> Int {
        PausedAudioKeeper.sweepArrival(delay: delay, blockLength: block.samples.count, configuration: configuration, sampleRate: sampleRate)
    }

    private func measureFloor(_ block: CapturedBlock, in test: inout TestRun) {
        progress = MeasurementProgress(
            run: test.run,
            runCount: runCount,
            roomLevel: SoundLevel(of: block.samples),
            quietEnoughLevel: nil,
            isRoomQuiet: false,
            inputLevel: SoundLevel(of: block.samples),
            inputPeakDecibels: LevelMeter.measure(block.samples).peakDecibels,
            isClipping: false,
            isPhoneSteady: stillness.isSteady,
            routeDelay: nil
        )
        if let (floor, detector) = test.listener.listen(block) {
            test.floor = floor
            test.detector = detector
        }
    }

    private func report(
        _ block: CapturedBlock,
        assessment: SweepNoiseDetector.Assessment,
        quiet: Bool,
        steady: Bool,
        clipped: Bool,
        test: TestRun
    ) {
        let paused = test.performer.isPaused
        let delay = test.tracker.delay
        let arriving = test.performer.arriving(at: block, delay: delay, sampleRate: test.sampleRate)
        let mark = test.floor.map {
            SoundLevel(dBFS: min($0.rmsDecibels + thresholds.resumeMarginDecibels, thresholds.resumeCeilingDecibels))
        }
        let room = paused ? assessment.blockLevel : assessment.roomLevel
        progress = MeasurementProgress(
            run: test.run,
            runCount: runCount,
            frequency: arriving?.frequency,
            sweepFraction: arriving?.fraction,
            roomLevel: room,
            quietEnoughLevel: mark,
            isRoomQuiet: paused ? quiet : room.dBFS <= (mark?.dBFS ?? .infinity),
            inputLevel: assessment.blockLevel,
            inputPeakDecibels: LevelMeter.measure(block.samples).peakDecibels,
            isClipping: clipped,
            isPhoneSteady: steady,
            routeDelay: delay.map { Double($0) / test.sampleRate }
        )
    }

    private func check(_ recording: RunRecorder.Recording, in test: inout TestRun) async -> State? {
        guard let floor = test.floor else { return nil }
        state = .checking(run: test.run)
        let (verdict, problem, measuredDelay) = await RunPerformer.inspect(recording.samples, sweep: test.sweep, floor: floor, thresholds: thresholds)
        guard !Task.isCancelled else { return nil }
        if case .tooNoisy = verdict {
            noisyRecording = CapturedAudio(samples: recording.samples, sampleRate: test.sampleRate, sweepPlaying: true)
        }
        let conclusion = test.performer.conclude(
            recording,
            verdict: verdict,
            problem: problem,
            measuredDelay: measuredDelay,
            run: test.run,
            delay: test.tracker.delay,
            sampleRate: test.sampleRate,
            io: io
        )
        switch conclusion {
        case .repeating:
            return nil
        case .failed(let problem):
            return .failed(.recordingUnusable(problem))
        case .kept(let kept):
            test.recordings.append(kept)
        }
        if test.recordings.count == runCount {
            return .finished(MeasurementResult(channel: channel, sweep: test.sweep, noiseFloor: floor, runs: test.recordings))
        }
        test.nextRun()
        return nil
    }

    /// Checks a finished recording off the main actor: `RunPerformer.check`, which says what is checked.
    @concurrent nonisolated static func check(
        _ samples: [Float],
        sweep: LogSweep,
        floor: NoiseFloorReport,
        thresholds: QualityThresholds
    ) async -> (verdict: RecordingVerdict, problem: RunProblem?) {
        await RunPerformer.check(samples, sweep: sweep, floor: floor, thresholds: thresholds)
    }
}

private extension MeasurementSession.State {
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}
