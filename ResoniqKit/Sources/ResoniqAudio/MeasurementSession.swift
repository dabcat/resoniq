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
        var access = permission.status
        if access == .undetermined {
            access = await permission.request() ? .granted : .denied
        }
        guard access == .granted else { return .failed(.permissionDenied) }
        guard !Task.isCancelled else { return .failed(.cancelled) }

        state = .measuringNoiseFloor
        let stream: CaptureStream
        do {
            stream = try await io.start()
        } catch {
            return .failed(.audioUnavailable(String(describing: error)))
        }
        guard stream.sampleRate >= MeasurementConfiguration.minimumSampleRate else {
            await io.stop()
            return .failed(.audioUnavailable(
                "the input runs at \(Int(stream.sampleRate)) Hz; the measurement sweep needs \(Int(MeasurementConfiguration.minimumSampleRate)) Hz"
            ))
        }
        stillness.start()
        defer { stillness.stop() }

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
            }
        } catch let error as AudioIOError {
            outcome = switch error {
            case .interrupted: .failed(.interrupted)
            case .routeChanged: .failed(.routeChanged)
            case .unavailable(let reason): .failed(.audioUnavailable(reason))
            case .notRunning: .failed(.audioUnavailable("the audio stopped"))
            }
        } catch {
            outcome = .failed(.audioUnavailable(String(describing: error)))
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
        let blockLength: Int
        var reblocker: Reblocker
        var settleRemaining: Int
        var floorSamples: [Float] = []
        var floor: NoiseFloorReport?
        var detector: SweepNoiseDetector?
        var tracker = ArrivalTracker()
        var recorder: RunRecorder?
        var run = 1
        var attempt = 1
        var note: RunNote?
        var phoneMoved = false
        /// Whether a block of this run clipped; it will be judged clipped when it ends.
        var clipped = false
        /// Times this run started again from the beginning.
        var restarts = 0
        var recordings: [RunRecording] = []

        init(sampleRate: Double, channel: SpeakerChannel, configuration: MeasurementConfiguration, thresholds: QualityThresholds) {
            self.sampleRate = sampleRate
            sweep = configuration.sweep(sampleRate: sampleRate)
            sweepSamples = sweep.samples()
            blockLength = configuration.samples(configuration.blockDuration, at: sampleRate)
            reblocker = Reblocker(length: blockLength)
            settleRemaining = configuration.samples(configuration.settleDuration, at: sampleRate)
        }
    }

    private func restartAfterGap(_ test: inout TestRun) {
        if test.floor == nil {
            test.floorSamples = []
        } else if test.recorder != nil {
            io.stopPlayback()
            test.recorder = nil
            test.note = .restarted(.timelineUnreliable)
            test.restarts += 1
        }
    }

    /// Takes one block; returns the final state when the test has ended.
    private func handle(_ block: CapturedBlock, in test: inout TestRun) async throws -> State? {
        guard let floor = test.floor, let detector = test.detector else {
            measureFloor(block, in: &test)
            return nil
        }

        let assessment = detector.assess(block.samples)
        let quiet = NoiseGate.isQuietEnough(block: block.samples, baseline: floor.rmsDecibels, thresholds: thresholds)
        let steady = stillness.isSteady
        let clipped = ClippingDetector.detect(block.samples, thresholds: thresholds).isClipped

        guard var recorder = test.recorder else {
            if test.restarts > configuration.maximumRestarts {
                return runFailed(.interruptedRepeatedly, in: &test)
            }
            // A new run (or a repeated or restarted one) starts with this block.
            var recorder = RunRecorder(sweep: test.sweep, sweepSamples: test.sweepSamples, configuration: configuration)
            try recorder.begin(with: block) { try io.schedule($0, on: channel, mode: .once) }
            test.recorder = recorder
            test.phoneMoved = false
            test.clipped = clipped
            state = .playing(run: test.run, note: test.note)
            report(block, assessment: assessment, quiet: quiet, steady: steady, clipped: clipped, test: test)
            return nil
        }

        if clipped { test.clipped = true }
        // A clipped sweep is full of harmonics the detector does not take out, so it reads as noise. Once a run has
        // clipped it is not paused: it will be judged clipped when it ends.
        let noisy = assessment.isTooNoisy && !test.clipped

        if !recorder.isPaused {
            if let origin = recorder.sweepOrigin {
                test.tracker.observe(
                    assessment,
                    noisy: noisy,
                    blockCentre: block.position + Int64(block.samples.count / 2),
                    sweepOrigin: origin,
                    sweep: test.sweep,
                    maximumDelay: configuration.samples(configuration.maximumRouteDelay, at: test.sampleRate)
                )
            }
            if !steady { test.phoneMoved = true }
        }

        let io = io
        let channel = channel
        let event = try recorder.consume(
            block,
            noisy: noisy,
            quietEnough: quiet,
            delay: test.tracker.delay,
            schedule: { try io.schedule($0, on: channel, mode: .once) },
            stopPlayback: { io.stopPlayback() }
        )
        test.recorder = recorder
        report(block, assessment: assessment, quiet: quiet, steady: steady, clipped: clipped, test: test)

        switch event {
        case .none:
            return nil
        case .paused(let frequency):
            state = .paused(run: test.run, resumeFrequency: frequency)
            return nil
        case .resumed(let restarted):
            if let restarted {
                test.note = .restarted(restarted)
                test.restarts += 1
                if test.restarts > configuration.maximumRestarts {
                    return runFailed(.interruptedRepeatedly, in: &test)
                }
            }
            state = .playing(run: test.run, note: test.note)
            return nil
        case .spliceFailed:
            io.stopPlayback()
            test.recorder = nil
            test.note = .restarted(.timelineUnreliable)
            test.restarts += 1
            return nil
        case .didNotArrive:
            return runFailed(.didNotArrive, in: &test)
        case .finished(let recording):
            return await check(recording, in: &test)
        }
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
        if test.settleRemaining > 0 {
            test.settleRemaining -= block.samples.count
            return
        }
        test.floorSamples += block.samples
        let needed = configuration.samples(configuration.noiseFloorDuration, at: test.sampleRate)
        guard test.floorSamples.count >= needed else { return }
        let report = NoiseFloor.measure(test.floorSamples, sampleRate: test.sampleRate, thresholds: thresholds)
        if report.isSteady, report.rmsDecibels <= thresholds.resumeCeilingDecibels {
            test.floor = report
            test.detector = SweepNoiseDetector(
                noiseFloor: test.floorSamples,
                sweep: test.sweep,
                blockLength: test.blockLength,
                thresholds: thresholds
            )
        } else {
            // Not a floor yet: someone talked, or the room is too loud. Keep listening, half a window at a time.
            test.floorSamples.removeFirst(needed / 2)
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
        let paused = test.recorder?.isPaused ?? false
        let delay = test.tracker.delay
        var frequency: Double?
        var fraction: Double?
        if !paused, let delay, let origin = test.recorder?.sweepOrigin {
            let heard = Double(block.position + Int64(block.samples.count / 2) - origin - Int64(delay))
            if heard >= 0, heard <= Double(test.sweepSamples.count) {
                fraction = heard / Double(test.sweepSamples.count)
                frequency = test.sweep.frequency(at: heard / test.sampleRate)
            }
        }
        let mark = test.floor.map {
            SoundLevel(dBFS: min($0.rmsDecibels + thresholds.resumeMarginDecibels, thresholds.resumeCeilingDecibels))
        }
        let room = paused ? assessment.blockLevel : assessment.roomLevel
        progress = MeasurementProgress(
            run: test.run,
            runCount: runCount,
            frequency: frequency,
            sweepFraction: fraction,
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
        let (verdict, problem) = await Self.check(recording.samples, sweep: test.sweep, floor: floor, thresholds: thresholds)
        guard !Task.isCancelled else { return nil }
        if let problem {
            return runFailed(problem, in: &test)
        }
        test.recordings.append(RunRecording(
            run: test.run,
            samples: recording.samples,
            sampleRate: test.sampleRate,
            leadIn: recording.leadIn,
            arrivalDelay: test.tracker.delay.map { Double(recording.leadIn + $0) / test.sampleRate },
            verdict: verdict,
            spliceCount: recording.spliceCount,
            phoneMoved: test.phoneMoved,
            attempt: test.attempt
        ))
        if test.recordings.count == runCount {
            return .finished(MeasurementResult(channel: channel, sweep: test.sweep, noiseFloor: floor, runs: test.recordings))
        }
        test.run += 1
        test.attempt = 1
        test.note = nil
        test.restarts = 0
        test.recorder = nil
        return nil
    }

    /// A bad run is repeated once; a second bad recording ends the test.
    private func runFailed(_ problem: RunProblem, in test: inout TestRun) -> State? {
        io.stopPlayback()
        guard test.attempt == 1 else { return .failed(.recordingUnusable(problem)) }
        test.attempt = 2
        test.note = .repeating(problem)
        test.restarts = 0
        test.recorder = nil
        return nil
    }

    /// Checks a finished recording, off the main actor (a run's recording is a quarter of a million samples and the
    /// second check deconvolves it): nil `problem` when the run can be kept.
    ///
    /// 1. `RecordingQuality.assess`: anything but `.valid` (clipped, too quiet, too noisy, silent, corrupt) is
    ///    `.unusable` with that verdict.
    /// 2. Whether the recording holds the whole sweep, from the deconvolved response
    ///    (`ImpulseResponse.capturesWholeSweep`): when it does not, the run is `.didNotArrive`. This, not the live
    ///    arrival estimate, is the authority: the estimate only decides when the recorder stops listening, and the
    ///    response's delay is exact. When the estimate was early and the recording stopped before the sweep's end
    ///    arrived, this is where it shows.
    @concurrent nonisolated static func check(
        _ samples: [Float],
        sweep: LogSweep,
        floor: NoiseFloorReport,
        thresholds: QualityThresholds
    ) async -> (verdict: RecordingVerdict, problem: RunProblem?) {
        let verdict = RecordingQuality.assess(recording: samples, noiseFloor: floor, thresholds: thresholds)
        guard case .valid = verdict else { return (verdict, .unusable(verdict)) }
        let response = Deconvolution.impulseResponse(recording: samples, sweep: sweep)
        return (verdict, response.capturesWholeSweep ? nil : .didNotArrive)
    }
}

private extension MeasurementSession.State {
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}
