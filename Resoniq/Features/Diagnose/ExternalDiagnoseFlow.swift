import Foundation
import Observation
import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqDSP
import ResoniqStore

// MARK: - What the screen shows

/// A calm notice on a listening screen: a caps label over a sentence from the Kit. Not an error: nothing has gone wrong
/// that playing the file again does not fix.
struct ExternalNotice: Equatable {
    var title: String
    var text: String
}

/// Everything the external listening screen shows, in display form. Built by `init(state:...)` from the session's
/// state and progress, so the screen only lays it out and a preview can pass a fixed one. Every sentence is the Kit's
/// (`ExternalSessionText`); the labels are `TestSoundText`'s and `DiagnoseText`'s.
struct ExternalRunDisplay: Equatable {
    /// The portrait, the readout's figure and the three readings, as the normal listening screen has them.
    var run: RunDisplay
    /// The instruction for this moment: "Press play now.", "Listening to run 2 of 3.", "Play the file once more."
    var headline: String
    /// The line under the readings while there is no notice: where to look, or to stay quiet.
    var detail: String?
    /// What is heard that is not the test sound, or why the file must be played again.
    var notice: ExternalNotice?
    /// What VoiceOver is told when this changes: the moments that need an action or mark a step, not every update.
    var announcement: String?

    init(
        state: ExternalMeasurementSession.State,
        progress: ExternalMeasurementProgress?,
        position: SpeakerPosition,
        file: TestSoundFile.Kind,
        runCount: Int,
        widths: [Double],
        heardUpTo: Double?
    ) {
        var runInHand: Int?
        var isChecking = false
        switch state {
        case .hearing(let number): runInHand = number
        case .checking(let number):
            runInHand = number
            isChecking = true
        default: break
        }

        // The portrait fills from the frequency the session reports; before a run is in, it is the not-heard portrait.
        let status: SpeakerPortrait.Status
        var hertz: Double?
        if isChecking {
            status = .drawing(progress: 1)
        } else if let heardUpTo, runInHand != nil {
            hertz = heardUpTo
            status = .drawing(progress: FrequencyRuler.fraction(forFrequency: heardUpTo))
        } else {
            status = .notHeard
        }

        let frequency: RunDisplay.Frequency
        if let playing = progress?.frequency {
            let reading = DiagnoseText.frequencyReading(playing)
            frequency = RunDisplay.Frequency(
                value: reading.value, unit: reading.unit, detail: DriverBand(frequency: Float(playing)).displayName
            )
        } else if progress?.isHearingTone == true {
            frequency = RunDisplay.Frequency(value: "–", unit: nil, detail: TestSoundText.startingTone)
        } else {
            frequency = RunDisplay.Frequency(value: "–", unit: nil, detail: TestSoundText.notHeardYet)
        }

        let readings: RunDisplay.Readings
        if let progress {
            readings = RunDisplay.Readings(
                roomLevel: progress.roomLevel, isRoomQuiet: progress.isRoomQuiet, quietEnoughLevel: progress.quietEnoughLevel,
                isClipping: progress.isClipping, frequency: progress.frequency, peakDecibels: progress.inputPeakDecibels,
                isPhoneSteady: progress.isPhoneSteady
            )
        } else {
            readings = .notMeasured
        }

        run = RunDisplay(
            title: runInHand.map { DiagnoseText.runTitle(position, run: $0, runCount: runCount) } ?? DiagnoseText.speakerName(position),
            widths: widths,
            portrait: status,
            portraitLabel: DiagnoseText.portraitLabel(status, hertz: hertz),
            frequency: frequency,
            room: readings.room, level: readings.level, phone: readings.phone, roomNoise: readings.roomNoise
        )
        headline = ExternalSessionText.headline(for: state, runCount: runCount)

        switch state {
        case .waitingForSound:
            detail = ExternalSessionText.waitingLine(isSilenceLong: false, file: file)
        case .hearing:
            detail = progress?.isHearingTone == true ? ExternalSessionText.toneLine : ExternalSessionText.hearingLine
        default:
            detail = nil
        }

        switch state {
        case .needsAnotherPlay(let have, let reason):
            let text = ExternalSessionText.anotherPlayText(reason, have: have, needed: runCount, file: file)
            notice = ExternalNotice(title: TestSoundText.againNoticeTitle, text: text)
            announcement = "\(headline) \(text)"
        default:
            notice = progress.flatMap { Self.hearingNotice($0.hearing, isSilenceLong: $0.isSilenceLong, file: file) }
            switch state {
            case .waitingForSound, .hearing: announcement = headline
            default: announcement = nil
            }
        }
    }

    /// The Kit's sentence for what is heard that is not the test sound. Nothing at all is said once the silence has
    /// lasted (until then it is just a person reaching for the play button).
    static func hearingNotice(_ hearing: ExternalHearing, isSilenceLong: Bool, file: TestSoundFile.Kind) -> ExternalNotice? {
        if hearing == .nothing, !isSilenceLong { return nil }
        return ExternalSessionText.hearingLine(hearing, file: file).map {
            ExternalNotice(title: TestSoundText.hearingNoticeTitle, text: $0)
        }
    }

    /// Memberwise, for previews.
    init(run: RunDisplay, headline: String, detail: String? = nil, notice: ExternalNotice? = nil, announcement: String? = nil) {
        self.run = run
        self.headline = headline
        self.detail = detail
        self.notice = notice
        self.announcement = announcement
    }
}

// MARK: - The flow

/// One test of one speaker whose sound another device plays: the files, then the listening, then a finished report.
///
/// It owns the `ExternalMeasurementSession`, follows its state and progress, and when the three runs are in analyses
/// them with the same code as `DiagnoseFlow` (`DiagnoseFlow.analyse`, with the source `.anotherDevice` the result
/// carries) and yields the same `DiagnoseFlow.Completed`, so the Result screen, keeping the result, the next-step rule
/// and the comparison memory work on it unchanged. It keeps nothing.
///
/// There is no Paused step: the app cannot pause someone else's player, so a run spoiled by noise is not paused for.
/// The session keeps the good runs and asks for the file to be played again (`needsAnotherPlay`), which the listening
/// screen says in place.
@MainActor
@Observable
final class ExternalDiagnoseFlow {
    enum Step: Equatable {
        /// Getting the test sound files (`TestSoundScreen`).
        case files
        /// The room's floor, "Press play now", a play being heard or checked, or the file to be played again.
        case listening
        /// The last run is in; the runs are being analysed.
        case analysing
        case finished(DiagnoseFlow.Completed)
        case failed(ExternalMeasurementFailure)
        /// The scene left the foreground while it listened; listening was stopped, and the screen says why.
        case stopped

        /// Which screen shows, for transitions: two steps with the same screen are not a change of screen.
        enum Screen: Hashable {
            case files, listening, analysing, finished, denied, failed, stopped
        }

        var screen: Screen {
            switch self {
            case .files: .files
            case .listening: .listening
            case .analysing: .analysing
            case .finished: .finished
            case .failed(.measurement(.permissionDenied)): .denied
            case .failed: .failed
            case .stopped: .stopped
            }
        }

        /// Whether the screen must stay on: the phone listens for the file, or the runs are being put together.
        var needsScreenAwake: Bool {
            switch self {
            case .listening, .analysing: true
            default: false
            }
        }
    }

    private enum Phase {
        case files
        case running(ExternalMeasurementSession)
        case finished(DiagnoseFlow.Completed)
        /// Stopped because the app left the foreground; `start()` listens again.
        case stopped
    }

    /// The speaker to test. Fixed once the test starts.
    let position: SpeakerPosition
    let isQuickCheck: Bool
    /// The speakers of the selected system: the files screen lists a file for each.
    let choices: [SpeakerPosition]
    let singleName: String

    @ObservationIgnored private let audio: AudioEnvironment
    @ObservationIgnored private let counterpart: (SpeakerPosition) -> [RunAnalysis]?
    @ObservationIgnored private let configuration: MeasurementConfiguration
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var simulatedPlay: (@MainActor (TestSoundFile) -> Void)?

    private var phase = Phase.files
    private var live: LivePortrait

    init(
        position: SpeakerPosition,
        isQuickCheck: Bool = false,
        choices: [SpeakerPosition] = [.left, .right],
        singleName: String = "Speaker",
        counterpart: @escaping (SpeakerPosition) -> [RunAnalysis]? = { _ in nil },
        audio: AudioEnvironment = .current,
        configuration: MeasurementConfiguration = .standard
    ) {
        self.position = position
        self.isQuickCheck = isQuickCheck
        self.choices = choices
        self.singleName = singleName
        self.counterpart = counterpart
        self.audio = audio
        self.configuration = configuration
        self.live = LivePortrait(sweep: configuration.sweep(sampleRate: 48_000))
    }

    // MARK: What the screens read

    var step: Step {
        switch phase {
        case .files: .files
        case .finished(let completed): .finished(completed)
        case .stopped: .stopped
        case .running(let session): Self.step(for: session.state)
        }
    }

    /// The file this test listens for.
    var file: TestSoundFile { TestSoundFile(kind: .speakerTest(DiagnoseFlow.channel(for: position))) }

    /// What the files screen lists.
    var filesContext: TestSoundContext { .speaker(choices: choices) }

    /// The listening screen's content.
    var display: ExternalRunDisplay {
        let state: ExternalMeasurementSession.State
        let progress: ExternalMeasurementProgress?
        let runCount: Int
        if case .running(let session) = phase {
            state = session.state
            progress = session.progress
            runCount = session.runCount
        } else {
            state = .idle
            progress = nil
            runCount = configuration.runCount
        }
        return ExternalRunDisplay(
            state: state, progress: progress, position: position, file: file.kind, runCount: runCount,
            widths: live.widths, heardUpTo: live.heardUpTo
        )
    }

    /// The session's state while it runs; nil otherwise. What the debug "simulated player" waits on.
    var sessionState: ExternalMeasurementSession.State? {
        if case .running(let session) = phase { return session.state }
        return nil
    }

    /// Whether a simulated player is there to press play (the simulator, or `-simulatedAudio YES`).
    var canSimulatePlay: Bool { simulatedPlay != nil }

    /// The step a session state is shown as. Pure, so it can be reasoned about (and previewed) without audio.
    static func step(for state: ExternalMeasurementSession.State) -> Step {
        switch state {
        case .idle, .measuringNoiseFloor, .waitingForSound, .hearing, .checking, .needsAnotherPlay: .listening
        case .finished: .analysing
        case .failed(.measurement(.cancelled)): .files
        case .failed(let failure): .failed(failure)
        }
    }

    // MARK: Actions

    /// "I have the file": starts listening to the room, then waits for the sound. Asks for the microphone first if it
    /// has not been asked.
    func start() {
        stopWork()
        live.reset()
        let external = audio.makeExternal()
        simulatedPlay = external.simulatedPlay
        let session = ExternalMeasurementSession(
            io: external.io,
            channel: DiagnoseFlow.channel(for: position),
            permission: audio.permission,
            stillness: external.stillness,
            configuration: configuration
        )
        let updates = session.progressUpdates()
        phase = .running(session)
        progressTask = Task { [weak self] in
            for await progress in updates { self?.ingest(progress) }
        }
        session.start()
        runTask = Task { [weak self] in
            await session.run()
            await self?.finish(session)
        }
    }

    /// Another listening, after a failure: the person already has the file.
    func tryAgain() { start() }

    /// Stops listening and goes back to the files.
    func stop() {
        stopWork()
        live.reset()
        phase = .files
    }

    /// Stops listening without changing the screen: for leaving the flow.
    func cancel() {
        stopWork()
    }

    /// The app left the foreground. A listening is stopped and says why (`.stopped`), instead of quietly going back
    /// to the files; one that has ended, or not begun, is left as it is. Not while the microphone is being asked for
    /// (`.idle`): the system's alert takes the scene's focus.
    func suspend() {
        guard case .running(let session) = phase, session.state != .idle, !session.state.isFinal else { return }
        stopWork()
        phase = .stopped
    }

    /// Debug: the simulated player presses play on the file this test listens for.
    func simulatePlay() {
        simulatedPlay?(file)
    }

    // MARK: Following the session

    private func stopWork() {
        if case .running(let session) = phase { session.cancel() }
        runTask?.cancel()
        progressTask?.cancel()
        runTask = nil
        progressTask = nil
    }

    private func ingest(_ progress: ExternalMeasurementProgress) {
        live.ingest(run: progress.hearingRun ?? progress.runsInHand + 1, frequency: progress.frequency, level: progress.inputLevel)
    }

    private func finish(_ session: ExternalMeasurementSession) async {
        guard case .finished(let result) = session.state else { return }
        let (report, analyses) = await DiagnoseFlow.analyse(result, counterpart: counterpart(position))
        guard !Task.isCancelled, case .running(let current) = phase, current === session else { return }
        phase = .finished(DiagnoseFlow.Completed(
            report: report, analyses: analyses, position: position, isQuickCheck: isQuickCheck,
            movedRuns: result.runs.filter(\.phoneMoved).map(\.run)
        ))
    }
}
