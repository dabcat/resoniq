import Foundation
import Observation
import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqDSP
import ResoniqStore

// MARK: - What the screens show

/// Everything Three spots and its Paused variant show, already in display form. Built by `init(state:...)` from the
/// session's state and progress, so a screen only lays it out and a preview can pass a fixed one.
struct SeatRunDisplay: Equatable {
    struct Pill: Equatable {
        var title: String
        var state: SpotsDiagram.SpotState
        /// "Seat, done", "Left, measuring now", "Right, still to do".
        var spoken: String
    }

    /// Seat, Left, Right, in the order they are measured.
    var pills: [Pill]
    /// The headline: what to do now.
    var instruction: String
    /// The state of the spots from the left of the top view (left, seat, right).
    var spots: [SpotsDiagram.SpotState]
    /// Where the phone is in the top view, from the left; nil when nothing is left to measure.
    var phoneSpot: Int?
    var diagramLabel: String
    /// Spots captured, for the haptic.
    var capturedCount: Int
    /// "1 of 3 in".
    var progressLabel: String
    /// Each captured spot's line, then the average of them: the Kit's `SeatReport.spotCurves` and `curve`.
    var traces: [[Double]]
    var average: [Double]
    var curveLabel: String
    var room: RunDisplay.Reading
    var level: RunDisplay.Reading
    var roomNoise: RunDisplay.RoomNoise
    /// "Left spot · right speaker", on the Paused screen.
    var pausedTitle: String
    /// "1 kHz", when paused.
    var resumeFrequency: String?
    var note: RunNote?
    /// "I'll start by myself once the phone is still." or "Stay quiet while the tones play."
    var footerLine: String

    init(
        state: SeatMeasurementSession.State,
        progress: SeatMeasurementProgress?,
        channels: [SpeakerChannel],
        building: SeatBuilding?
    ) {
        let total = SeatSpot.allCases.count
        var captured = progress?.spotsCaptured ?? 0
        var note: RunNote?
        var resume: Double?
        var activeSpot: SeatSpot? = progress?.spot
        var pausedChannel = channels[0]
        switch state {
        case .waitingForStillness(let spot):
            activeSpot = spot
        case .playing(let spot, _, let playingNote):
            activeSpot = spot
            note = playingNote
        case .paused(let spot, let channel, let frequency):
            activeSpot = spot
            pausedChannel = channel
            resume = frequency
        case .checking(let spot, _):
            activeSpot = spot
        case .spotCaptured(let spot):
            captured = max(captured, spot.index + 1)
        case .finished:
            captured = total
        default:
            break
        }
        captured = min(captured, total)

        // The spot being worked on is the first one not captured.
        let active: SeatSpot? = captured < total ? SeatSpot.allCases[captured] : nil
        let current = activeSpot.flatMap { $0.index >= captured ? $0 : nil } ?? active
        func spotState(_ spot: SeatSpot) -> SpotsDiagram.SpotState {
            if spot.index < captured { return .done }
            return spot == current ? .active : .upcoming
        }
        let spots = SeatSpot.allCases.sorted { MeasureText.position(of: $0) < MeasureText.position(of: $1) }.map(spotState)
        pills = SeatSpot.allCases.map { spot in
            let state = spotState(spot)
            let words = switch state {
            case .done: "done"
            case .active: "measuring now"
            case .upcoming: "still to do"
            }
            return Pill(title: MeasureText.pillTitle(spot), state: state, spoken: "\(MeasureText.pillTitle(spot)), \(words)")
        }
        self.spots = spots
        phoneSpot = current.map(MeasureText.position(of:))
        diagramLabel = MeasureText.diagramLabel(
            captured: SeatSpot.allCases.filter { $0.index < captured },
            active: current
        )
        capturedCount = captured
        progressLabel = MeasureText.progress(captured: captured, of: total)
        instruction = MeasureText.instruction(for: state, wait: progress?.wait, channels: channels)
        pausedTitle = MeasureText.pausedTitle(spot: current ?? .seat, channel: pausedChannel, of: channels)
        resumeFrequency = resume.map { SeatText.frequency(Float($0)) }
        self.note = note

        let isWaiting: Bool
        switch state {
        case .idle, .measuringNoiseFloor, .waitingForStillness: isWaiting = true
        default: isWaiting = false
        }
        footerLine = isWaiting ? MeasureText.waitingLine : MeasureText.playingLine

        // The curves: the Kit's own, from the spots analysed so far, as far as they may be drawn.
        let curves = (building?.spotCurves ?? []).map { SeatReport.heldAtEdges($0).map(Double.init) }
        traces = curves
        average = building?.average.map { SeatReport.heldAtEdges($0).map(Double.init) } ?? []
        curveLabel = MeasureText.curveLabel(captured: captured, drawn: curves.count, of: total)

        // The readings.
        if let progress {
            room = RunDisplay.Reading(
                title: "Room",
                value: DiagnoseText.room(progress.roomLevel, isQuiet: progress.isRoomQuiet),
                spoken: DiagnoseText.spokenRoom(progress.roomLevel, isQuiet: progress.isRoomQuiet)
            )
            let levelText = MeasureText.level(
                isClipping: progress.isClipping, frequency: progress.frequency, peakDecibels: progress.inputPeakDecibels
            )
            level = RunDisplay.Reading(title: "Level", value: levelText, spoken: "Level: \(levelText.lowercased()).")
            roomNoise = RunDisplay.RoomNoise(
                value: DiagnoseText.decibels(progress.roomLevel),
                level: DiagnoseText.barFraction(progress.roomLevel),
                mark: progress.quietEnoughLevel.map(DiagnoseText.barFraction) ?? 0,
                isQuiet: progress.isRoomQuiet
            )
        } else {
            room = RunDisplay.Reading(title: "Room", value: "–", spoken: "Room: not measured yet.")
            level = RunDisplay.Reading(title: "Level", value: "–", spoken: "Level: not measured yet.")
            roomNoise = RunDisplay.RoomNoise(value: "–", level: 0, mark: 0, isQuiet: false)
        }
    }

    /// Memberwise, for previews.
    init(
        pills: [Pill], instruction: String, spots: [SpotsDiagram.SpotState], phoneSpot: Int?, diagramLabel: String,
        capturedCount: Int, progressLabel: String, traces: [[Double]], average: [Double], curveLabel: String,
        room: RunDisplay.Reading, level: RunDisplay.Reading, roomNoise: RunDisplay.RoomNoise,
        pausedTitle: String = "Left spot · left speaker", resumeFrequency: String? = nil, note: RunNote? = nil,
        footerLine: String = MeasureText.waitingLine
    ) {
        self.pills = pills
        self.instruction = instruction
        self.spots = spots
        self.phoneSpot = phoneSpot
        self.diagramLabel = diagramLabel
        self.capturedCount = capturedCount
        self.progressLabel = progressLabel
        self.traces = traces
        self.average = average
        self.curveLabel = curveLabel
        self.room = room
        self.level = level
        self.roomNoise = roomNoise
        self.pausedTitle = pausedTitle
        self.resumeFrequency = resumeFrequency
        self.note = note
        self.footerLine = footerLine
    }
}

// MARK: - The flow

/// One seat measurement, from Sit and aim to a finished report.
///
/// It owns the `SeatMeasurementSession`, follows its state and progress, and when the last spot is in, analyses the
/// spots off the main actor and diagnoses them with the room's size when it is known. It keeps nothing: the caller
/// takes the report from `step` and decides whether to save it.
///
/// The curve panel grows from `building`, the Kit's running average (`SeatDiagnosis.building`) of the spots analysed
/// so far: each spot is analysed off the main actor as soon as the session has captured it (`capturedSpots`).
@MainActor
@Observable
final class SeatFlow {
    /// Why a measurement ended without a report.
    enum Failure: Equatable {
        case permissionDenied
        case interrupted
        case routeChanged
        /// A spot's recording was unusable twice; the problem is the second one's.
        case unusable(RunProblem)
        case audioUnavailable
        /// The room stayed too loud to carry on.
        case tooNoisy
        /// The sound would come out of the phone itself.
        case speakersNotConnected(AudioOutputRoute)
    }

    enum Step: Equatable {
        /// Sit and aim.
        case guide
        /// The room's floor, or a spot being waited for, played, checked or captured.
        case running
        /// Noise stopped a sweep; it resumes by itself.
        case paused
        /// The last spot is in; the spots are being analysed.
        case analysing
        case finished(SeatReport)
        case failed(Failure)

        /// Which screen shows, for transitions: two steps with the same screen are not a change of screen.
        enum Screen: Hashable {
            case guide, running, paused, analysing, finished, denied, failed
        }

        var screen: Screen {
            switch self {
            case .guide: .guide
            case .running: .running
            case .paused: .paused
            case .analysing: .analysing
            case .finished: .finished
            case .failed(.permissionDenied): .denied
            case .failed: .failed
            }
        }
    }

    private enum Phase {
        case guide
        case running(SeatMeasurementSession)
        case finished(SeatReport)
    }

    let kind: SoundSystemKind
    /// The channels played at each spot: a pair, left then right; one speaker or a soundbar, both together.
    let channels: [SpeakerChannel]

    @ObservationIgnored private let audio: AudioEnvironment
    @ObservationIgnored private let roomHint: RoomHint?
    @ObservationIgnored private let configuration: MeasurementConfiguration
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var spotsTask: Task<Void, Never>?
    /// Each captured spot's analysis, by its place in the order; and how many spots have been sent to be analysed.
    @ObservationIgnored private var analyses: [Int: SpotAnalysis] = [:]
    @ObservationIgnored private var requested = 0

    private var phase: Phase = .guide
    /// The running average of the spots analysed so far, for the curve panel.
    private var building: SeatBuilding?

    /// - Parameters:
    ///   - kind: The selected system's kind: it decides which channels play.
    ///   - roomHint: The room's size from its stored layout, when there is one; it lets the diagnosis say the room
    ///     is the cause.
    init(
        kind: SoundSystemKind,
        roomHint: RoomHint? = nil,
        audio: AudioEnvironment = .current,
        configuration: MeasurementConfiguration = .seat
    ) {
        self.kind = kind
        self.channels = Self.channels(for: kind)
        self.roomHint = roomHint
        self.audio = audio
        self.configuration = configuration
    }

    // MARK: What the screens read

    var step: Step {
        switch phase {
        case .guide: .guide
        case .finished(let report): .finished(report)
        case .running(let session): Self.step(for: session.state)
        }
    }

    /// Three spots' and Paused's content.
    var display: SeatRunDisplay {
        if case .running(let session) = phase {
            return SeatRunDisplay(state: session.state, progress: session.progress, channels: channels, building: building)
        }
        return SeatRunDisplay(state: .idle, progress: nil, channels: channels, building: building)
    }

    /// The step a session state is shown as. Pure, so it can be reasoned about (and previewed) without audio.
    static func step(for state: SeatMeasurementSession.State) -> Step {
        switch state {
        case .idle, .measuringNoiseFloor, .waitingForStillness, .playing, .checking, .spotCaptured: .running
        case .paused: .paused
        case .finished: .analysing
        case .failed(let failure):
            switch failure {
            case .cancelled: .guide
            case .permissionDenied: .failed(.permissionDenied)
            case .interrupted: .failed(.interrupted)
            case .routeChanged: .failed(.routeChanged)
            case .recordingUnusable(let problem): .failed(.unusable(problem))
            case .audioUnavailable: .failed(.audioUnavailable)
            case .tooNoisy: .failed(.tooNoisy)
            case .speakersNotConnected(let route): .failed(.speakersNotConnected(route))
            }
        }
    }

    /// The channels a system kind plays at each spot.
    static func channels(for kind: SoundSystemKind) -> [SpeakerChannel] {
        switch kind {
        case .stereoPair, .stereoWithSubwoofer, .surround: [.left, .right]
        case .soundbar, .singleSpeaker: [.both]
        }
    }

    // MARK: Actions

    /// Starts measuring: the room's floor first, then the three spots. Asks for the microphone first if it has not
    /// been asked.
    func start() {
        stopWork()
        building = nil
        let seat = audio.makeSeat()
        let session = SeatMeasurementSession(
            io: seat.io,
            channels: channels,
            permission: audio.permission,
            stillness: seat.stillness,
            configuration: configuration
        )
        let updates = session.progressUpdates()
        phase = .running(session)
        session.start()
        // A spot is captured between two progress updates; each update checks for new ones.
        spotsTask = Task { [weak self] in
            for await _ in updates { self?.analyseNewSpots(of: session) }
        }
        runTask = Task { [weak self] in
            await session.run()
            await self?.finish(session)
        }
    }

    /// Another measurement, after a failure.
    func tryAgain() { start() }

    /// Stops playback and the session and goes back to Sit and aim.
    func stop() {
        stopWork()
        building = nil
        phase = .guide
    }

    /// Stops playback and the session without changing the screen: for leaving the flow.
    func cancel() {
        stopWork()
    }

    /// "Skip to result": ends with the spots captured so far. With fewer than three the report says it is
    /// inconclusive.
    func skipToResult() {
        if case .running(let session) = phase { session.skipToResult() }
    }

    // MARK: Following the session

    private func stopWork() {
        if case .running(let session) = phase { session.cancel() }
        runTask?.cancel()
        spotsTask?.cancel()
        runTask = nil
        spotsTask = nil
        analyses = [:]
        requested = 0
    }

    /// Analyses each spot the session has captured since the last look, off the main actor, and grows the running
    /// average from the spots analysed so far, in order.
    private func analyseNewSpots(of session: SeatMeasurementSession) {
        guard case .running(let current) = phase, current === session, let captured = session.captured else { return }
        while requested < captured.spots.count {
            let index = requested
            requested += 1
            let spot = captured.spots[index]
            Task { [weak self] in
                let analysis = await Self.analyse(spot, channels: captured.channels, sweep: captured.sweep, floor: captured.noiseFloor)
                guard let self, case .running(let current) = self.phase, current === session, let analysis else { return }
                self.analyses[index] = analysis
                let inOrder = (0..<self.requested).prefix { self.analyses[$0] != nil }.compactMap { self.analyses[$0] }
                self.building = SeatDiagnosis.building(spots: inOrder)
            }
        }
    }

    private func finish(_ session: SeatMeasurementSession) async {
        guard case .finished(let result) = session.state else { return }
        let report = await Self.analyse(result, room: roomHint, known: analyses)
        guard !Task.isCancelled, case .running(let current) = phase, current === session else { return }
        phase = .finished(report)
    }

    /// One spot's response, distortion and decay (about a second). Off the main actor.
    @concurrent nonisolated private static func analyse(
        _ spot: SeatSpotRecording, channels: [SpeakerChannel], sweep: LogSweep, floor: NoiseFloorReport
    ) async -> SpotAnalysis? {
        guard let left = spot.recording(for: channels[0]) else { return nil }
        let right = channels.count > 1 ? spot.recording(for: channels[1]) : nil
        return SpotAnalyzer.analyze(left: left.samples, right: right?.samples, sweep: sweep, noiseFloor: floor)
    }

    /// Each spot not analysed yet (`known` holds those that are), the spots side by side, then the diagnosis of the
    /// seat. Off the main actor.
    @concurrent nonisolated private static func analyse(
        _ result: SeatMeasurementResult, room: RoomHint?, known: [Int: SpotAnalysis]
    ) async -> SeatReport {
        let channels = result.channels
        let analyses = await withTaskGroup(of: (Int, SpotAnalysis?).self) { group in
            for (index, spot) in result.spots.enumerated() {
                group.addTask {
                    if let analysis = known[index] { return (index, analysis) }
                    return (index, await analyse(spot, channels: channels, sweep: result.sweep, floor: result.noiseFloor))
                }
            }
            var collected: [(Int, SpotAnalysis)] = []
            for await (index, analysis) in group {
                if let analysis { collected.append((index, analysis)) }
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return SeatDiagnosis.diagnose(spots: analyses, room: room)
    }
}
