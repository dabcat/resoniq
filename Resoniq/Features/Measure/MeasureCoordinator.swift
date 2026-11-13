import Foundation
import Observation
import ResoniqDiagnostics
import ResoniqRoom
import ResoniqStore

/// Everything the Measure tab does besides drawing: which flow or live view is on screen, what was kept, whether The
/// numbers are pushed. It decides navigation and what to save; every judgement about the seat comes from the Kit.
@MainActor
@Observable
final class MeasureCoordinator {
    /// What the full-screen cover shows. Nil: the cover is not shown.
    enum Content {
        /// A measurement, from Sit and aim to its end.
        case measurement(SeatFlow)
        /// "Watch the sound live".
        case live(LiveSpectrumModel)
    }

    /// Pushed on the tab's navigation stack.
    nonisolated enum Route: Hashable {
        case numbers
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
    /// A measurement that finished but is not kept: one that could not conclude. Measure home shows it with what went
    /// wrong, until the next measurement.
    private(set) var unsaved: MeasureSummary?

    @ObservationIgnored private let store: ResoniqStore
    @ObservationIgnored private let audio: AudioEnvironment

    init(store: ResoniqStore, audio: AudioEnvironment) {
        self.store = store
        self.audio = audio
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

    private func show(_ content: Content) {
        contentID = UUID()
        self.content = content
    }

    // MARK: Finishing

    /// The flow produced a report. A conclusive one is kept in the selected system; one that could not conclude is not
    /// kept and Measure home shows it with what went wrong. Either way the cover closes onto Measure home. Once per
    /// flow: a report from a flow that is no longer the one on screen is ignored.
    func measurementFinished(_ report: SeatReport, from flow: SeatFlow) {
        guard case .measurement(let current) = content, current === flow else { return }
        var isKept = false
        if report.isConclusive, let system {
            isKept = (try? store.keep(report, in: system)) != nil
        }
        unsaved = isKept ? nil : MeasureSummary(report: report, date: .now)
        close()
    }

    // MARK: Leaving

    /// Leaves the cover from anywhere: stops the flow or the live stream, and with them the sound, then goes home.
    func close() {
        stopWork()
        content = nil
    }

    /// The scene left the foreground: stop anything that plays or listens. A measurement goes back to Sit and aim, the
    /// live view stops until it is shown again.
    func suspend() {
        stopWork()
    }

    private func stopWork() {
        switch content {
        case .measurement(let flow): flow.cancel()
        case .live(let model): model.stop()
        case nil: break
        }
    }
}
