import Foundation
import Observation
import ResoniqDSP

/// The seat measurement: measures the room's floor once, then at each of three spots (the seat, 30 cm left, 30 cm
/// right) waits for the phone to settle and plays the sweep on each channel in turn, with the run machinery of a
/// speaker test (pause on noise and splice, check the recording, repeat once). Ends with every spot's recordings or a
/// reason.
///
/// **Between spots** the phone must first move (so the same position is not captured twice) and then be still for
/// `stillnessHold`. When the stillness monitor reports no movement within `movementTimeout`, the spot is captured
/// once the phone is still, and marked (`SeatSpotRecording.movementDetected`). The first spot only needs the phone
/// still. A captured spot shows as `spotCaptured` for `capturedHold`, for the haptic and "1 of 3 in".
///
/// **Isolation: the main actor**, as `MeasurementSession`, for the same reasons: the screens observe `state` and
/// `progress`, the work per 100 ms block is well under a millisecond, capture runs on the IO's threads and the
/// recording check runs off the main actor (`RunPerformer.check`). Every wait is counted in captured samples, so a
/// measurement on `SimulatedAudioIO` runs as fast as the arithmetic.
@MainActor
@Observable
public final class SeatMeasurementSession {
    /// Where a seat measurement is.
    public enum State: Sendable, Equatable {
        case idle
        /// Listening to the room before the first spot.
        case measuringNoiseFloor
        /// Waiting for the phone to move to `spot` (after the first) and be still there.
        case waitingForStillness(spot: SeatSpot)
        /// The sweep plays on `channel` at `spot`, or its end is still arriving and dying away.
        case playing(spot: SeatSpot, channel: SpeakerChannel, note: RunNote?)
        /// Noise stopped the sweep; it picks up at `resumeFrequency` once the room is quiet.
        case paused(spot: SeatSpot, channel: SpeakerChannel, resumeFrequency: Double)
        /// The recording just made is being checked.
        case checking(spot: SeatSpot, channel: SpeakerChannel)
        /// Every channel at `spot` is in. Lasts `capturedHold`: the moment for the rigid haptic and "1 of 3 in".
        case spotCaptured(spot: SeatSpot)
        case finished(SeatMeasurementResult)
        case failed(MeasurementFailure)

        /// Whether the measurement has ended, one way or the other.
        public var isFinal: Bool {
            switch self {
            case .finished, .failed: true
            default: false
            }
        }
    }

    /// Seconds the phone must stay still before a spot is captured. *First guess*: 1 s, long enough that a hand
    /// settling at ear height has stopped, short enough not to feel slow.
    public static let stillnessHold: Double = 1
    /// Seconds to wait for the phone to be seen moving to the next spot before capturing it anyway (and marking
    /// it). *First guess*: 10 s, time to read "Now move the phone 30 cm to your left" and do it.
    public static let movementTimeout: Double = 10
    /// Seconds `spotCaptured` lasts before the next spot is waited for (or the measurement finishes).
    /// *First guess*: 0.5 s.
    public static let capturedHold: Double = 0.5

    /// The channels played at each spot, in order: `[.left, .right]` for a pair, `[.both]` for one speaker.
    public let channels: [SpeakerChannel]
    public let configuration: MeasurementConfiguration
    public let thresholds: QualityThresholds

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// Live readings for the screen; nil until the first block arrives.
    public private(set) var progress: SeatMeasurementProgress? {
        didSet {
            guard let progress else { return }
            for continuation in progressContinuations.values { continuation.yield(progress) }
        }
    }

    public var spotCount: Int { SeatSpot.allCases.count }

    /// Whether the measurement's task is still running. False once `run()` has returned.
    public var isRunning: Bool { task != nil }

    @ObservationIgnored private let io: any AudioIO
    @ObservationIgnored private let permission: any MicrophonePermission
    @ObservationIgnored private let stillness: any StillnessMonitor
    @ObservationIgnored private var task: Task<State, Never>?
    @ObservationIgnored private var skipRequested = false
    @ObservationIgnored private var progressContinuations: [UUID: AsyncStream<SeatMeasurementProgress>.Continuation] = [:]
    /// Called on every state change, synchronously; for tests.
    @ObservationIgnored var onStateChange: ((State) -> Void)?

    /// - Parameters:
    ///   - channels: `[.left, .right]` for a pair, `[.both]` for a single speaker; played in this order at each spot.
    ///   - stillness: Whether the phone is still. A `SpotAwareStillnessMonitor` is told each time a spot is waited
    ///     for.
    ///   - configuration: `.seat` unless a test needs otherwise; its `runCount` is ignored.
    public init(
        io: any AudioIO,
        channels: [SpeakerChannel],
        permission: any MicrophonePermission,
        stillness: any StillnessMonitor,
        configuration: MeasurementConfiguration = .seat,
        thresholds: QualityThresholds = .standard
    ) {
        precondition(!channels.isEmpty, "a seat measurement plays at least one channel")
        self.io = io
        self.channels = channels
        self.permission = permission
        self.stillness = stillness
        self.configuration = configuration
        self.thresholds = thresholds
    }

    /// Starts the measurement in its own task. Does nothing if it has already started.
    public func start() {
        guard task == nil, state == .idle else { return }
        task = Task { await self.perform() }
    }

    /// Starts the measurement if needed and waits for it to end; returns the final state. Cancelling the calling task
    /// cancels the measurement.
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

    /// Stops the measurement: playback stops at once, the audio is released, and the state becomes
    /// `failed(.cancelled)`. Safe in any state.
    public func cancel() {
        if let task {
            task.cancel()
        } else if state == .idle {
            state = .failed(.cancelled)
        }
    }

    /// Ends the measurement now with the spots captured so far ("Skip to result"): playback stops, a spot in
    /// progress is dropped, and the state becomes `finished` (with fewer than three spots the analysis is
    /// inconclusive). Before the noise floor is known there is nothing to analyse, and it is `failed(.cancelled)`.
    public func skipToResult() {
        if task != nil {
            skipRequested = true
        } else if state == .idle {
            state = .failed(.cancelled)
        }
    }

    /// Every progress update from now until the measurement ends.
    public func progressUpdates() -> AsyncStream<SeatMeasurementProgress> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SeatMeasurementProgress>.makeStream(bufferingPolicy: .unbounded)
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

    // MARK: - The measurement

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

        var seat = SeatRun(sampleRate: stream.sampleRate, configuration: configuration, thresholds: thresholds)
        var outcome: State?
        do {
            blocks: for try await captured in stream.blocks {
                if Task.isCancelled { break }
                if skipRequested {
                    outcome = skipped(seat)
                    break
                }
                let (blocks, gap) = seat.reblocker.append(captured)
                if gap {
                    if seat.floor == nil { seat.listener.reset() } else { seat.performer?.restartAfterGap(io: io) }
                }
                for block in blocks {
                    if let final = try await handle(block, in: &seat) {
                        outcome = final
                        break blocks
                    }
                    if Task.isCancelled { break blocks }
                    if skipRequested {
                        outcome = skipped(seat)
                        break blocks
                    }
                }
            }
        } catch {
            outcome = .failed(MeasurementFailure(streamError: error))
        }
        io.stopPlayback()
        await io.stop()
        if Task.isCancelled, outcome?.isFinished != true { return .failed(.cancelled) }
        // The stream ended on its own: the audio went away under the measurement.
        return outcome ?? .failed(.interrupted)
    }

    private enum Phase {
        case floor
        case waiting
        case capturing
        case captured(remaining: Int)
    }

    /// Everything one measurement keeps between blocks.
    private struct SeatRun {
        let sampleRate: Double
        let sweep: LogSweep
        let sweepSamples: [Float]
        let configuration: MeasurementConfiguration
        var reblocker: Reblocker
        var listener: FloorListener
        var floor: NoiseFloorReport?
        var detector: SweepNoiseDetector?
        var tracker = ArrivalTracker()
        var phase = Phase.floor
        var spotIndex = 0
        /// The channel being captured, as an index into `channels`.
        var channelIndex = 0
        var performer: RunPerformer?
        var recordings: [SpeakerChannel: RunRecording] = [:]
        var spots: [SeatSpotRecording] = []
        /// Samples the phone has been still for, and waited for, at the spot being waited for.
        var stillSamples = 0
        var waitedSamples = 0
        /// Whether the phone was seen moving since the last spot was captured.
        var moved = false
        var movementDetected = true

        init(sampleRate: Double, configuration: MeasurementConfiguration, thresholds: QualityThresholds) {
            self.sampleRate = sampleRate
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
        }

        var spot: SeatSpot { SeatSpot.allCases[spotIndex] }

        func count(_ seconds: Double) -> Int { configuration.samples(seconds, at: sampleRate) }
    }

    /// The result with the spots captured so far, or `cancelled` before there is a floor to analyse against.
    private func skipped(_ seat: SeatRun) -> State {
        io.stopPlayback()
        guard let floor = seat.floor else { return .failed(.cancelled) }
        return .finished(SeatMeasurementResult(channels: channels, sweep: seat.sweep, noiseFloor: floor, spots: seat.spots))
    }

    private func waitForSpot(_ seat: inout SeatRun) {
        seat.phase = .waiting
        seat.stillSamples = 0
        seat.waitedSamples = 0
        state = .waitingForStillness(spot: seat.spot)
        (stillness as? any SpotAwareStillnessMonitor)?.willWaitForStillness(at: seat.spot)
    }

    /// Takes one block; returns the final state when the measurement has ended.
    private func handle(_ block: CapturedBlock, in seat: inout SeatRun) async throws -> State? {
        guard let floor = seat.floor, let detector = seat.detector else {
            report(block, assessment: nil, quiet: false, steady: stillness.isSteady, clipped: false, seat: seat)
            if let (floor, detector) = seat.listener.listen(block) {
                seat.floor = floor
                seat.detector = detector
                waitForSpot(&seat)
            }
            return nil
        }

        let assessment = detector.assess(block.samples)
        let quiet = NoiseGate.isQuietEnough(block: block.samples, baseline: floor.rmsDecibels, thresholds: thresholds)
        // Read once a block: a simulated monitor counts its reads.
        let steady = stillness.isSteady
        let clipped = ClippingDetector.detect(block.samples, thresholds: thresholds).isClipped

        switch seat.phase {
        case .floor:
            return nil

        case .captured(let remaining):
            if !steady { seat.moved = true }
            let left = remaining - block.samples.count
            report(block, assessment: assessment, quiet: quiet, steady: steady, clipped: clipped, seat: seat)
            if left > 0 {
                seat.phase = .captured(remaining: left)
                return nil
            }
            if seat.spots.count == spotCount {
                return .finished(SeatMeasurementResult(channels: channels, sweep: seat.sweep, noiseFloor: floor, spots: seat.spots))
            }
            seat.spotIndex += 1
            waitForSpot(&seat)
            return nil

        case .waiting:
            if !steady { seat.moved = true }
            seat.waitedSamples += block.samples.count
            seat.stillSamples = steady ? seat.stillSamples + block.samples.count : 0
            report(block, assessment: assessment, quiet: quiet, steady: steady, clipped: clipped, seat: seat)
            let first = seat.spotIndex == 0
            guard seat.stillSamples >= seat.count(Self.stillnessHold),
                  first || seat.moved || seat.waitedSamples >= seat.count(Self.movementTimeout)
            else { return nil }
            // The sweep starts with the next block.
            seat.movementDetected = first || seat.moved
            seat.phase = .capturing
            seat.channelIndex = 0
            seat.recordings = [:]
            seat.performer = makePerformer(seat)
            return nil

        case .capturing:
            return try await capture(block, assessment: assessment, quiet: quiet, steady: steady, clipped: clipped, in: &seat)
        }
    }

    private func makePerformer(_ seat: SeatRun) -> RunPerformer {
        RunPerformer(channel: channels[seat.channelIndex], sweep: seat.sweep, sweepSamples: seat.sweepSamples, configuration: configuration)
    }

    private func capture(
        _ block: CapturedBlock,
        assessment: SweepNoiseDetector.Assessment,
        quiet: Bool,
        steady: Bool,
        clipped: Bool,
        in seat: inout SeatRun
    ) async throws -> State? {
        guard var performer = seat.performer else { return nil }
        let channel = performer.channel
        let spot = seat.spot

        guard performer.isRecording else {
            let step = try performer.begin(with: block, clipped: clipped, io: io)
            seat.performer = performer
            switch step {
            case .playing(let note):
                state = .playing(spot: spot, channel: channel, note: note)
                report(block, assessment: assessment, quiet: quiet, steady: steady, clipped: clipped, seat: seat)
                return nil
            case .failed(let problem):
                return .failed(.recordingUnusable(problem))
            default:
                return nil
            }
        }

        let step = try performer.consume(
            block,
            assessment: assessment,
            quiet: quiet,
            steady: steady,
            clipped: clipped,
            tracker: &seat.tracker,
            sampleRate: seat.sampleRate,
            io: io
        )
        seat.performer = performer
        report(block, assessment: assessment, quiet: quiet, steady: steady, clipped: clipped, seat: seat)

        switch step {
        case .none, .repeating:
            return nil
        case .paused(let frequency):
            state = .paused(spot: spot, channel: channel, resumeFrequency: frequency)
            return nil
        case .playing(let note):
            state = .playing(spot: spot, channel: channel, note: note)
            return nil
        case .failed(let problem):
            return .failed(.recordingUnusable(problem))
        case .tooNoisy:
            return .failed(.tooNoisy)
        case .recorded(let recording):
            return await check(recording, in: &seat)
        }
    }

    private func check(_ recording: RunRecorder.Recording, in seat: inout SeatRun) async -> State? {
        guard let floor = seat.floor, var performer = seat.performer else { return nil }
        let channel = performer.channel
        state = .checking(spot: seat.spot, channel: channel)
        let (verdict, problem) = await RunPerformer.check(recording.samples, sweep: seat.sweep, floor: floor, thresholds: thresholds)
        guard !Task.isCancelled else { return nil }
        let conclusion = performer.conclude(
            recording,
            verdict: verdict,
            problem: problem,
            run: seat.channelIndex + 1,
            delay: seat.tracker.delay,
            sampleRate: seat.sampleRate,
            io: io
        )
        seat.performer = performer
        switch conclusion {
        case .repeating:
            return nil
        case .failed(let problem):
            return .failed(.recordingUnusable(problem))
        case .kept(let kept):
            seat.recordings[channel] = kept
        }
        if seat.channelIndex + 1 < channels.count {
            seat.channelIndex += 1
            seat.performer = makePerformer(seat)
            return nil
        }
        seat.spots.append(SeatSpotRecording(
            spot: seat.spot,
            recordings: seat.recordings,
            phoneMoved: seat.recordings.values.contains { $0.phoneMoved },
            movementDetected: seat.movementDetected
        ))
        seat.performer = nil
        seat.moved = false
        seat.phase = .captured(remaining: seat.count(Self.capturedHold))
        state = .spotCaptured(spot: seat.spot)
        return nil
    }

    private func report(
        _ block: CapturedBlock,
        assessment: SweepNoiseDetector.Assessment?,
        quiet: Bool,
        steady: Bool,
        clipped: Bool,
        seat: SeatRun
    ) {
        let blockLevel = SoundLevel(of: block.samples)
        let peak = LevelMeter.measure(block.samples).peakDecibels
        guard let assessment else {
            progress = SeatMeasurementProgress(
                spot: seat.spot,
                spotsCaptured: seat.spots.count,
                spotCount: spotCount,
                roomLevel: blockLevel,
                quietEnoughLevel: nil,
                isRoomQuiet: false,
                inputLevel: blockLevel,
                inputPeakDecibels: peak,
                isClipping: false,
                isPhoneSteady: steady
            )
            return
        }
        let performer: RunPerformer? = if case .capturing = seat.phase { seat.performer } else { nil }
        let paused = performer?.isPaused ?? false
        let delay = seat.tracker.delay
        let arriving = performer?.arriving(at: block, delay: delay, sampleRate: seat.sampleRate)
        let mark = seat.floor.map {
            SoundLevel(dBFS: min($0.rmsDecibels + thresholds.resumeMarginDecibels, thresholds.resumeCeilingDecibels))
        }
        // While nothing plays, the room is the whole block.
        let room = paused || performer?.isRecording != true ? assessment.blockLevel : assessment.roomLevel
        var stillnessFraction: Double?
        if case .waiting = seat.phase {
            stillnessFraction = min(1, Double(seat.stillSamples) / Double(max(seat.count(Self.stillnessHold), 1)))
        }
        progress = SeatMeasurementProgress(
            spot: seat.spot,
            spotsCaptured: seat.spots.count,
            spotCount: spotCount,
            channel: performer?.channel,
            frequency: arriving?.frequency,
            sweepFraction: arriving?.fraction,
            roomLevel: room,
            quietEnoughLevel: mark,
            isRoomQuiet: paused || performer?.isRecording != true ? quiet : room.dBFS <= (mark?.dBFS ?? .infinity),
            inputLevel: blockLevel,
            inputPeakDecibels: peak,
            isClipping: clipped,
            isPhoneSteady: steady,
            stillness: stillnessFraction,
            routeDelay: delay.map { Double($0) / seat.sampleRate }
        )
    }
}

private extension SeatMeasurementSession.State {
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}
