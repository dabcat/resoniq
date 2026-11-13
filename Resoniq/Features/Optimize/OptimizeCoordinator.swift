import Foundation
import Observation
import ResoniqDiagnostics
import ResoniqRoom
import ResoniqStore

/// Where the scan and the AR guide get their sensors from. The app uses the real ones; debug entries use the
/// scripted ones, because RoomPlan and ARKit cannot run in the simulator.
struct OptimizeSources {
    var scanReadiness: @MainActor () -> ScanReadiness
    var makeScanSource: @MainActor () -> any RoomScanSource
    var arReadiness: @MainActor () -> ScanReadiness
    var makeARSource: @MainActor () -> any ARGuidanceSource
    var makeARHaptics: @MainActor () -> any ARGuidanceHaptics

    static let live = OptimizeSources(
        scanReadiness: ScanCapability.readiness,
        makeScanSource: ScanCapability.makeSource,
        arReadiness: ARGuidanceCapability.readiness,
        makeARSource: ARGuidanceCapability.makeSource,
        makeARHaptics: ARGuidanceCapability.makeHaptics)
}

/// A plain alert in the product's voice.
struct OptimizeAlert: Equatable {
    var title: String
    var message: String
}

/// Everything the Optimize tab does besides drawing: which full-screen cover is up (scan, manual entry, Confirm layout,
/// the AR guide, Before and after), what is stored at each step, and how the tab hands over to Measure and back. The
/// Kit decides everything acoustic; the routes and the small decisions are `OptimizeRules`.
///
/// **Measure tab.** "Measure from my seat" is a request on `MeasureCoordinator` (`startMeasurement()`) after switching
/// to its tab with `showTab`, which `RootView` sets. When Measure keeps a conclusive report it calls `onSeatKept`, which
/// this coordinator sets in `init`: it compares the new measurement with the one before the move, when there was a
/// move, and shows Before and after; when this coordinator started the measurement it takes the person back to Optimize.
@MainActor
@Observable
final class OptimizeCoordinator {
    // MARK: What a cover shows

    struct LayoutDraft {
        var room: RoomModel
        /// The speakers and seat are guesses (a scan or a room entered by hand), not a stored layout being edited.
        var isGuess: Bool
    }

    struct ARRequest {
        var suggestion: PlacementSuggestion
        var room: RoomModel
        var optimization: Optimization
    }

    struct Verification {
        var optimization: Optimization
        var comparison: ComparisonReport
        var before: SeatReport
        var after: SeatReport
    }

    enum Cover {
        case scan
        case manualRoom(initial: ManualRoom?)
        case layout(LayoutDraft)
        case guide(ARRequest)
        case verification(Verification)
    }

    private(set) var cover: Cover?
    /// Changes whenever a different screen takes the cover, so each starts fresh.
    private(set) var coverID = UUID()
    var alert: OptimizeAlert?
    let sources: OptimizeSources

    /// How this tab asks the shell to show another tab. `RootView` sets it.
    @ObservationIgnored var showTab: (AppTab) -> Void = { _ in }

    @ObservationIgnored private let store: ResoniqStore
    @ObservationIgnored private let measure: MeasureCoordinator
    /// The scan file imported for a scan not yet confirmed; deleted when the cover closes without confirming.
    @ObservationIgnored private var pendingScanFile: String?
    /// What to do once the cover is gone (switch tab, show an alert): presenting over a cover that is still leaving
    /// is dropped by the system.
    @ObservationIgnored private var afterDismiss: (() -> Void)?
    /// The Measure flow this coordinator started, so a kept measurement from it returns to Optimize.
    @ObservationIgnored private var measureFlowID: UUID?

    init(store: ResoniqStore, measure: MeasureCoordinator, sources: OptimizeSources = .live) {
        self.store = store
        self.measure = measure
        self.sources = sources
        measure.onSeatKept = { [weak self] measurement in self?.seatKept(measurement) }
    }

    // MARK: Reading

    /// The room's name, for Confirm layout.
    var roomName: String { context?.room.name ?? StoreText.defaultRoomName }

    private var context: (room: Room, system: SoundSystem)? { try? store.defaultContext() }

    private func storedLayout(of room: Room) -> RoomModel? {
        (try? store.layout(of: room)) ?? nil
    }

    private var progress: OptimizeProgress {
        context.map { store.progress(in: $0.system) } ?? OptimizeProgress()
    }

    /// The suggestion the home is showing, when it shows one.
    func currentSuggestion() -> PlacementSuggestion? {
        OptimizeHomeState.make(.read(from: store, system: context?.system)).suggestion
    }

    // MARK: Home actions

    func scan() { perform(.scan) }
    func enterByHand() { perform(.enterByHand) }
    func editLayout() { perform(.editLayout) }
    func measureFromSeat() { perform(.measure) }
    func showVerification() { perform(.showVerification) }

    func guideInAR(_ suggestion: PlacementSuggestion) { perform(.guideInAR, suggestion: suggestion) }
    func moveMyself(_ suggestion: PlacementSuggestion) { perform(.moveMyself, suggestion: suggestion) }

    /// One entry for every home action: ignored while a cover is up (a second flow cannot start while one is
    /// finishing), then routed by `OptimizeRules` from what the store holds.
    private func perform(_ action: OptimizeRules.HomeAction, suggestion: PlacementSuggestion? = nil) {
        guard cover == nil else { return }
        switch OptimizeRules.route(for: action, progress: progress) {
        case .scan:
            show(.scan)
        case .manualRoom:
            show(.manualRoom(initial: nil))
        case .editStoredLayout:
            guard let room = context?.room, let layout = storedLayout(of: room) else {
                alert = OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.roomUnreadable)
                return
            }
            show(.layout(LayoutDraft(room: layout, isGuess: false)))
        case .seatMeasurement:
            startSeatMeasurement()
        case .guideInAR:
            if let suggestion { startGuide(suggestion) }
        case .moveThenMeasure:
            if let suggestion, move(suggestion, to: suggestion.to) != nil { startSeatMeasurement() }
        case .verification:
            if let optimization = context.flatMap({ store.currentOptimization(in: $0.system) }),
               let verification = verification(of: optimization) {
                show(.verification(verification))
            }
        case .nothing:
            break
        }
    }

    // MARK: Scan and manual entry

    /// The scan finished: keep its file when the store has a place for it, then Confirm layout with the room as a guess.
    func scanned(_ result: RoomScanResult) {
        guard case .scan = cover else { return }
        discardPendingScan()
        if let url = result.usdzURL, let files = store.scanFiles {
            do {
                pendingScanFile = try files.importScan(from: url)
                try? FileManager.default.removeItem(at: url)
            } catch {
                alert = OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.scanNotKept)
            }
        }
        show(.layout(LayoutDraft(room: OptimizeRules.withGuess(result.room), isGuess: true)))
    }

    /// "No LiDAR? Enter the room by hand" from the scan, or "Fix a wall" on a hand-entered room.
    func showManualEntry(starting initial: ManualRoom? = nil) {
        switch cover {
        case .scan, .layout: break
        default: return
        }
        discardPendingScan()
        show(.manualRoom(initial: initial))
    }

    func manualRoomMade(_ room: RoomModel) {
        guard case .manualRoom = cover else { return }
        show(.layout(LayoutDraft(room: room, isGuess: true)))
    }

    /// "Scan again" from Confirm layout.
    func scanAgain() {
        guard case .layout = cover else { return }
        discardPendingScan()
        show(.scan)
    }

    /// The hand-entered room's sizes, for reopening manual entry from "Fix a wall".
    func manualRoom(of layout: RoomModel) -> ManualRoom? {
        RoomGeometry.dimensions(of: layout).map { ManualRoom(width: $0.width, length: $0.length, height: $0.height) }
    }

    // MARK: Confirm layout

    /// "Looks right, measure the room": the layout is stored, and a new room (or an edit no measurement matches) goes on
    /// to the seat measurement. A layout that was only edited, with a measurement that already matches it, just closes.
    func confirmLayout(_ layout: RoomModel) {
        guard case .layout(let draft) = cover, let (room, system) = context else { return }
        do {
            try store.setLayout(layout, for: room, scanFile: pendingScanFile)
        } catch {
            alert = saveFailed
            return
        }
        pendingScanFile = nil
        let matches = store.progress(in: system).measured
        switch OptimizeRules.afterLayoutConfirmed(isNewRoom: draft.isGuess, measurementMatchesLayout: matches) {
        case .measure: closeCover { [self] in startSeatMeasurement() }
        case .close: closeCover()
        }
    }

    // MARK: AR

    private func startGuide(_ suggestion: PlacementSuggestion) {
        guard let (room, system) = context, let layout = storedLayout(of: room) else {
            alert = OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.roomUnreadable)
            return
        }
        guard let optimization = optimization(for: suggestion, in: system) else { return }
        show(.guide(ARRequest(suggestion: suggestion, room: layout, optimization: optimization)))
    }

    /// The speaker is in place: the layout takes the pose the guide reported, as the Kit places it, and is stored with
    /// the move.
    func placed(_ pose: PlanPose, in request: ARRequest) {
        guard case .guide(let current) = cover, current.optimization === request.optimization else { return }
        guard let layout = OptimizeRules.moved(request.room, speaker: request.suggestion.speakerID, to: pose) else {
            alert = OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.speakerMissing)
            return
        }
        do {
            try store.recordMove(request.optimization, newLayout: layout)
        } catch {
            alert = saveFailed
            return
        }
        closeCover()
    }

    /// "Can't move it": the suggestion is declined; the home shows the next one the advisor has.
    func declined(_ request: ARRequest) {
        guard case .guide(let current) = cover, current.optimization === request.optimization else { return }
        do {
            try store.decline(request.optimization)
        } catch {
            alert = saveFailed
            return
        }
        closeCover()
    }

    /// Starts an optimisation from the suggestion and the latest seat measurement, or carries on with the open one when
    /// it is the same suggestion. Nil, with an alert, when it cannot.
    private func optimization(for suggestion: PlacementSuggestion, in system: SoundSystem) -> Optimization? {
        if let current = store.currentOptimization(in: system),
           OptimizeRules.canReuse(outcome: current.outcome, stored: current.suggestion, for: suggestion) {
            return current
        }
        guard let before = store.latestSeatMeasurement(in: system) else {
            alert = OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.noSeatMeasurement)
            return nil
        }
        do {
            return try store.beginOptimization(suggestion: suggestion, in: system, before: before)
        } catch {
            alert = saveFailed
            return nil
        }
    }

    /// "I'll move it myself": the suggestion's target pose is stored as what the person says they will do.
    private func move(_ suggestion: PlacementSuggestion, to pose: PlanPose) -> Optimization? {
        guard let (room, system) = context, let layout = storedLayout(of: room) else {
            alert = OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.roomUnreadable)
            return nil
        }
        guard let optimization = optimization(for: suggestion, in: system) else { return nil }
        guard let moved = OptimizeRules.moved(layout, speaker: suggestion.speakerID, to: pose) else {
            alert = OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.speakerMissing)
            return nil
        }
        do {
            try store.recordMove(optimization, newLayout: moved)
        } catch {
            alert = saveFailed
            return nil
        }
        return optimization
    }

    // MARK: Measuring

    private func startSeatMeasurement() {
        guard measure.content == nil else { return }
        showTab(.measure)
        measure.startMeasurement()
        measureFlowID = measure.contentID
    }

    /// Measure kept a conclusive seat report. After a move it is the second measurement: compare it with the first,
    /// store both, and show Before and after. Otherwise, when this coordinator started the measurement, go back to
    /// Optimize, whose home reads the store.
    private func seatKept(_ measurement: SeatMeasurement) {
        let startedHere = measureFlowID == measure.contentID
        measureFlowID = nil
        guard let system = context?.system else { return }
        guard let optimization = store.currentOptimization(in: system),
              OptimizeRules.verifies(outcome: optimization.outcome)
        else {
            if startedHere { afterMeasureCoverLeaves { [self] in showTab(.optimize) } }
            return
        }
        guard let before = optimization.seatBefore?.report, let after = measurement.report,
              let suggestion = optimization.suggestion
        else {
            alert = OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.couldNotCompare)
            afterMeasureCoverLeaves { [self] in showTab(.optimize) }
            return
        }
        let comparison = SeatComparison.compare(
            before: before, after: after, targeting: OptimizeRules.targets(of: suggestion, in: before))
        do {
            try store.recordVerification(optimization, after: measurement, comparison: comparison)
        } catch {
            alert = saveFailed
            afterMeasureCoverLeaves { [self] in showTab(.optimize) }
            return
        }
        afterMeasureCoverLeaves { [self] in
            showTab(.optimize)
            if cover == nil, let verification = verification(of: optimization) { show(.verification(verification)) }
        }
    }

    /// Measure's cover is on its way out when it reports; give it the time the system takes to dismiss it before this
    /// tab shows something of its own.
    private func afterMeasureCoverLeaves(_ work: @escaping @MainActor () -> Void) {
        Task {
            try? await Task.sleep(for: OptimizeRules.dismissalAllowance)
            work()
        }
    }

    // MARK: Before and after

    private func verification(of optimization: Optimization) -> Verification? {
        guard let before = optimization.seatBefore?.report, let after = optimization.seatAfter?.report,
              let comparison = optimization.comparison
        else { return nil }
        return Verification(optimization: optimization, comparison: comparison, before: before, after: after)
    }

    /// "Keep this setup" and "Next suggestion": the optimisation is kept. The home then shows the next suggestion,
    /// from the measurement just made.
    func keep(_ verification: Verification) {
        guard case .verification(let current) = cover, current.optimization === verification.optimization else { return }
        do {
            try store.keep(verification.optimization)
        } catch {
            alert = saveFailed
            return
        }
        closeCover()
    }

    /// "Put the speaker back where it was": the stored layout returns to the one before. The app cannot move the
    /// speaker, so it says so.
    func putBack(_ verification: Verification) {
        guard case .verification(let current) = cover, current.optimization === verification.optimization else { return }
        do {
            try store.putBack(verification.optimization)
        } catch {
            alert = saveFailed
            return
        }
        closeCover { [self] in
            alert = OptimizeAlert(title: OptimizeText.putBackTitle, message: OptimizeText.putBackNotice)
        }
    }

    // MARK: Covers

    private func show(_ cover: Cover) {
        coverID = UUID()
        self.cover = cover
    }

    /// Leaves the cover from anywhere. The screens cancel what they were doing when they disappear (the scan, the AR
    /// session). `then` runs once the cover is gone.
    func closeCover(then work: (() -> Void)? = nil) {
        discardPendingScan()
        guard cover != nil else {
            work?()
            return
        }
        afterDismiss = work
        cover = nil
    }

    /// The system finished dismissing the cover.
    func coverDismissed() {
        let work = afterDismiss
        afterDismiss = nil
        work?()
    }

    /// The scene left the foreground: the scan and the AR guide stop (their covers close; an optimisation stays as
    /// suggested), and the Measure tab's own hook stops its sound.
    func suspend() {
        switch cover {
        case .scan, .guide: closeCover()
        default: break
        }
    }

    private func discardPendingScan() {
        if let name = pendingScanFile { store.scanFiles?.delete(name) }
        pendingScanFile = nil
    }

    private var saveFailed: OptimizeAlert {
        OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.saveFailed)
    }
}

extension OptimizeRules {
    /// How long a dismissed cover takes to leave before another tab presents its own.
    static let dismissalAllowance = Duration.milliseconds(450)
}
