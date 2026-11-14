import Foundation
import Observation
import ResoniqDiagnostics
import ResoniqRoom
import ResoniqStore
import SwiftData
import SwiftUI

/// Everything the Measure tab does besides drawing: which flow or live view is on screen, what was kept, whether The
/// numbers are pushed. It decides navigation and what to save; every judgement about the seat comes from the Kit.
@MainActor
@Observable
final class MeasureCoordinator {
    /// What the full-screen cover shows. Nil: the cover is not shown.
    enum Content {
        /// A measurement, from Sit and aim to its end.
        case measurement(SeatFlow)
        /// A measurement whose sound another device plays: the file, then Three spots, then the same result.
        case externalMeasurement(ExternalSeatFlow)
        /// "Watch the sound live".
        case live(LiveSpectrumModel)
    }

    /// Pushed on the tab's navigation stack.
    nonisolated enum Route: Hashable {
        case numbers
        /// The list of earlier measurements to compare the latest with.
        case earlier
        /// Two measurements over each other.
        case comparison
    }

    /// Two kept measurements being compared: the latest, the earlier ones to pick from, the one picked and the Kit's
    /// comparison of the two (`SeatComparison.compare`).
    struct Comparing {
        var latest: KeptSeat
        var earlier: [KeptSeat]
        var picked: KeptSeat?
        var comparison: ComparisonReport?
    }

    /// The report The numbers is showing, and when it was measured.
    struct Numbers {
        var report: SeatReport
        var date: Date
    }

    private(set) var content: Content?
    /// Changes whenever a different flow or view takes the cover, so its screens start fresh.
    private(set) var contentID = UUID()
    var path: [Route] = []
    private(set) var numbers: Numbers?
    private(set) var comparing: Comparing?
    /// A measurement that finished but is not kept: one that could not conclude, or one the store could not save.
    /// Measure home shows it until the next measurement.
    private(set) var unsaved: MeasureSummary?
    /// The store could not save a conclusive measurement: the alert that says so, in the product's voice. Set once
    /// the cover has gone; `RootView` shows it.
    var saveFailedAlert: Bool = false

    /// Called with the stored measurement each time a conclusive seat report was kept, once the cover has finished
    /// dismissing (`coverDismissed`), so whoever presents next does not present over a cover that is still leaving.
    /// The Optimize coordinator sets it, to compare a measurement made after a move.
    @ObservationIgnored var onSeatKept: ((SeatMeasurement) -> Void)?

    /// What the cover's dismissal hands on: the kept measurement, or that the save failed.
    @ObservationIgnored private var pendingKept: SeatMeasurement?
    @ObservationIgnored private var pendingSaveFailure = false

    @ObservationIgnored private let store: ResoniqStore
    @ObservationIgnored private let audio: AudioEnvironment

    init(store: ResoniqStore, audio: AudioEnvironment) {
        self.store = store
        self.audio = audio
        shownSystem = (try? store.defaultContext())?.system.persistentModelID
    }

    /// The system the numbers and the unsaved measurement belong to.
    @ObservationIgnored private var shownSystem: PersistentIdentifier?

    /// The rooms sheet or Settings closed: when the selected system is another one, drops what belonged to the
    /// system before (an unsaved measurement, The numbers).
    func selectionMayHaveChanged() {
        let current = system?.persistentModelID
        guard current != shownSystem else { return }
        shownSystem = current
        comparing = nil
        unsaved = nil
        numbers = nil
        path = []
    }

    // MARK: Reading

    private var system: SoundSystem? { try? store.defaultContext().system }

    /// The room's name, for Sit and aim.
    var roomName: String { system?.room?.name ?? StoreText.defaultRoomName }

    /// The room's size from its stored layout, when it has one: it lets the diagnosis say the room is the cause.
    private func roomHint(for system: SoundSystem?) -> RoomHint? {
        guard let room = system?.room, let layout = try? store.layout(of: room),
              let size = RoomGeometry.dimensions(of: layout) else { return nil }
        return RoomHint(width: size.width, length: size.length, height: size.height)
    }

    // MARK: Opening

    /// Starts a seat measurement from home: opens the flow on Sit and aim. Ignored while a flow or the live view is
    /// already on screen, so a second measurement cannot start while one is finishing.
    func startMeasurement() {
        guard content == nil else { return }
        let system = system
        let flow = SeatFlow(kind: system?.kind ?? .stereoPair, roomHint: roomHint(for: system), audio: audio)
        unsaved = nil
        show(.measurement(flow))
    }

    /// Starts a seat measurement whose sound another device plays, from its file. Ignored while a flow or the live view
    /// is already on screen.
    func startExternalMeasurement() {
        guard content == nil else { return }
        show(.externalMeasurement(makeExternalFlow()))
        unsaved = nil
    }

    /// "My speakers can't play from this iPhone" and "Play the test sound from another device": the measurement on screen
    /// carries on as one whose sound another device plays, from its file. The one it leaves is stopped.
    func switchToExternal(from flow: SeatFlow) {
        guard case .measurement(let current) = content, current === flow else { return }
        flow.cancel()
        show(.externalMeasurement(makeExternalFlow()))
    }

    private func makeExternalFlow() -> ExternalSeatFlow {
        let system = system
        return ExternalSeatFlow(kind: system?.kind ?? .stereoPair, roomHint: roomHint(for: system), audio: audio)
    }

    /// "Watch the sound live".
    func watchLive() {
        guard content == nil else { return }
        show(.live(LiveSpectrumModel(audio: audio)))
    }

    /// "Show the numbers".
    func showNumbers(_ report: SeatReport, date: Date) {
        numbers = Numbers(report: report, date: date)
        if path != [.numbers] { path = [.numbers] }
    }

    func closeNumbers() {
        path = []
    }

    /// "Compare with an earlier one": the list of earlier measurements, with `latest` to compare them with.
    func showEarlier(latest: KeptSeat, earlier: [KeptSeat]) {
        guard !earlier.isEmpty else { return }
        comparing = Comparing(latest: latest, earlier: earlier)
        path = [.earlier]
    }

    /// An earlier measurement was picked: the Kit compares it with the latest. With no problem named as a target, the
    /// earlier report's own extremes are the targets, so every one of its problems is looked for in the latest.
    func pickEarlier(_ picked: KeptSeat) {
        guard var comparing else { return }
        comparing.picked = picked
        comparing.comparison = SeatComparison.compare(
            before: picked.report, after: comparing.latest.report, targeting: picked.report.extremes
        )
        self.comparing = comparing
        path = [.earlier, .comparison]
    }

    /// Back from the comparison to the list, or from the list to home.
    func closeComparison() {
        if !path.isEmpty { path.removeLast() }
    }

    private func show(_ content: Content) {
        contentID = UUID()
        self.content = content
    }

    // MARK: Finishing

    /// The flow produced a report. A conclusive one is kept in the selected system; one that could not conclude is not
    /// kept and Measure home shows it with what went wrong. A conclusive one the store could not save stays on Measure
    /// home too, unsaved, and an alert says so once the cover has gone. Either way the cover closes onto Measure home,
    /// and a kept measurement is handed on from the dismissal. Once per flow: a report from a flow that is no longer
    /// the one on screen is ignored.
    func measurementFinished(_ report: SeatReport, from flow: SeatFlow) {
        guard case .measurement(let current) = content, current === flow else { return }
        keep(report)
    }

    /// The external flow produced a report: kept exactly like a normal measurement (`measurementFinished`).
    func measurementFinished(_ report: SeatReport, from flow: ExternalSeatFlow) {
        guard case .externalMeasurement(let current) = content, current === flow else { return }
        keep(report)
    }

    private func keep(_ report: SeatReport) {
        var kept: SeatMeasurement?
        if report.isConclusive, let system {
            do {
                kept = try store.keep(report, in: system)
            } catch {
                pendingSaveFailure = true
            }
        }
        unsaved = kept == nil ? MeasureSummary(report: report, date: .now) : nil
        pendingKept = kept
        close()
        // The cover closes onto Measure home; say what was found, since nothing on screen moves VoiceOver there.
        let verdict = report.verdict
        Task {
            try? await Task.sleep(for: .seconds(1))
            AccessibilityNotification.Announcement(verdict).post()
        }
    }

    // MARK: Leaving

    /// Leaves the cover from anywhere: stops the flow or the live stream, and with them the sound, then goes home.
    func close() {
        stopWork()
        content = nil
    }

    /// The system finished dismissing the cover: hand on what the measurement left (a kept measurement to Optimize, a
    /// failed save to the alert).
    func coverDismissed() {
        if pendingSaveFailure {
            pendingSaveFailure = false
            saveFailedAlert = true
        }
        guard let kept = pendingKept else { return }
        pendingKept = nil
        onSeatKept?(kept)
    }

    /// The scene left the foreground: stop anything that plays or listens. A measurement stops and its screen says why
    /// (the flow's `suspend()`); the live view stops until it is shown again.
    func suspend() {
        switch content {
        case .measurement(let flow): flow.suspend()
        case .externalMeasurement(let flow): flow.suspend()
        case .live(let model): model.stop()
        case nil: break
        }
    }

    /// "Delete all results" or "Delete everything": the cover closes, and an unsaved result, a comparison, The numbers
    /// and anything waiting to be handed on are dropped, back to Measure home.
    func resetAfterDataDeletion() {
        close()
        pendingKept = nil
        pendingSaveFailure = false
        saveFailedAlert = false
        comparing = nil
        unsaved = nil
        numbers = nil
        path = []
        shownSystem = system?.persistentModelID
    }

    private func stopWork() {
        switch content {
        case .measurement(let flow): flow.cancel()
        case .externalMeasurement(let flow): flow.cancel()
        case .live(let model): model.stop()
        case nil: break
        }
    }
}
