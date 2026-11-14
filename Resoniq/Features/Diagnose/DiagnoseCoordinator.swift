import Foundation
import Observation
import ResoniqAudio
import ResoniqDiagnostics
import ResoniqStore
import SwiftData

// MARK: - Rules

/// What a test leads to and whether it is kept. Plain functions of values: no store, no audio, nothing to set up.
enum DiagnoseRules {
    /// The most useful next step after a result, as the primary button shows it.
    struct NextStep: Equatable {
        enum Action: Equatable {
            /// Start the flow for this speaker.
            case test(SpeakerPosition)
            /// Back to Diagnose home.
            case done
        }

        var title: String
        var action: Action
    }

    /// The most useful next step after the result of `tested`:
    ///
    /// 1. A result that cannot be trusted (`isConclusive == false`) offers the same speaker again.
    /// 2. Otherwise, the first speaker of this kind of system that has not been heard is next: "Now the right
    ///    speaker" after the left, "Now the left speaker" after the right.
    /// 3. When every speaker has been heard (or there is only one), it is "Done".
    ///
    /// - Parameter heard: The speakers with a result: kept in the store, or, in a quick check, finished earlier in
    ///   that quick check (or it would offer the other speaker for ever).
    static func nextStep(
        after tested: SpeakerPosition,
        isConclusive: Bool,
        kind: SoundSystemKind,
        heard: Set<SpeakerPosition>
    ) -> NextStep {
        guard isConclusive else {
            return NextStep(title: "Try \(tested.speakerInSentence) again", action: .test(tested))
        }
        let heard = heard.union([tested])
        if let next = HomePlan.positions(for: kind).first(where: { !heard.contains($0) }) {
            return NextStep(title: "Now \(next.speakerInSentence)", action: .test(next))
        }
        return NextStep(title: "Done", action: .done)
    }

    /// A finished test is kept in the selected system as soon as it appears, unless it is a quick check or its
    /// report is inconclusive (nothing was learned, so nothing is worth keeping).
    static func shouldKeep(isQuickCheck: Bool, isConclusive: Bool) -> Bool {
        !isQuickCheck && isConclusive
    }

    /// Whether a finished test's runs may feed a later left/right comparison: only when the test is kept. A quick
    /// check, an inconclusive test and a test that could not be saved never do, so the second speaker is never
    /// compared with a run the user chose not to keep.
    static func shouldRemember(isKept: Bool) -> Bool {
        isKept
    }

    /// What `ComparisonMemory` holds after the user discards a kept test: the entry for its speaker is dropped.
    static func memory(
        _ memory: [ComparisonMemory.Key: [RunAnalysis]],
        afterDiscarding key: ComparisonMemory.Key
    ) -> [ComparisonMemory.Key: [RunAnalysis]] {
        memory.filter { $0.key != key }
    }

    /// What `ComparisonMemory` holds when `system` is the selected system: nothing from any other, so going back to
    /// a system does not bring back runs from before it was left.
    static func memory(
        _ memory: [ComparisonMemory.Key: [RunAnalysis]],
        whenSelected system: PersistentIdentifier?
    ) -> [ComparisonMemory.Key: [RunAnalysis]] {
        memory.filter { $0.key.system == system }
    }

    /// The speakers a quick check has heard so far in its chain ("Now the right speaker", then "Done"): a quick check
    /// is kept nowhere, so this is all that lets it move on to the other speaker.
    static func quickHeard(
        _ heard: Set<SpeakerPosition>,
        after tested: SpeakerPosition,
        isQuickCheck: Bool
    ) -> Set<SpeakerPosition> {
        isQuickCheck ? heard.union([tested]) : heard
    }
}

// MARK: - Session memory

/// The analysed runs of each speaker's kept test, for the selected system only and the life of the app session only.
/// A stored test keeps just the report, so this is what lets the second speaker of a pair be compared with the first.
/// It holds only what the user kept: a quick check never writes to it, a discarded test is forgotten, and a different
/// selected system empties it (`DiagnoseRules.shouldRemember`, `memory(_:afterDiscarding:)`, `memory(_:whenSelected:)`).
@MainActor
@Observable
final class ComparisonMemory {
    nonisolated struct Key: Hashable {
        let system: PersistentIdentifier
        let position: SpeakerPosition
    }

    @ObservationIgnored private var runs: [Key: [RunAnalysis]] = [:]
    /// How each remembered speaker's sound was played, where it was not the phone (`SoundSource`); a speaker with no
    /// entry here was played by the phone. Kept in step with `runs`.
    @ObservationIgnored private var sources: [Key: SoundSource] = [:]

    func record(
        _ analyses: [RunAnalysis], source: SoundSource? = nil, for position: SpeakerPosition, in system: PersistentIdentifier
    ) {
        let key = Key(system: system, position: position)
        runs[key] = analyses
        sources[key] = source
    }

    /// Drops the speaker's runs: its test was discarded.
    func forget(_ position: SpeakerPosition, in system: PersistentIdentifier) {
        runs = DiagnoseRules.memory(runs, afterDiscarding: Key(system: system, position: position))
        sources = sources.filter { runs[$0.key] != nil }
    }

    /// Drops the runs of every system but `system`.
    func select(_ system: PersistentIdentifier?) {
        let kept = DiagnoseRules.memory(runs, whenSelected: system)
        if kept.count != runs.count {
            runs = kept
            sources = sources.filter { runs[$0.key] != nil }
        }
    }

    /// Drops every speaker's runs: the results they belonged to were deleted.
    func removeAll() {
        runs = [:]
        sources = [:]
    }

    /// The other speaker of the pair, when it was tested in this session, and how its sound was played; nil when it was
    /// not tested (the inner value is nil when the phone played it).
    func counterpartSource(for position: SpeakerPosition, in system: PersistentIdentifier) -> (position: SpeakerPosition, source: SoundSource?)? {
        let other: SpeakerPosition
        switch position {
        case .left: other = .right
        case .right: other = .left
        case .single: return nil
        }
        let key = Key(system: system, position: other)
        guard runs[key] != nil else { return nil }
        return (other, sources[key])
    }

    /// The runs of the speaker on the other side of the pair, when it was tested in this session.
    func counterpart(for position: SpeakerPosition, in system: PersistentIdentifier) -> [RunAnalysis]? {
        let other: SpeakerPosition
        switch position {
        case .left: other = .right
        case .right: other = .left
        case .single: return nil
        }
        return runs[Key(system: system, position: other)]
    }

    func heard(in system: PersistentIdentifier) -> Set<SpeakerPosition> {
        Set(runs.keys.filter { $0.system == system }.map(\.position))
    }
}

// MARK: - Coordinator

/// Everything the Diagnose tab does besides drawing: which flow or result is on screen, what was kept, what comes
/// next. It decides navigation and what to save; every judgement about a speaker comes from the Kit.
@MainActor
@Observable
final class DiagnoseCoordinator {
    /// What the full-screen cover shows. Nil: the cover is not shown.
    enum Content {
        /// A test, from Aim to its result (the result is `outcome`).
        case test(DiagnoseFlow)
        /// A test whose sound another device plays: the files, then listening, then the same result.
        case external(ExternalDiagnoseFlow)
        /// A kept result, opened from home.
        case stored
        /// A kept result that cannot be read any more.
        case unreadable(SpeakerPosition)
    }

    /// Pushed on the cover's one navigation stack.
    nonisolated enum Route: Hashable {
        /// A finding of the shown report, by its index.
        case finding(Int)
    }

    /// A result on screen, whether it came from a test just finished or from the store.
    struct Outcome {
        var report: SpeakerReport
        var position: SpeakerPosition
        var isQuickCheck: Bool
        /// The stored test, while it is kept.
        var test: SpeakerTest?
        var system: SoundSystem?
        var next: DiagnoseRules.NextStep
        /// The runs in which the phone moved (`Completed.movedRuns`); empty for a stored result.
        var movedRuns: [Int] = []
        /// The other speaker's name and how its sound was played, when the left/right comparison used its runs and it
        /// was measured differently from this one; empty otherwise (`SourceWords.lines`).
        var sourceLines: [String] = []
    }

    private(set) var content: Content?
    /// Changes whenever a different test or result takes the cover, so its screens start fresh.
    private(set) var contentID = UUID()
    var path: [Route] = []
    private(set) var outcome: Outcome?

    /// The rename alert.
    var isRenaming = false
    var renameDraft = ""

    @ObservationIgnored private let store: ResoniqStore
    @ObservationIgnored private let memory: ComparisonMemory
    @ObservationIgnored private let audio: AudioEnvironment

    init(store: ResoniqStore, memory: ComparisonMemory, audio: AudioEnvironment) {
        self.store = store
        self.memory = memory
        self.audio = audio
    }

    // MARK: Reading

    /// "Kept in · room · system" while the result is kept.
    var keptIn: KeptIn? {
        guard let outcome, outcome.test != nil, let system = outcome.system else { return nil }
        return KeptIn(room: system.room?.name ?? StoreText.defaultRoomName, system: system.name)
    }

    /// A player for "Hear it yourself", on the app's audio. The coordinator keeps a weak reference to the latest one,
    /// so the app's lifecycle can stop a tone that is playing (`stopTone`).
    func makeTonePlayer() -> any FindingTonePlaying {
        let player = TonePlayerAdapter(player: TonePlayer(io: audio.makeIO()))
        tone = player
        return player
    }

    /// The scene left the foreground: a hold-to-hear tone (one VoiceOver started, with no finger to lift) stops now
    /// instead of at its time limit.
    func stopTone() {
        tone?.stop()
    }

    @ObservationIgnored private weak var tone: TonePlayerAdapter?

    /// The selected system. Reading it tells the comparison memory which system is selected, so a change of system
    /// forgets the runs kept for the one before.
    private var system: SoundSystem? {
        let system = try? store.defaultContext().system
        memory.select(system?.persistentModelID)
        return system
    }

    /// Speakers a quick check has finished in this chain; empty outside one. Reset when a quick check starts.
    @ObservationIgnored private var quickHeard: Set<SpeakerPosition> = []

    /// The speakers with a result in the selected system: kept, or (in a quick check) heard earlier in that quick check.
    private func heard(in system: SoundSystem?, isQuickCheck: Bool) -> Set<SpeakerPosition> {
        guard let system else { return isQuickCheck ? quickHeard : [] }
        let kept = HomePlan.positions(for: system.kind).filter { position in
            store.history(for: position, in: system).contains { $0.report != nil }
        }
        let remembered = Set(kept).union(memory.heard(in: system.persistentModelID))
        return isQuickCheck ? remembered.union(quickHeard) : remembered
    }

    // MARK: Starting

    /// Starts a test of `position` from home. Ignored while a flow or a result is already on screen.
    func startTest(_ position: SpeakerPosition, isQuickCheck: Bool = false) {
        guard content == nil else { return }
        show(.test(makeFlow(position, isQuickCheck: isQuickCheck)))
    }

    /// The first test of the first launch ("Try it on a speaker"): the speaker the home's primary button offers on a
    /// system with no results.
    func startFirstTest() {
        let kind = system?.kind ?? .stereoPair
        startTest(HomePlan.make(kind: kind, latest: [:]).next)
    }

    /// The rooms sheet or Settings closed: reading the selected system tells the comparison memory which one it is,
    /// so a change drops the runs kept for the system before.
    func selectionMayHaveChanged() {
        _ = system
    }

    /// The quick check: the same flow, on the first speaker of the system, kept nowhere.
    func startQuickCheck() {
        guard content == nil else { return }
        quickHeard = []
        let kind = system?.kind ?? .stereoPair
        startTest(HomePlan.positions(for: kind).first ?? .single, isQuickCheck: true)
    }

    /// Starts a test of `position` whose sound another device plays, from the files screen. Ignored while a flow or a
    /// result is already on screen.
    func startExternalTest(_ position: SpeakerPosition, isQuickCheck: Bool = false) {
        guard content == nil else { return }
        show(.external(makeExternalFlow(position, isQuickCheck: isQuickCheck)))
    }

    /// "My speakers can't play from this iPhone" and "Play the test sound from another device": the test on screen
    /// carries on as a listening test, for the same speaker, from the files screen. The test it leaves is stopped.
    func switchToExternal(from flow: DiagnoseFlow) {
        guard case .test(let current) = content, current === flow else { return }
        flow.cancel()
        show(.external(makeExternalFlow(flow.position, isQuickCheck: flow.isQuickCheck)))
    }

    /// A tap on a speaker of home: its latest kept result, or its test when it has none.
    func openSpeaker(_ position: SpeakerPosition) {
        guard content == nil else { return }
        guard let system else { return startTest(position) }
        let history = store.history(for: position, in: system)
        guard !history.isEmpty else { return startTest(position) }
        // The newest readable test, as home shows it.
        guard let test = history.first(where: { $0.report != nil }), let report = test.report else {
            return show(.unreadable(position))
        }
        outcome = Outcome(
            report: report, position: position, isQuickCheck: false, test: test, system: system,
            next: DiagnoseRules.nextStep(
                after: position, isConclusive: report.isConclusive, kind: system.kind, heard: heard(in: system, isQuickCheck: false)
            )
        )
        show(.stored)
    }

    /// From the screen for a result that cannot be read.
    func testAgain(_ position: SpeakerPosition) {
        show(.test(makeFlow(position, isQuickCheck: false)))
    }

    private func makeFlow(_ position: SpeakerPosition, isQuickCheck: Bool) -> DiagnoseFlow {
        let systemID = system?.persistentModelID
        let kind = system?.kind ?? .stereoPair
        return DiagnoseFlow(
            position: position,
            isQuickCheck: isQuickCheck,
            choices: HomePlan.positions(for: kind),
            singleName: kind == .soundbar ? "Soundbar" : "Speaker",
            counterpart: { [memory] position in
                systemID.flatMap { memory.counterpart(for: position, in: $0) }
            },
            audio: audio
        )
    }

    private func makeExternalFlow(_ position: SpeakerPosition, isQuickCheck: Bool) -> ExternalDiagnoseFlow {
        let systemID = system?.persistentModelID
        let kind = system?.kind ?? .stereoPair
        return ExternalDiagnoseFlow(
            position: position,
            isQuickCheck: isQuickCheck,
            choices: HomePlan.positions(for: kind),
            singleName: kind == .soundbar ? "Soundbar" : "Speaker",
            counterpart: { [memory] position in
                systemID.flatMap { memory.counterpart(for: position, in: $0) }
            },
            audio: audio
        )
    }

    private func show(_ content: Content) {
        switch content {
        case .test, .external: outcome = nil
        case .stored, .unreadable: break
        }
        path = []
        isRenaming = false
        contentID = UUID()
        self.content = content
    }

    // MARK: Finishing

    /// The flow produced a report: remember its runs for the comparison, keep the report when the rule says so,
    /// and work out the next step. Once per test.
    func testFinished(_ completed: DiagnoseFlow.Completed) {
        switch content {
        case .test, .external: break
        case .stored, .unreadable, nil: return
        }
        guard outcome == nil else { return }
        let system = system
        let report = completed.report
        var test: SpeakerTest?
        if DiagnoseRules.shouldKeep(isQuickCheck: completed.isQuickCheck, isConclusive: report.isConclusive),
           let system {
            test = try? store.keep(report, speaker: completed.position, in: system)
        }
        // The other speaker's runs fed the left/right comparison; say so when it was measured another way.
        var sourceLines: [String] = []
        if let system, let other = memory.counterpartSource(for: completed.position, in: system.persistentModelID) {
            sourceLines = SourceWords.lines(
                (SourceWords.speaker(completed.position), report.source), (SourceWords.speaker(other.position), other.source))
        }
        // Only a kept test is compared with the other speaker's later.
        if DiagnoseRules.shouldRemember(isKept: test != nil), let system {
            memory.record(completed.analyses, source: report.source, for: completed.position, in: system.persistentModelID)
        }
        quickHeard = DiagnoseRules.quickHeard(quickHeard, after: completed.position, isQuickCheck: completed.isQuickCheck)
        outcome = Outcome(
            report: report, position: completed.position, isQuickCheck: completed.isQuickCheck, test: test,
            system: system,
            next: DiagnoseRules.nextStep(
                after: completed.position, isConclusive: report.isConclusive, kind: system?.kind ?? .stereoPair,
                heard: heard(in: system, isQuickCheck: completed.isQuickCheck)
            ),
            movedRuns: completed.movedRuns,
            sourceLines: sourceLines
        )
    }

    /// The primary button of the result.
    func primary() {
        guard let outcome else { return }
        switch outcome.next.action {
        case .done:
            close()
        case .test(let position):
            // Another test of the same kind: a quick check stays a quick check, and a system that could not take sound
            // from the phone for this speaker will not for the next one (the files screen has its file).
            if outcome.report.source == .anotherDevice {
                show(.external(makeExternalFlow(position, isQuickCheck: outcome.isQuickCheck)))
            } else {
                show(.test(makeFlow(position, isQuickCheck: outcome.isQuickCheck)))
            }
        }
    }

    /// "Don't keep": deletes the kept test and goes home.
    func dontKeep() {
        if let outcome, let test = outcome.test {
            let system = outcome.system?.persistentModelID
            try? store.discard(test)
            // The runs of a discarded test must not be compared with the other speaker's.
            if let system { memory.forget(outcome.position, in: system) }
        }
        close()
    }

    // MARK: Renaming

    func beginRename() {
        renameDraft = outcome?.system?.name ?? ""
        isRenaming = true
    }

    func commitRename() {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, let system = outcome?.system { try? store.rename(system, to: name) }
        isRenaming = false
    }

    // MARK: Navigation

    func openFinding(_ finding: Finding) {
        guard finding.noteAction != .informational,
              let index = outcome?.report.findings.firstIndex(where: { $0.id == finding.id }) else { return }
        path.append(.finding(index))
    }

    func closeFinding() {
        if !path.isEmpty { path.removeLast() }
    }

    /// "Delete all results" or "Delete everything": the comparison memory and the quick check's chain are dropped and
    /// the cover closes (a result or a finding on screen may be one that was just deleted), back to Diagnose home.
    func resetAfterDataDeletion() {
        stopTone()
        memory.removeAll()
        quickHeard = []
        close()
    }

    /// The scene left the foreground: a test that is listening or playing stops and its screen says why (the flow's
    /// `suspend()`). A result on screen stays.
    func suspendFlow() {
        switch content {
        case .test(let flow): flow.suspend()
        case .external(let flow): flow.suspend()
        case .stored, .unreadable, nil: break
        }
    }

    /// Stops a test that is listening or playing, without a word: the cover is closing.
    private func stopFlow() {
        switch content {
        case .test(let flow): flow.cancel()
        case .external(let flow): flow.cancel()
        case .stored, .unreadable, nil: break
        }
    }

    /// Leaves the cover from anywhere: stops the flow and with it the sound, then goes home.
    func close() {
        stopFlow()
        isRenaming = false
        path = []
        outcome = nil
        content = nil
    }
}
