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
/// Kit decides everything acoustic, and `OptimizeRules` and the store's optimisation calls (both in `ResoniqStore`)
/// decide routes, baselines, what a layout change closes and what counts as declined; this calls them and navigates.
///
/// **Measure tab.** "Measure from my seat" is a request on `MeasureCoordinator` (`startMeasurement()`) after switching
/// to its tab with `showTab`, which `RootView` sets. When Measure keeps a conclusive report it calls `onSeatKept` once
/// its cover has finished dismissing; this coordinator sets that in `init`. After a move it compares the new
/// measurement with the one before and shows Before and after, presented when this tab is on screen; when this
/// coordinator started the measurement it takes the person back to Optimize.
///
/// **Covers.** `cover` is what was asked for; `isCoverShowing` is what the system actually presented (set when the
/// cover's content appears, cleared when it has dismissed). Work that must wait for a cover to leave runs from the
/// dismissal, never after a timer, and a cover that was asked for but never presented is dropped when the tab appears
/// again, so a home action is never ignored for good.
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
        /// How sure the plan is of where the speaker went; nil when it was marked on the spot.
        var placementNote: String?
    }

    enum Cover {
        case scan
        case manualRoom(initial: ManualRoom?)
        case layout(LayoutDraft)
        case guide(ARRequest)
        case verification(Verification)
    }

    /// The cover asked for.
    private(set) var cover: Cover?
    /// Whether a cover is actually on screen: from its content appearing to the end of its dismissal.
    private(set) var isCoverShowing = false
    /// Changes whenever a different screen takes the cover, so each starts fresh.
    private(set) var coverID = UUID()
    var alert: OptimizeAlert?
    let sources: OptimizeSources

    /// How this tab asks the shell to show another tab. `RootView` sets it.
    @ObservationIgnored var showTab: (AppTab) -> Void = { _ in }

    @ObservationIgnored private let store: ResoniqStore
    @ObservationIgnored private let measure: MeasureCoordinator
    /// RoomPlan's temporary export for a scan not yet confirmed. Imported into the store's scan folder only when the
    /// layout is confirmed; removed when the cover closes without confirming.
    @ObservationIgnored private var pendingScanExport: URL?
    /// What to do once the cover has dismissed (start the seat measurement, open the layout).
    @ObservationIgnored private var afterDismiss: (() -> Void)?
    /// The Measure flow this coordinator started, so a kept measurement from it returns to Optimize.
    @ObservationIgnored private var measureFlowID: UUID?
    /// Before and after, waiting for this tab to be on screen.
    @ObservationIgnored private var pendingVerification: Verification?
    @ObservationIgnored private var isTabVisible = false

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
        OptimizeHomeState.make(OptimizeHomeInput(store.optimizeStatus(in: context?.system))).suggestion
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
            if let suggestion, moveMyself(suggestion) != nil { startSeatMeasurement() }
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

    /// The scan finished: keep its temporary export until the layout is confirmed, then Confirm layout with the room
    /// as a guess. A scan that finishes after its cover closed is thrown away with its file.
    func scanned(_ result: RoomScanResult) {
        guard case .scan = cover else {
            if let url = result.usdzURL { try? FileManager.default.removeItem(at: url) }
            return
        }
        discardPendingScan()
        pendingScanExport = result.usdzURL
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

    /// "Looks right, measure the room": the scan's file is imported now, the layout is stored (closing an open
    /// optimisation the change makes stale), and a new room, or an edit no measurement matches, goes on to the seat
    /// measurement. A layout that was only edited, with a measurement that still matches it, just closes.
    func confirmLayout(_ layout: RoomModel) {
        guard case .layout(let draft) = cover, let (room, system) = context else { return }
        var scanFile: String?
        if let url = pendingScanExport, let files = store.scanFiles {
            do {
                scanFile = try files.importScan(from: url)
            } catch {
                alert = OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.scanNotKept)
            }
        }
        do {
            try store.confirmLayout(layout, for: room, scanFile: scanFile)
        } catch {
            if let scanFile { store.scanFiles?.delete(scanFile) }
            alert = saveFailed
            return
        }
        discardPendingScan()
        switch OptimizeRules.afterLayoutConfirmed(isNewRoom: draft.isGuess, progress: store.progress(in: system)) {
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

    /// The speaker is in place: the layout takes the pose the person last marked (not the suggestion's target), as the
    /// Kit places it, confirmed because it was seen there; it is stored with the move.
    func placed(_ placement: ARPlacement, in request: ARRequest) {
        guard case .guide(let current) = cover, current.optimization === request.optimization else { return }
        guard let layout = OptimizeRules.moved(
            request.room, speaker: request.suggestion.speakerID, to: placement.pose, isConfirmed: true)
        else {
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

    /// "Fix the layout" from the AR guide, when the marks do not agree with the plan: Confirm layout on the stored one.
    func fixLayout(from request: ARRequest) {
        guard case .guide(let current) = cover, current.optimization === request.optimization else { return }
        closeCover { [self] in perform(.editLayout) }
    }

    /// The optimisation for the suggestion (the store carries on with the open one or begins one from the baseline).
    /// Nil, with an alert, when it cannot.
    private func optimization(for suggestion: PlacementSuggestion, in system: SoundSystem) -> Optimization? {
        do {
            return try store.optimization(for: suggestion, in: system)
        } catch StoreError.notMeasured {
            alert = OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.noSeatMeasurement)
        } catch {
            alert = saveFailed
        }
        return nil
    }

    /// "I'll move it myself": the suggestion's target pose is stored as where the person means to put the speaker, not
    /// confirmed, because nobody saw it go there.
    private func moveMyself(_ suggestion: PlacementSuggestion) -> Optimization? {
        guard let (room, system) = context, let layout = storedLayout(of: room) else {
            alert = OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.roomUnreadable)
            return nil
        }
        guard let optimization = optimization(for: suggestion, in: system) else { return nil }
        guard let moved = OptimizeRules.moved(layout, speaker: suggestion.speakerID, to: suggestion.to, isConfirmed: false)
        else {
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

    /// Measure kept a conclusive seat report and its cover has gone. When it is the second measurement of a move
    /// (`ResoniqStore.verifies`), compare it with the first, store both, and show Before and after. Otherwise, when
    /// this coordinator started the measurement, go back to Optimize, whose home reads the store.
    private func seatKept(_ measurement: SeatMeasurement) {
        let startedHere = measureFlowID == measure.contentID
        measureFlowID = nil
        guard let system = context?.system else { return }
        guard let optimization = store.currentOptimization(in: system), store.verifies(measurement, optimization) else {
            if startedHere { showTab(.optimize) }
            return
        }
        guard let before = optimization.seatBefore?.report, let after = measurement.report,
              let suggestion = optimization.suggestion
        else {
            alert = OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.couldNotCompare)
            showTab(.optimize)
            return
        }
        let comparison = SeatComparison.compare(
            before: before, after: after, targeting: OptimizeRules.targets(of: suggestion, in: before))
        do {
            try store.recordVerification(optimization, after: measurement, comparison: comparison)
        } catch {
            alert = saveFailed
            showTab(.optimize)
            return
        }
        guard let verification = verification(of: optimization) else { return }
        pendingVerification = verification
        showTab(.optimize)
        presentPendingVerification()
    }

    // MARK: Before and after

    private func verification(of optimization: Optimization) -> Verification? {
        guard let before = optimization.seatBefore?.report, let after = optimization.seatAfter?.report,
              let comparison = optimization.comparison
        else { return nil }
        let placement = both(optimization.suggestion, optimization.layoutAfter).flatMap { OptimizeRules.placement(of: $0.0, in: $0.1) }
        return Verification(
            optimization: optimization, comparison: comparison, before: before, after: after,
            placementNote: placement.flatMap(OptimizeText.verifyNote))
    }

    /// Before and after, once this tab is on screen and nothing else covers it.
    private func presentPendingVerification() {
        guard isTabVisible, cover == nil, let verification = pendingVerification else { return }
        pendingVerification = nil
        show(.verification(verification))
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
    /// speaker, so it says so; the alert shows on the home once the cover has gone. Refused when the plan changed
    /// since the move.
    func putBack(_ verification: Verification) {
        guard case .verification(let current) = cover, current.optimization === verification.optimization else { return }
        do {
            try store.putBack(verification.optimization)
        } catch StoreError.layoutChanged {
            alert = OptimizeAlert(title: OptimizeText.putBackTitle, message: OptimizeText.putBackUnavailable)
            return
        } catch {
            alert = saveFailed
            return
        }
        alert = OptimizeAlert(title: OptimizeText.putBackTitle, message: OptimizeText.putBackNotice)
        closeCover()
    }

    // MARK: Covers

    private func show(_ cover: Cover) {
        coverID = UUID()
        self.cover = cover
    }

    /// Leaves the cover from anywhere. The screens cancel what they were doing when they disappear (the scan, the AR
    /// session). `then` runs once the cover has dismissed, or at once when none is on screen.
    func closeCover(then work: (() -> Void)? = nil) {
        discardPendingScan()
        guard cover != nil, isCoverShowing else {
            cover = nil
            work?()
            return
        }
        afterDismiss = work
        cover = nil
    }

    /// The cover's content appeared: the system presented it.
    func coverAppeared() {
        isCoverShowing = true
    }

    /// The system finished dismissing the cover.
    func coverDismissed() {
        isCoverShowing = false
        let work = afterDismiss
        afterDismiss = nil
        work?()
        presentPendingVerification()
    }

    /// The tab is on screen. A cover asked for but never presented (a presentation the system dropped) is let go, so
    /// it cannot block the home; then Before and after, if it is waiting.
    func tabAppeared() {
        isTabVisible = true
        if cover != nil, !isCoverShowing {
            cover = nil
            afterDismiss = nil
        }
        presentPendingVerification()
    }

    func tabDisappeared() {
        isTabVisible = false
    }

    /// The scene left the foreground: the scan and the AR guide stop (their covers close; an optimisation stays as
    /// suggested), and the Measure tab's own hook stops its sound.
    func suspend() {
        switch cover {
        case .scan, .guide: closeCover()
        default: break
        }
    }

    /// "Delete all results" or "Delete everything": whatever this tab holds about deleted data goes, and it is back on
    /// its home.
    func resetAfterDataDeletion() {
        pendingVerification = nil
        measureFlowID = nil
        alert = nil
        closeCover()
    }

    private func discardPendingScan() {
        if let url = pendingScanExport { try? FileManager.default.removeItem(at: url) }
        pendingScanExport = nil
    }

    private var saveFailed: OptimizeAlert {
        OptimizeAlert(title: OptimizeText.alertTitle, message: OptimizeText.saveFailed)
    }
}

private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
