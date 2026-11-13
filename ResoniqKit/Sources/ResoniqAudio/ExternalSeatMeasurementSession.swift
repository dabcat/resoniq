import Foundation
import Observation
import ResoniqDSP

/// The seat measurement when another device plays the sound: at each of the three spots (as
/// `SeatMeasurementSession`: the seat, 30 cm left, 30 cm right, with the same waits for the phone to move and be
/// still), the user plays the seat file (`TestSoundFile.Kind.seat(channels)`: left then right, or one sweep on both)
/// and the phone listens, finds the clock tone and the sweeps, checks each recording and moves on.
///
/// A spot whose recordings are not all usable asks for the file to be played again at that spot
/// (`needsAnotherPlay`); a usable recording of one channel is kept while the other is played again. A sweep's channel
/// is known from the file's timing (the tone, or the spacing of the two sweeps), never from its sound: one microphone
/// cannot tell the left speaker from the right. A sweep whose place cannot be told is not kept.
///
/// **The result** is a `SeatMeasurementResult` of the same shape as a normal one, so `SpotAnalyzer` and
/// `SeatDiagnosis` read it unchanged: each recording starts `leadIn` before its sweep and keeps
/// `TestSoundFile.recordedTail(for:)` after it (2.4 s with `.seat`, which holds the room window and the bass decay
/// estimate), corrected for the player's clock, with `source` `.anotherDevice`.
///
/// **Isolation: the main actor**, as `ExternalMeasurementSession`.
@MainActor
@Observable
public final class ExternalSeatMeasurementSession {
    /// Where a listening seat measurement is.
    public enum State: Sendable, Equatable {
        case idle
        /// Listening to the room before the first spot.
        case measuringNoiseFloor
        /// Waiting for the phone to move to `spot` (after the first) and be still there.
        case waitingForStillness(spot: SeatSpot)
        /// The phone is in place: "Press play now".
        case waitingForSound(spot: SeatSpot)
        /// The file is being heard at `spot`: its tone, a sweep on `channel` (nil until its place in the file is
        /// known), or the silence between.
        case hearing(spot: SeatSpot, channel: SpeakerChannel?)
        /// The sweep just heard is being checked.
        case checking(spot: SeatSpot, channel: SpeakerChannel?)
        /// The play ended without every channel usable at `spot`: the file must be played again there.
        case needsAnotherPlay(spot: SeatSpot, reason: ExternalPlayProblem?)
        /// Every channel at `spot` is in. Lasts `SeatMeasurementSession.capturedHold`.
        case spotCaptured(spot: SeatSpot)
        case finished(SeatMeasurementResult)
        case failed(ExternalMeasurementFailure)

        public var isFinal: Bool {
            switch self {
            case .finished, .failed: true
            default: false
            }
        }
    }

    /// The channels of the seat file, in order: `[.left, .right]` for a pair, `[.both]` for one speaker.
    public let channels: [SpeakerChannel]
    public let configuration: MeasurementConfiguration
    public let thresholds: QualityThresholds
    /// The file the user plays at each spot.
    public var file: TestSoundFile { TestSoundFile(kind: .seat(channels)) }
    public var spotCount: Int { SeatSpot.allCases.count }

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    public private(set) var progress: ExternalSeatMeasurementProgress? {
        didSet {
            guard let progress else { return }
            for continuation in progressContinuations.values { continuation.yield(progress) }
        }
    }

    /// The spots captured so far, as `SeatMeasurementSession.captured`.
    public private(set) var captured: SeatMeasurementResult?
    public var capturedSpots: [SeatSpotRecording] { captured?.spots ?? [] }
    public var isRunning: Bool { task != nil }

    @ObservationIgnored private let io: any AudioIO
    @ObservationIgnored private let permission: any MicrophonePermission
    @ObservationIgnored private let stillness: any StillnessMonitor
    @ObservationIgnored private var task: Task<State, Never>?
    @ObservationIgnored private var skipRequested = false
    @ObservationIgnored private var progressContinuations: [UUID: AsyncStream<ExternalSeatMeasurementProgress>.Continuation] = [:]
    @ObservationIgnored var onStateChange: ((State) -> Void)?

    /// - Parameters:
    ///   - channels: `[.left, .right]` for a pair, `[.both]` for one speaker.
    ///   - configuration: `.seat` unless a test needs otherwise.
    public init(
        io: any AudioIO,
        channels: [SpeakerChannel],
        permission: any MicrophonePermission,
        stillness: any StillnessMonitor,
        configuration: MeasurementConfiguration = .seat,
        thresholds: QualityThresholds = .standard
    ) {
        precondition(channels == [.left, .right] || channels == [.both], "a seat file plays left then right, or both once")
        self.io = io
        self.channels = channels
        self.permission = permission
        self.stillness = stillness
        self.configuration = configuration
        self.thresholds = thresholds
    }

    public func start() {
        guard task == nil, state == .idle else { return }
        task = Task { await self.perform() }
    }

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

    /// Stops listening; the state becomes `failed(.measurement(.cancelled))`. Safe in any state and more than once.
    public func cancel() {
        if let task {
            task.cancel()
        } else if state == .idle {
            state = .failed(.measurement(.cancelled))
        }
    }

    /// Ends now with the spots captured so far, as `SeatMeasurementSession.skipToResult()`.
    public func skipToResult() {
        if task != nil {
            skipRequested = true
        } else if state == .idle {
            state = .failed(.measurement(.cancelled))
        }
    }

    public func progressUpdates() -> AsyncStream<ExternalSeatMeasurementProgress> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ExternalSeatMeasurementProgress>.makeStream(bufferingPolicy: .unbounded)
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

        var seat = Listening(sampleRate: stream.sampleRate, kind: file.kind, configuration: configuration, thresholds: thresholds)
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
                    if seat.floor == nil { seat.floorListener.reset() } else { seat.listener.restartAfterGap(at: captured.position) }
                }
                for block in blocks {
                    if let final = await handle(block, in: &seat) {
                        outcome = final
                        break blocks
                    }
                    if Task.isCancelled { break blocks }
                    if skipRequested {
                        outcome = skipped(seat)
                        break blocks
                    }
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

    private enum Phase {
        case floor
        case waiting
        case listening
        case captured(remaining: Int)
    }

    /// One recording heard at the current spot and found usable.
    private struct Candidate {
        var play: Int
        var estimate: Int64
        var identity: SweepIdentity?
        var inspection: SweepInspection
        var phoneMoved: Bool
        var verdict: RecordingVerdict
    }

    private struct Listening {
        let sampleRate: Double
        let sweep: LogSweep
        let configuration: MeasurementConfiguration
        var reblocker: Reblocker
        var floorListener: FloorListener
        var floor: NoiseFloorReport?
        var detector: SweepNoiseDetector?
        var listener: ExternalListener
        var phase = Phase.floor
        var spotIndex = 0
        var spots: [SeatSpotRecording] = []
        var kept: [Candidate] = []
        var lastProblem: ExternalPlayProblem?
        var stillSamples = 0
        var waitedSamples = 0
        var moved = false
        var movementDetected = true
        var listeningSince: Int64 = 0
        /// As in `ExternalMeasurementSession`.
        var latestHearing: ExternalHearing?
        var deferred: [SweepCut] = []

        init(sampleRate: Double, kind: TestSoundFile.Kind, configuration: MeasurementConfiguration, thresholds: QualityThresholds) {
            self.sampleRate = sampleRate
            self.configuration = configuration
            sweep = configuration.sweep(sampleRate: sampleRate)
            let blockLength = configuration.samples(configuration.blockDuration, at: sampleRate)
            reblocker = Reblocker(length: blockLength)
            floorListener = FloorListener(sampleRate: sampleRate, sweep: sweep, blockLength: blockLength, configuration: configuration, thresholds: thresholds)
            listener = ExternalListener(sampleRate: sampleRate, sweep: sweep, expected: kind, configuration: configuration)
        }

        var spot: SeatSpot { SeatSpot.allCases[spotIndex] }
        func count(_ seconds: Double) -> Int { configuration.samples(seconds, at: sampleRate) }
        func seconds(_ samples: Int64) -> Double { Double(samples) / sampleRate }
    }

    private func skipped(_ seat: Listening) -> State {
        guard let floor = seat.floor else { return .failed(.measurement(.cancelled)) }
        return .finished(result(seat, floor: floor))
    }

    private func result(_ seat: Listening, floor: NoiseFloorReport) -> SeatMeasurementResult {
        SeatMeasurementResult(channels: channels, sweep: seat.sweep, noiseFloor: floor, spots: seat.spots, source: .anotherDevice)
    }

    private func waitForSpot(_ seat: inout Listening) {
        seat.phase = .waiting
        seat.stillSamples = 0
        seat.waitedSamples = 0
        seat.kept = []
        seat.lastProblem = nil
        seat.latestHearing = nil
        seat.deferred = []
        state = .waitingForStillness(spot: seat.spot)
        (stillness as? any SpotAwareStillnessMonitor)?.willWaitForStillness(at: seat.spot)
    }

    private func handle(_ block: CapturedBlock, in seat: inout Listening) async -> State? {
        let steady = stillness.isSteady
        let clipped = ClippingDetector.detect(block.samples, thresholds: thresholds).isClipped
        guard let floor = seat.floor else {
            report(block, seat: seat, steady: steady, clipped: clipped)
            if let (floor, detector) = seat.floorListener.listen(block) {
                seat.detector = detector
                seat.floor = floor
                seat.listeningSince = block.end
                captured = result(seat, floor: floor)
                waitForSpot(&seat)
            } else if seat.floorListener.hasTimedOut {
                return .failed(.measurement(.tooNoisy))
            }
            return nil
        }

        // The listener hears everything, so the audio it keeps is continuous; what it hears counts only while
        // listening at a spot.
        let loud = SoundLevel(of: block.samples).dBFS > floor.rmsDecibels + thresholds.pauseMarginDecibels
        let events = seat.listener.consume(block, steady: steady, loud: loud)
        switch seat.phase {
        case .floor:
            return nil

        case .captured(let remaining):
            if !steady { seat.moved = true }
            while seat.listener.takeCut() != nil {}
            report(block, seat: seat, steady: steady, clipped: clipped)
            let left = remaining - block.samples.count
            if left > 0 {
                seat.phase = .captured(remaining: left)
                return nil
            }
            if seat.spots.count == spotCount { return .finished(result(seat, floor: floor)) }
            seat.spotIndex += 1
            waitForSpot(&seat)
            return nil

        case .waiting:
            if !steady { seat.moved = true }
            while seat.listener.takeCut() != nil {}
            seat.waitedSamples += block.samples.count
            seat.stillSamples = steady ? seat.stillSamples + block.samples.count : 0
            report(block, seat: seat, steady: steady, clipped: clipped)
            if seat.stillSamples < seat.count(SeatMeasurementSession.stillnessHold),
               seat.waitedSamples >= seat.count(SeatMeasurementSession.maximumStillnessWait) {
                return .failed(.measurement(.phoneNeverStill))
            }
            let first = seat.spotIndex == 0
            guard seat.stillSamples >= seat.count(SeatMeasurementSession.stillnessHold),
                  first || seat.moved || seat.waitedSamples >= seat.count(SeatMeasurementSession.movementTimeout)
            else { return nil }
            seat.movementDetected = first || seat.moved
            seat.phase = .listening
            seat.listener.markListening(at: block.end)
            state = .waitingForSound(spot: seat.spot)
            return nil

        case .listening:
            for event in events {
                if let final = await listen(event, floor: floor, in: &seat) { return final }
                if case .captured = seat.phase { break }
            }
            report(block, seat: seat, steady: steady, clipped: clipped)
            if case .listening = seat.phase {
                if let failure = seat.listener.silenceFailure(at: block.end) { return .failed(failure) }
            }
            if seat.seconds(block.end - seat.listeningSince) >= ExternalListening.maximumListeningTime * Double(spotCount) {
                return .failed(.listeningTimeUp(lastProblem: seat.lastProblem))
            }
            return nil
        }
    }

    private func listen(_ event: ExternalListener.Event, floor: NoiseFloorReport, in seat: inout Listening) async -> State? {
        switch event {
        case .toneStarted:
            seat.latestHearing = nil
            state = .hearing(spot: seat.spot, channel: nil)
        case .toneRead(let ratio):
            if let ratio, !SweepFinder.isCorrectable(ratio) { return .failed(.playerClockOff(ratio: ratio)) }
        case .sweepStarted(let play, let identity):
            seat.latestHearing = nil
            state = .hearing(spot: seat.spot, channel: channel(of: identity))
            return await recheckDeferred(play: play, floor: floor, in: &seat)
        case .wrongFile(let play, let heard):
            seat.kept.removeAll { $0.play == play }
            seat.lastProblem = .wrongFile(heard: heard)
            seat.latestHearing = .notTheTestSound
            state = .needsAnotherPlay(spot: seat.spot, reason: seat.lastProblem)
        case .cutReady:
            while let cut = seat.listener.takeCut() {
                if let final = await check(cut, floor: floor, in: &seat) { return final }
                if case .captured = seat.phase { break }
            }
        case .playOver(let play):
            return playEnded(play, in: &seat)
        }
        return nil
    }

    private func channel(of identity: SweepIdentity?) -> SpeakerChannel? {
        guard let identity, identity.kind == file.kind, channels.indices.contains(identity.index) else { return nil }
        return channels[identity.index]
    }

    private func check(_ cut: SweepCut, floor: NoiseFloorReport, in seat: inout Listening) async -> State? {
        let spot = seat.spot
        state = .checking(spot: spot, channel: channel(of: cut.identity))
        let inspection = await SweepInspection.inspect(
            cut, sweep: seat.sweep, floor: floor, detector: seat.detector, thresholds: thresholds,
            ratio: seat.listener.ratio(forPlay: cut.play),
            leadIn: seat.listener.leadIn, tail: seat.listener.tail
        )
        guard !Task.isCancelled else { return nil }
        let wrong = seat.listener.plays.first { $0.id == cut.play }?.wrongFile
        if inspection.start == nil, wrong == nil, cut.identity == nil { seat.deferred.append(cut) }
        if inspection.start != nil, wrong == nil {
            if let problem = inspection.problem {
                seat.lastProblem = .run(problem)
            } else if case .valid = inspection.verdict {
                seat.kept.append(Candidate(
                    play: cut.play, estimate: cut.estimate, identity: cut.identity, inspection: inspection,
                    phoneMoved: cut.phoneMoved, verdict: inspection.verdict ?? .valid(level: LevelMeter.measure(inspection.samples), signalToNoise: 0)
                ))
            }
        }
        if let final = await captureIfComplete(&seat, floor: floor) { return final }
        if case .captured = seat.phase { return nil }
        if wrong != nil {
            state = .needsAnotherPlay(spot: spot, reason: seat.lastProblem)
        } else {
            state = seat.listener.currentPlay == nil ? .waitingForSound(spot: spot) : .hearing(spot: spot, channel: nil)
        }
        // Every sweep of the file has been heard: no need to wait for the play to time out.
        if let play = seat.listener.plays.first(where: { $0.id == cut.play }), play.sweeps.count >= channels.count,
           seat.listener.isQuiet {
            seat.listener.endPlay(cut.play)
            return playEnded(cut.play, in: &seat)
        }
        return nil
    }

    /// The usable recording of each channel at this spot, by the file's timing; nil while one is missing.
    private func recordingsByChannel(_ seat: inout Listening) -> [SpeakerChannel: Candidate]? {
        for index in seat.kept.indices where seat.kept[index].identity == nil {
            let candidate = seat.kept[index]
            seat.kept[index].identity = seat.listener.plays.first { $0.id == candidate.play }?
                .sweeps.first { $0.estimate == candidate.estimate }?.identity
        }
        var byChannel: [SpeakerChannel: Candidate] = [:]
        for candidate in seat.kept {
            guard let channel = channel(of: candidate.identity) else { continue }
            byChannel[channel] = candidate
        }
        return byChannel.count == channels.count ? byChannel : nil
    }

    private func captureIfComplete(_ seat: inout Listening, floor: NoiseFloorReport) async -> State? {
        guard let byChannel = recordingsByChannel(&seat) else { return nil }
        var recordings: [SpeakerChannel: RunRecording] = [:]
        for (index, channel) in channels.enumerated() {
            guard let candidate = byChannel[channel] else { return nil }
            guard let ratio = seat.listener.ratio(forPlay: candidate.play) else {
                seat.kept.removeAll { $0.play == candidate.play }
                seat.lastProblem = .clockUnknown
                return nil
            }
            if !SweepFinder.isCorrectable(ratio) { return .failed(.playerClockOff(ratio: ratio)) }
            var inspection = candidate.inspection
            if inspection.ratio != ratio {
                inspection = await SweepInspection.recorrected(inspection, ratio: ratio, sweep: seat.sweep)
                guard !Task.isCancelled else { return nil }
            }
            recordings[channel] = RunRecording(
                run: index + 1,
                samples: inspection.samples,
                sampleRate: seat.sampleRate,
                leadIn: inspection.leadIn,
                arrivalDelay: Double(inspection.leadIn) / seat.sampleRate,
                verdict: candidate.verdict,
                spliceCount: 0,
                phoneMoved: candidate.phoneMoved,
                attempt: 1,
                measuredDelay: inspection.measuredDelay,
                clockRatio: ratio
            )
        }
        seat.spots.append(SeatSpotRecording(
            spot: seat.spot,
            recordings: recordings,
            phoneMoved: recordings.values.contains { $0.phoneMoved },
            movementDetected: seat.movementDetected
        ))
        captured = result(seat, floor: floor)
        if let play = seat.listener.currentPlay { seat.listener.endPlay(play.id) }
        seat.kept = []
        seat.moved = false
        seat.phase = .captured(remaining: seat.count(SeatMeasurementSession.capturedHold))
        state = .spotCaptured(spot: seat.spot)
        return nil
    }

    /// Cuts deferred from play `play` that a later sweep's spacing has now placed, checked again, anchored.
    private func recheckDeferred(play: Int, floor: NoiseFloorReport, in seat: inout Listening) async -> State? {
        guard let record = seat.listener.plays.first(where: { $0.id == play }) else { return nil }
        let placed = seat.deferred.filter { cut in
            cut.play == play && record.sweeps.contains { $0.estimate == cut.estimate && $0.identity != nil }
        }
        seat.deferred.removeAll { cut in placed.contains { $0.estimate == cut.estimate } }
        for var cut in placed {
            cut.identity = record.sweeps.first { $0.estimate == cut.estimate }?.identity
            if let final = await check(cut, floor: floor, in: &seat) { return final }
            if case .captured = seat.phase { return nil }
        }
        return nil
    }

    private func playEnded(_ play: Int, in seat: inout Listening) -> State? {
        seat.deferred.removeAll { $0.play == play }
        guard case .listening = seat.phase else { return nil }
        _ = recordingsByChannel(&seat)
        let unknown = seat.kept.contains { $0.play == play && $0.identity == nil }
        seat.kept.removeAll { $0.play == play && $0.identity == nil }
        if unknown, seat.lastProblem == nil { seat.lastProblem = .missedSweeps }
        let reason = seat.lastProblem ?? .missedSweeps
        if seat.latestHearing != .notTheTestSound { seat.latestHearing = ExternalListener.hearing(after: reason) }
        state = .needsAnotherPlay(spot: seat.spot, reason: reason)
        seat.lastProblem = nil
        return nil
    }

    private func report(_ block: CapturedBlock, seat: Listening, steady: Bool, clipped: Bool) {
        let level = SoundLevel(of: block.samples)
        let mark = seat.floor.map {
            SoundLevel(dBFS: min($0.rmsDecibels + thresholds.resumeMarginDecibels, thresholds.resumeCeilingDecibels))
        }
        let listener = seat.listener
        var stillnessFraction: Double?
        var wait: SeatWaitPhase?
        if case .waiting = seat.phase {
            stillnessFraction = min(1, Double(seat.stillSamples) / Double(max(seat.count(SeatMeasurementSession.stillnessHold), 1)))
            wait = SeatWaitPhase(firstSpot: seat.spotIndex == 0, moved: seat.moved, steady: steady)
        }
        var waiting = false
        if case .listening = seat.phase { waiting = listener.isQuiet }
        let silence = seat.seconds(block.end - listener.lastHeard)
        var hearing: SpeakerChannel?
        if case .hearing(_, let channel) = state { hearing = channel }
        let ratio = listener.currentPlay?.ratio ?? listener.knownRatio
        progress = ExternalSeatMeasurementProgress(
            spot: seat.spot,
            spotsCaptured: seat.spots.count,
            spotCount: spotCount,
            channel: listener.isHearingSweep ? hearing : nil,
            frequency: listener.heardFrequency,
            sweepFraction: listener.sweepFraction,
            isHearingTone: listener.isHearingTone,
            clockOffsetPPM: ratio.map { ($0 - 1) * 1e6 },
            roomLevel: level,
            quietEnoughLevel: mark,
            isRoomQuiet: level.dBFS <= (mark?.dBFS ?? -.infinity),
            inputLevel: level,
            inputPeakDecibels: LevelMeter.measure(block.samples).peakDecibels,
            isClipping: clipped,
            isPhoneSteady: steady,
            stillness: stillnessFraction,
            wait: wait,
            silentFor: waiting ? silence : nil,
            isSilenceLong: waiting && silence >= ExternalListening.nothingHeardHint,
            hearing: seat.floor == nil ? .nothing : listener.hearing(latest: seat.latestHearing)
        )
    }
}

private extension ExternalSeatMeasurementSession.State {
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}
