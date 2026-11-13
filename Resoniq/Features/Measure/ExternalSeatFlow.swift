import Foundation
import Observation
import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqDSP
import ResoniqStore

// MARK: - What the screen shows

extension SeatRunDisplay {
    /// Three spots for a measurement whose sound another device plays: the same pills, top view and building average as
    /// the normal one (`init(captured:activeSpot:...)`), with the external session's sentences (`ExternalSessionText`) as
    /// the headline, the line under it and the notice, and the Room and Level readings from what it hears.
    init(
        state: ExternalSeatMeasurementSession.State,
        progress: ExternalSeatMeasurementProgress?,
        channels: [SpeakerChannel],
        file: TestSoundFile.Kind,
        building: SeatBuilding?
    ) {
        var captured = progress?.spotsCaptured ?? 0
        var activeSpot = progress?.spot
        switch state {
        case .waitingForStillness(let spot), .waitingForSound(let spot), .needsAnotherPlay(let spot, _):
            activeSpot = spot
        case .hearing(let spot, _), .checking(let spot, _):
            activeSpot = spot
        case .spotCaptured(let spot):
            activeSpot = spot
            captured = max(captured, spot.index + 1)
        case .finished:
            captured = SeatSpot.allCases.count
        case .idle, .measuringNoiseFloor, .failed:
            break
        }

        let footer: String
        switch state {
        case .idle, .measuringNoiseFloor, .waitingForStillness: footer = TestSoundText.seatStillLine
        case .waitingForSound: footer = ExternalSessionText.seatWaitingLine(isSilenceLong: false, file: file)
        case .hearing: footer = progress?.isHearingTone == true ? ExternalSessionText.toneLine : ExternalSessionText.hearingLine
        case .checking, .needsAnotherPlay, .finished, .failed: footer = ExternalSessionText.hearingLine
        case .spotCaptured: footer = TestSoundText.nextSpotLine
        }

        self.init(
            captured: captured, activeSpot: activeSpot, channels: channels, building: building,
            instruction: ExternalSessionText.seatHeadline(for: state, wait: progress?.wait, channels: channels),
            footerLine: footer,
            readings: progress.map {
                Readings(
                    roomLevel: $0.roomLevel, isRoomQuiet: $0.isRoomQuiet, quietEnoughLevel: $0.quietEnoughLevel,
                    isClipping: $0.isClipping, frequency: $0.frequency, peakDecibels: $0.inputPeakDecibels
                )
            } ?? .notMeasured
        )

        switch state {
        case .needsAnotherPlay(_, let reason):
            externalNotice = ExternalNotice(
                title: TestSoundText.againNoticeTitle, text: ExternalSessionText.seatAnotherPlayText(reason, file: file)
            )
        default:
            externalNotice = progress.flatMap {
                ExternalRunDisplay.hearingNotice($0.hearing, isSilenceLong: $0.isSilenceLong, file: file)
            }
        }
    }
}

// MARK: - The flow

/// One seat measurement whose sound another device plays: the file, then the three spots, then a finished report.
///
/// It owns the `ExternalSeatMeasurementSession`, follows its state and progress, and when the last spot is in analyses
/// the spots with the same code as `SeatFlow` (`SeatFlow.analyse`, with the source `.anotherDevice` the result carries,
/// the room's size when it is known), yielding the same `SeatReport`, so the coordinator keeps it exactly like a
/// normal measurement. It keeps nothing.
///
/// There is no Paused step: the app cannot pause someone else's player, so a spot spoiled by noise is not paused for
/// (the session asks for the file again at that spot, which Three spots says in place).
@MainActor
@Observable
final class ExternalSeatFlow {
    enum Step: Equatable {
        /// Getting the test sound file (`TestSoundScreen`).
        case files
        /// The room's floor, a spot being waited for, played, checked or captured, or the file to play again.
        case running
        /// The last spot is in; the spots are being analysed.
        case analysing
        case finished(SeatReport)
        case failed(ExternalMeasurementFailure)

        /// Which screen shows, for transitions: two steps with the same screen are not a change of screen.
        enum Screen: Hashable {
            case files, running, analysing, finished, denied, failed
        }

        var screen: Screen {
            switch self {
            case .files: .files
            case .running: .running
            case .analysing: .analysing
            case .finished: .finished
            case .failed(.measurement(.permissionDenied)): .denied
            case .failed: .failed
            }
        }
    }

    private enum Phase {
        case files
        case running(ExternalSeatMeasurementSession)
        case finished(SeatReport)
    }

    let kind: SoundSystemKind
    /// The channels of the seat file: a pair, left then right; one speaker or a soundbar, both together.
    let channels: [SpeakerChannel]

    @ObservationIgnored private let audio: AudioEnvironment
    @ObservationIgnored private let roomHint: RoomHint?
    @ObservationIgnored private let configuration: MeasurementConfiguration
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var spotsTask: Task<Void, Never>?
    @ObservationIgnored private var simulatedPlay: (@MainActor (TestSoundFile) -> Void)?
    private let spots = SpotBuilder()
    private var phase = Phase.files

    init(
        kind: SoundSystemKind,
        roomHint: RoomHint? = nil,
        audio: AudioEnvironment = .current,
        configuration: MeasurementConfiguration = .seat
    ) {
        self.kind = kind
        self.channels = SeatFlow.channels(for: kind)
        self.roomHint = roomHint
        self.audio = audio
        self.configuration = configuration
    }

    // MARK: What the screens read

    var step: Step {
        switch phase {
        case .files: .files
        case .finished(let report): .finished(report)
        case .running(let session): Self.step(for: session.state)
        }
    }

    /// The file played at each spot.
    var file: TestSoundFile { TestSoundFile(kind: .seat(channels)) }

    /// What the files screen lists.
    var filesContext: TestSoundContext { .seat(channels: channels) }

    /// Three spots' content.
    var display: SeatRunDisplay {
        if case .running(let session) = phase {
            return SeatRunDisplay(
                state: session.state, progress: session.progress, channels: channels, file: file.kind, building: spots.building
            )
        }
        return SeatRunDisplay(state: .idle, progress: nil, channels: channels, file: file.kind, building: spots.building)
    }

    /// The session's state while it runs; nil otherwise. What the debug "simulated player" waits on.
    var sessionState: ExternalSeatMeasurementSession.State? {
        if case .running(let session) = phase { return session.state }
        return nil
    }

    var canSimulatePlay: Bool { simulatedPlay != nil }

    /// The step a session state is shown as. Pure, so it can be reasoned about (and previewed) without audio.
    static func step(for state: ExternalSeatMeasurementSession.State) -> Step {
        switch state {
        case .idle, .measuringNoiseFloor, .waitingForStillness, .waitingForSound, .hearing, .checking, .needsAnotherPlay,
             .spotCaptured: .running
        case .finished: .analysing
        case .failed(.measurement(.cancelled)): .files
        case .failed(let failure): .failed(failure)
        }
    }

    // MARK: Actions

    /// "I have the file": listens to the room, then to each of the three spots. Asks for the microphone first if it has
    /// not been asked.
    func start() {
        stopWork()
        let external = audio.makeExternalSeat()
        simulatedPlay = external.simulatedPlay
        let session = ExternalSeatMeasurementSession(
            io: external.io, channels: channels, permission: audio.permission, stillness: external.stillness,
            configuration: configuration
        )
        let updates = session.progressUpdates()
        phase = .running(session)
        session.start()
        // A spot is captured between two progress updates; each update checks for new ones.
        spotsTask = Task { [weak self] in
            for await _ in updates { self?.spots.analyseNew(in: session.captured) }
        }
        runTask = Task { [weak self] in
            await session.run()
            await self?.finish(session)
        }
    }

    /// Another measurement, after a failure: the person already has the file.
    func tryAgain() { start() }

    /// Stops listening and goes back to the file.
    func stop() {
        stopWork()
        phase = .files
    }

    /// Stops listening without changing the screen: for leaving the flow.
    func cancel() {
        stopWork()
    }

    /// "Skip to result": ends with the spots captured so far. With fewer than three the report says it is inconclusive.
    func skipToResult() {
        if case .running(let session) = phase { session.skipToResult() }
    }

    /// Debug: the simulated player presses play on the seat file.
    func simulatePlay() {
        simulatedPlay?(file)
    }

    // MARK: Following the session

    private func stopWork() {
        if case .running(let session) = phase { session.cancel() }
        runTask?.cancel()
        spotsTask?.cancel()
        runTask = nil
        spotsTask = nil
        spots.reset()
    }

    private func finish(_ session: ExternalSeatMeasurementSession) async {
        guard case .finished(let result) = session.state else { return }
        let report = await SeatFlow.analyse(result, room: roomHint, known: spots.analyses)
        guard !Task.isCancelled, case .running(let current) = phase, current === session else { return }
        phase = .finished(report)
    }
}
