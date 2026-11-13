import Foundation
import ResoniqDSP

// The run machinery every measurement shares: listening for the room's floor, then playing one sweep on one channel
// block by block until a checked recording comes out. `MeasurementSession` plays three runs on one channel with it;
// `SeatMeasurementSession` plays one run per channel at each of three spots. Both own the capture stream, the state
// the screen sees and the progress; these types decide nothing about states or screens.

/// Listens to the room before the first run: drops `settleDuration` while the input settles, then keeps listening
/// until `noiseFloorDuration` of steady, quiet enough sound gives a floor, half a window at a time.
struct FloorListener {
    let sampleRate: Double
    let sweep: LogSweep
    let blockLength: Int
    let configuration: MeasurementConfiguration
    let thresholds: QualityThresholds
    private var settleRemaining: Int
    private var samples: [Float] = []

    init(sampleRate: Double, sweep: LogSweep, blockLength: Int, configuration: MeasurementConfiguration, thresholds: QualityThresholds) {
        self.sampleRate = sampleRate
        self.sweep = sweep
        self.blockLength = blockLength
        self.configuration = configuration
        self.thresholds = thresholds
        settleRemaining = configuration.samples(configuration.settleDuration, at: sampleRate)
    }

    /// Samples were lost: what was heard so far cannot be joined to what follows.
    mutating func reset() {
        samples = []
    }

    /// Takes one block; returns the floor and the detector built on it once the floor is known.
    mutating func listen(_ block: CapturedBlock) -> (floor: NoiseFloorReport, detector: SweepNoiseDetector)? {
        if settleRemaining > 0 {
            settleRemaining -= block.samples.count
            return nil
        }
        samples += block.samples
        let needed = configuration.samples(configuration.noiseFloorDuration, at: sampleRate)
        guard samples.count >= needed else { return nil }
        let report = NoiseFloor.measure(samples, sampleRate: sampleRate, thresholds: thresholds)
        if report.isSteady, report.rmsDecibels <= thresholds.resumeCeilingDecibels {
            let detector = SweepNoiseDetector(noiseFloor: samples, sweep: sweep, blockLength: blockLength, thresholds: thresholds)
            return (report, detector)
        }
        // Not a floor yet: someone talked, or the room is too loud. Keep listening, half a window at a time.
        samples.removeFirst(needed / 2)
        return nil
    }
}

/// One run of the sweep on one channel, from its first block to a checked recording: starts the sweep, follows it
/// through pauses, resumes and splices (`RunRecorder`), restarts it when it must, and repeats it once when its
/// recording is bad. A run that fails a second time, or restarts more than `maximumRestarts` times on its second
/// attempt, ends with the problem. Make a new one for every run.
struct RunPerformer {
    /// What a block did to the run.
    enum Step: Equatable {
        /// Nothing the screen needs to hear about.
        case none
        /// The sweep plays: a new run, a repeated or restarted one, or one resumed after a pause.
        case playing(note: RunNote?)
        /// Noise stopped the sweep; it resumes from `resumeFrequency` once the room is quiet.
        case paused(resumeFrequency: Double)
        /// The run's first recording was bad; it starts again with the next block.
        case repeating
        /// The run's second recording was bad too: the measurement ends.
        case failed(RunProblem)
        /// The recording is complete and must be checked (`check`, then `conclude`).
        case recorded(RunRecorder.Recording)
    }

    /// What the check of a recording decided.
    enum Conclusion: Equatable {
        case kept(RunRecording)
        case repeating
        case failed(RunProblem)
    }

    let channel: SpeakerChannel
    let sweep: LogSweep
    let sweepSamples: [Float]
    let configuration: MeasurementConfiguration
    private(set) var recorder: RunRecorder?
    private(set) var attempt = 1
    private(set) var note: RunNote?
    private(set) var phoneMoved = false
    /// Whether a block of this run clipped; it will be judged clipped when it ends.
    private var clipped = false
    /// Times this run started again from the beginning.
    private var restarts = 0

    init(channel: SpeakerChannel, sweep: LogSweep, sweepSamples: [Float], configuration: MeasurementConfiguration) {
        self.channel = channel
        self.sweep = sweep
        self.sweepSamples = sweepSamples
        self.configuration = configuration
    }

    /// Whether the sweep has been started and its recording is under way.
    var isRecording: Bool { recorder != nil }
    /// Whether the run is waiting for quiet.
    var isPaused: Bool { recorder?.isPaused ?? false }
    /// The current take's sweep origin on the capture timeline.
    var sweepOrigin: Int64? { recorder?.sweepOrigin }

    /// Samples were lost while recording: the positions a splice depends on are gone, so the run starts over.
    mutating func restartAfterGap(io: any AudioIO) {
        guard recorder != nil else { return }
        io.stopPlayback()
        recorder = nil
        note = .restarted(.timelineUnreliable)
        restarts += 1
    }

    /// Starts the sweep with `block`, the block just captured (call when `isRecording` is false). Returns
    /// `.playing`, `.repeating` or `.failed`.
    mutating func begin(with block: CapturedBlock, clipped: Bool, io: any AudioIO) throws -> Step {
        if restarts > configuration.maximumRestarts {
            return fail(.interruptedRepeatedly, io: io)
        }
        let channel = channel
        var recorder = RunRecorder(sweep: sweep, sweepSamples: sweepSamples, configuration: configuration)
        try recorder.begin(with: block) { try io.schedule($0, on: channel, mode: .once) }
        self.recorder = recorder
        phoneMoved = false
        self.clipped = clipped
        return .playing(note: note)
    }

    /// Takes the next block of a run under way.
    ///
    /// - Parameters:
    ///   - assessment: The noise detector's view of the block.
    ///   - quiet: `NoiseGate.isQuietEnough` on the block against the floor.
    ///   - steady: Whether the phone is held still.
    ///   - clipped: Whether the block clipped.
    ///   - tracker: The route-delay estimate, kept for the whole measurement since the route does not change.
    mutating func consume(
        _ block: CapturedBlock,
        assessment: SweepNoiseDetector.Assessment,
        quiet: Bool,
        steady: Bool,
        clipped: Bool,
        tracker: inout ArrivalTracker,
        sampleRate: Double,
        io: any AudioIO
    ) throws -> Step {
        guard var recorder else { return .none }
        if clipped { self.clipped = true }
        // A clipped sweep is full of harmonics the detector does not take out, so it reads as noise. Once a run has
        // clipped it is not paused: it will be judged clipped when it ends.
        let noisy = assessment.isTooNoisy && !self.clipped

        if !recorder.isPaused {
            if let origin = recorder.sweepOrigin {
                tracker.observe(
                    assessment,
                    noisy: noisy,
                    blockCentre: block.position + Int64(block.samples.count / 2),
                    sweepOrigin: origin,
                    sweep: sweep,
                    maximumDelay: configuration.samples(configuration.maximumRouteDelay, at: sampleRate)
                )
            }
            if !steady { phoneMoved = true }
        }

        let channel = channel
        let event = try recorder.consume(
            block,
            noisy: noisy,
            quietEnough: quiet,
            delay: tracker.delay,
            schedule: { try io.schedule($0, on: channel, mode: .once) },
            stopPlayback: { io.stopPlayback() }
        )
        self.recorder = recorder

        switch event {
        case .none:
            return .none
        case .paused(let frequency):
            return .paused(resumeFrequency: frequency)
        case .resumed(let restarted):
            if let restarted {
                note = .restarted(restarted)
                restarts += 1
                if restarts > configuration.maximumRestarts {
                    return fail(.interruptedRepeatedly, io: io)
                }
            }
            return .playing(note: note)
        case .spliceFailed:
            io.stopPlayback()
            self.recorder = nil
            note = .restarted(.timelineUnreliable)
            restarts += 1
            return .none
        case .didNotArrive:
            return fail(.didNotArrive, io: io)
        case .finished(let recording):
            return .recorded(recording)
        }
    }

    /// What to do with a checked recording: keep it as run `run`, or repeat or fail the run for `problem`.
    mutating func conclude(
        _ recording: RunRecorder.Recording,
        verdict: RecordingVerdict,
        problem: RunProblem?,
        run: Int,
        delay: Int?,
        sampleRate: Double,
        io: any AudioIO
    ) -> Conclusion {
        if let problem {
            return fail(problem, io: io) == .repeating ? .repeating : .failed(problem)
        }
        return .kept(RunRecording(
            run: run,
            samples: recording.samples,
            sampleRate: sampleRate,
            leadIn: recording.leadIn,
            arrivalDelay: delay.map { Double(recording.leadIn + $0) / sampleRate },
            verdict: verdict,
            spliceCount: recording.spliceCount,
            phoneMoved: phoneMoved,
            attempt: attempt
        ))
    }

    /// A bad run is repeated once; a second bad recording ends the measurement.
    private mutating func fail(_ problem: RunProblem, io: any AudioIO) -> Step {
        io.stopPlayback()
        guard attempt == 1 else { return .failed(problem) }
        attempt = 2
        note = .repeating(problem)
        restarts = 0
        recorder = nil
        return .repeating
    }

    /// The sweep frequency arriving at the microphone at `block`'s centre and how far through the sweep it is, when
    /// the delay is known and the run is not paused.
    func arriving(at block: CapturedBlock, delay: Int?, sampleRate: Double) -> (frequency: Double, fraction: Double)? {
        guard !isPaused, let delay, let origin = sweepOrigin else { return nil }
        let heard = Double(block.position + Int64(block.samples.count / 2) - origin - Int64(delay))
        guard heard >= 0, heard <= Double(sweepSamples.count) else { return nil }
        return (sweep.frequency(at: heard / sampleRate), heard / Double(sweepSamples.count))
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

extension MeasurementFailure {
    /// The failure an error from the capture stream means.
    init(streamError error: any Error) {
        switch error as? AudioIOError {
        case .interrupted: self = .interrupted
        case .routeChanged: self = .routeChanged
        case .unavailable(let reason): self = .audioUnavailable(reason)
        case .notRunning: self = .audioUnavailable("the audio stopped")
        case nil: self = .audioUnavailable(String(describing: error))
        }
    }
}

/// Opening a measurement: microphone access, then the stream at a rate the sweep can play at.
enum MeasurementOpening {
    /// Whether the microphone may be used, asking when the user has not decided.
    static func hasAccess(_ permission: any MicrophonePermission) async -> Bool {
        var access = permission.status
        if access == .undetermined {
            access = await permission.request() ? .granted : .denied
        }
        return access == .granted
    }

    /// Starts `io`; fails, with the stream stopped, when it cannot start or runs under
    /// `MeasurementConfiguration.minimumSampleRate`.
    static func open(_ io: any AudioIO) async -> Result<CaptureStream, MeasurementFailure> {
        let stream: CaptureStream
        do {
            stream = try await io.start()
        } catch {
            return .failure(.audioUnavailable(String(describing: error)))
        }
        guard stream.sampleRate >= MeasurementConfiguration.minimumSampleRate else {
            await io.stop()
            return .failure(.audioUnavailable(
                "the input runs at \(Int(stream.sampleRate)) Hz; the measurement sweep needs \(Int(MeasurementConfiguration.minimumSampleRate)) Hz"
            ))
        }
        return .success(stream)
    }
}
