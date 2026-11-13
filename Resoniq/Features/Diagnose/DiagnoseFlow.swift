import Foundation
import Observation
import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqDSP
import ResoniqStore

// MARK: - What the screens show

/// Everything the Listening and Paused screens show, already in display form. Built by `init(state:...)` from the
/// session's state and progress, so a screen only lays it out and a preview can pass a fixed one.
struct RunDisplay: Equatable {
    /// One of the three readings under "Playing now": a caps label, the words, and the sentence VoiceOver reads.
    struct Reading: Equatable {
        var title: String
        var value: String
        var spoken: String
    }

    /// "Playing now": the figure, its unit and the driver.
    struct Frequency: Equatable {
        var value: String
        var unit: String?
        var detail: String
    }

    /// The room-noise readout on the Paused screen.
    struct RoomNoise: Equatable {
        var value: String
        /// 0...1 along the bar.
        var level: Double
        var mark: Double
        var isQuiet: Bool
    }

    /// "Left speaker · run 2 of 3".
    var title: String
    /// 0...1, bottom (20 Hz) to top (20 kHz): `PortraitProfile.live`.
    var widths: [Double]
    var portrait: SpeakerPortrait.Status
    var portraitLabel: String
    var frequency: Frequency
    var room: Reading
    var level: Reading
    var phone: Reading
    var roomNoise: RoomNoise
    /// "1 kHz", when paused.
    var resumeFrequency: String?
    var note: RunNote?

    init(
        state: MeasurementSession.State,
        progress: MeasurementProgress?,
        position: SpeakerPosition,
        runCount: Int,
        widths: [Double],
        heardUpTo: Double?
    ) {
        var run = progress?.run ?? 1
        var note: RunNote?
        var isChecking = false
        var resumeHertz: Double?
        switch state {
        case .playing(let current, let playingNote):
            run = current
            note = playingNote
        case .paused(let current, let frequency):
            run = current
            resumeHertz = frequency
        case .checking(let current):
            run = current
            isChecking = true
        default:
            break
        }
        self.title = DiagnoseText.runTitle(position, run: run, runCount: runCount)
        self.widths = widths
        self.note = note

        // The portrait.
        var hertz: Double?
        let status: SpeakerPortrait.Status
        if let resumeHertz {
            hertz = resumeHertz
            status = .paused(progress: FrequencyRuler.fraction(forFrequency: resumeHertz))
        } else if isChecking {
            status = .drawing(progress: 1)
        } else if let heardUpTo {
            hertz = heardUpTo
            status = .drawing(progress: FrequencyRuler.fraction(forFrequency: heardUpTo))
        } else {
            status = .notHeard
        }
        self.portrait = status
        self.portraitLabel = DiagnoseText.portraitLabel(status, hertz: hertz)
        self.resumeFrequency = resumeHertz.map { DiagnosisText.frequency(Float($0)) }

        // "Playing now".
        if let playing = progress?.frequency {
            let reading = DiagnoseText.frequencyReading(playing)
            frequency = Frequency(
                value: reading.value,
                unit: reading.unit,
                detail: DriverBand(frequency: Float(playing)).displayName
            )
        } else {
            let detail = if isChecking {
                "Checking this run"
            } else if case .playing = state {
                "Waiting for the sound to arrive"
            } else {
                "Listening to the room first"
            }
            frequency = Frequency(value: "–", unit: nil, detail: detail)
        }

        // The three readings.
        if let progress {
            room = Reading(
                title: "Room",
                value: DiagnoseText.room(progress.roomLevel, isQuiet: progress.isRoomQuiet),
                spoken: DiagnoseText.spokenRoom(progress.roomLevel, isQuiet: progress.isRoomQuiet)
            )
            let levelText = DiagnoseText.level(progress)
            level = Reading(title: "Level", value: levelText, spoken: "Level: \(levelText.lowercased()).")
            let phoneText = DiagnoseText.phone(isSteady: progress.isPhoneSteady)
            phone = Reading(title: "Phone", value: phoneText, spoken: "Phone: \(phoneText.lowercased()).")
            roomNoise = RoomNoise(
                value: DiagnoseText.decibels(progress.roomLevel),
                level: DiagnoseText.barFraction(progress.roomLevel),
                mark: progress.quietEnoughLevel.map(DiagnoseText.barFraction) ?? 0,
                isQuiet: progress.isRoomQuiet
            )
        } else {
            room = Reading(title: "Room", value: "–", spoken: "Room: not measured yet.")
            level = Reading(title: "Level", value: "–", spoken: "Level: not measured yet.")
            phone = Reading(title: "Phone", value: "–", spoken: "Phone: not measured yet.")
            roomNoise = RoomNoise(value: "–", level: 0, mark: 0, isQuiet: false)
        }
    }

    /// Memberwise, for previews.
    init(
        title: String, widths: [Double], portrait: SpeakerPortrait.Status, portraitLabel: String,
        frequency: Frequency, room: Reading, level: Reading, phone: Reading, roomNoise: RoomNoise,
        resumeFrequency: String? = nil, note: RunNote? = nil
    ) {
        self.title = title
        self.widths = widths
        self.portrait = portrait
        self.portraitLabel = portraitLabel
        self.frequency = frequency
        self.room = room
        self.level = level
        self.phone = phone
        self.roomNoise = roomNoise
        self.resumeFrequency = resumeFrequency
        self.note = note
    }
}

// MARK: - The flow

/// One test of one speaker, from Aim to a finished report.
///
/// It owns the `MeasurementSession`, follows its state and progress, and when the last run is in, analyses the runs
/// off the main actor and diagnoses them. It keeps nothing: the caller takes the `Completed` report from
/// `step` and decides whether to save it.
@MainActor
@Observable
final class DiagnoseFlow {
    /// A finished test.
    struct Completed: Equatable {
        let report: SpeakerReport
        /// The runs' analyses the report was made from, for the left/right comparison with the other speaker.
        let analyses: [RunAnalysis]
        let position: SpeakerPosition
        /// A quick check is not kept in a room.
        let isQuickCheck: Bool
    }

    /// Why a test ended without a report.
    enum Failure: Equatable {
        case permissionDenied
        case interrupted
        case routeChanged
        /// A run's recording was unusable twice; the problem is the second one's.
        case unusable(RunProblem)
        case audioUnavailable
    }

    enum Step: Equatable {
        /// Choosing a speaker.
        case aim
        /// The room's floor, or a run playing (a run being repeated is `runDisplay.note`).
        case listening
        /// Noise stopped a run; it resumes by itself.
        case paused
        /// The last run is in; the runs are being analysed.
        case analysing
        case finished(Completed)
        case failed(Failure)

        /// Which screen shows, for transitions: two steps with the same screen are not a change of screen.
        enum Screen: Hashable {
            case aim, listening, paused, analysing, finished, denied, failed
        }

        var screen: Screen {
            switch self {
            case .aim: .aim
            case .listening: .listening
            case .paused: .paused
            case .analysing: .analysing
            case .finished: .finished
            case .failed(.permissionDenied): .denied
            case .failed: .failed
            }
        }
    }

    private enum Phase {
        case aim
        case running(MeasurementSession)
        case finished(Completed)
    }

    /// The speaker to test. Chosen on Aim, fixed once the test starts.
    var position: SpeakerPosition
    let isQuickCheck: Bool

    @ObservationIgnored private let audio: AudioEnvironment
    @ObservationIgnored private let counterpart: (SpeakerPosition) -> [RunAnalysis]?
    @ObservationIgnored private let configuration: MeasurementConfiguration
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var envelope: LevelEnvelope
    @ObservationIgnored private var sweep: LogSweep
    @ObservationIgnored private var envelopeRun = 1

    private var phase: Phase = .aim
    private var liveWidths: [Double] = []
    private var liveHeardUpTo: Double?

    /// - Parameters:
    ///   - position: The speaker Aim starts on.
    ///   - counterpart: The other speaker's analysed runs for the speaker being tested, for a left/right comparison,
    ///     when it has been tested. A closure, because the speaker can still be changed on Aim.
    init(
        position: SpeakerPosition = .left,
        isQuickCheck: Bool = false,
        counterpart: @escaping (SpeakerPosition) -> [RunAnalysis]? = { _ in nil },
        audio: AudioEnvironment = .current,
        configuration: MeasurementConfiguration = .standard
    ) {
        self.position = position
        self.isQuickCheck = isQuickCheck
        self.counterpart = counterpart
        self.audio = audio
        self.configuration = configuration
        // The sweep is only used for its time-to-frequency map, which does not depend on the rate; 48 kHz keeps
        // its top frequency at the configured one.
        self.sweep = configuration.sweep(sampleRate: 48_000)
        self.envelope = LevelEnvelope(sampleRate: Self.envelopeRate)
    }

    // MARK: What the screens read

    var step: Step {
        switch phase {
        case .aim: .aim
        case .finished(let completed): .finished(completed)
        case .running(let session): Self.step(for: session.state)
        }
    }

    /// The Listening and Paused screens' content.
    var runDisplay: RunDisplay {
        let state: MeasurementSession.State
        let progress: MeasurementProgress?
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
        return RunDisplay(
            state: state,
            progress: progress,
            position: position,
            runCount: runCount,
            widths: liveWidths,
            heardUpTo: liveHeardUpTo
        )
    }

    /// The step a session state is shown as. Pure, so it can be reasoned about (and previewed) without audio.
    static func step(for state: MeasurementSession.State) -> Step {
        switch state {
        case .idle, .measuringNoiseFloor, .playing, .checking: .listening
        case .paused: .paused
        case .finished: .analysing
        case .failed(let failure):
            switch failure {
            case .cancelled: .aim
            case .permissionDenied: .failed(.permissionDenied)
            case .interrupted: .failed(.interrupted)
            case .routeChanged: .failed(.routeChanged)
            case .recordingUnusable(let problem): .failed(.unusable(problem))
            case .audioUnavailable: .failed(.audioUnavailable)
            // Placeholders until the Diagnose states get their own screens for these two.
            case .tooNoisy: .failed(.unusable(.interruptedRepeatedly))
            case .speakersNotConnected: .failed(.audioUnavailable)
            }
        }
    }

    // MARK: Actions

    /// Starts listening to the chosen speaker. Asks for the microphone first if it has not been asked.
    func start() {
        stopWork()
        resetLive()
        let session = MeasurementSession(
            io: audio.makeIO(),
            channel: Self.channel(for: position),
            permission: audio.permission,
            stillness: audio.makeStillness(),
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

    /// Another test of the same speaker, after a failure.
    func tryAgain() { start() }

    /// Stops playback and the session and goes back to choosing a speaker.
    func stop() {
        stopWork()
        resetLive()
        phase = .aim
    }

    /// Stops playback and the session without changing the screen: for leaving the flow.
    func cancel() {
        stopWork()
    }

    // MARK: Following the session

    private func stopWork() {
        if case .running(let session) = phase { session.cancel() }
        runTask?.cancel()
        progressTask?.cancel()
        runTask = nil
        progressTask = nil
    }

    private func finish(_ session: MeasurementSession) async {
        guard case .finished(let result) = session.state else { return }
        let (report, analyses) = await Self.analyse(result, counterpart: counterpart(position))
        guard !Task.isCancelled, case .running(let current) = phase, current === session else { return }
        phase = .finished(Completed(report: report, analyses: analyses, position: position, isQuickCheck: isQuickCheck))
    }

    /// Each run's response and distortion (about a second a run, the runs side by side), then the comparison of the
    /// runs. Off the main actor.
    @concurrent nonisolated private static func analyse(
        _ result: MeasurementResult,
        counterpart: [RunAnalysis]?
    ) async -> (SpeakerReport, [RunAnalysis]) {
        let analyses = await withTaskGroup(of: (Int, RunAnalysis).self) { group in
            for (index, run) in result.runs.enumerated() {
                group.addTask {
                    (index, RunAnalyzer.analyze(recording: run.samples, sweep: result.sweep, noiseFloor: result.noiseFloor))
                }
            }
            var collected: [(Int, RunAnalysis)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return (SpeakerDiagnosis.diagnose(runs: analyses, counterpart: counterpart), analyses)
    }

    static func channel(for position: SpeakerPosition) -> SpeakerChannel {
        switch position {
        case .left: .left
        case .right: .right
        case .single: .both
        }
    }

    // MARK: The live portrait

    /// The envelope is kept at 1 kHz: the portrait only needs the level at each moment of the sweep, and the
    /// session reports one block every 100 ms.
    private static let envelopeRate = 1_000.0
    /// A sweep position this far behind what is drawn means the run started again from the beginning (a resume
    /// only backs up by the overlap, well under this).
    private static let restartTolerance = 1.0

    private func resetLive() {
        envelope = LevelEnvelope(sampleRate: Self.envelopeRate)
        envelopeRun = 1
        liveWidths = []
        liveHeardUpTo = nil
    }

    /// Adds one block's level at the moment of the sweep it carries, then redraws the portrait from the Kit's
    /// `PortraitProfile.live`. The delay is 0 because `progress.frequency` is already the frequency arriving now.
    private func ingest(_ progress: MeasurementProgress) {
        if progress.run != envelopeRun {
            resetLive()
            envelopeRun = progress.run
        }
        guard let frequency = progress.frequency else { return }
        let moment = sweep.time(of: frequency)
        if moment < envelope.duration - Self.restartTolerance {
            envelope = LevelEnvelope(sampleRate: Self.envelopeRate)
        }
        let missing = Int(((moment - envelope.duration) * Self.envelopeRate).rounded())
        guard missing > 0 else { return }
        let amplitude = Decibels.toAmplitude(progress.inputLevel.dBFS)
        envelope.append([Float](repeating: amplitude, count: missing))
        let profile = PortraitProfile.live(envelope: envelope, sweep: sweep, delay: 0)
        liveWidths = profile.widths.map(Double.init)
        liveHeardUpTo = profile.heardUpTo.map(Double.init)
    }
}
