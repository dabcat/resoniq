import Foundation
import ResoniqDiagnostics
import ResoniqRoom
import SwiftData
import Testing

@testable import ResoniqStore

/// The Optimize flow at store level: what home shows and what the next step works from after each thing a person can
/// do (move, measure, put back, rescan, edit), with the suggestion the real advisor gives for the fixture room.
@MainActor
struct OptimizeFlowTests {
    let store: ResoniqStore
    let room: Room
    let system: SoundSystem
    let layout = V2Fixtures.room()

    init() throws {
        store = ResoniqStore(container: try ResoniqStore.inMemoryContainer())
        (room, system) = try store.defaultContext()
    }

    /// Layout at t=100, the first measurement at t=200 (a 61 Hz dip, which the advisor's first suggestion answers).
    func measured() throws -> (first: SeatMeasurement, suggestion: PlacementSuggestion) {
        try store.confirmLayout(layout, for: room, date: Date(timeIntervalSince1970: 100))
        let first = try store.keep(V2Fixtures.dipReport("first"), in: system, date: Date(timeIntervalSince1970: 200))
        return (first, try V2Fixtures.suggestion(in: layout))
    }

    /// The advisor's suggestions for the status home would show, and the first one not turned down.
    func shownSuggestion() -> PlacementSuggestion? {
        let status = store.optimizeStatus(in: system)
        guard let layout = status.layout, let report = status.baseline else { return nil }
        let problems = report.placementTargets.map {
            AcousticProblem(frequency: Double($0.frequency), deviation: Double(abs($0.deviation)), kind: $0.kind == .peak ? .peak : .dip)
        }
        return OptimizeRules.firstOpen(PlacementAdvisor.suggestions(room: layout, problems: problems), declined: status.declined)
    }

    /// The layout the move leaves, as "I'll move it myself" or the AR guide store it.
    func movedLayout(_ suggestion: PlacementSuggestion, confirmed: Bool) throws -> RoomModel {
        try #require(OptimizeRules.moved(layout, speaker: suggestion.speakerID, to: suggestion.to, isConfirmed: confirmed))
    }

    // MARK: Put back

    @Test func afterPutBackHomeWorksFromTheMeasurementOfTheRestoredLayout() throws {
        let (first, suggestion) = try measured()
        #expect(shownSuggestion().map { OptimizeRules.isSame($0, suggestion) } == true)
        let optimization = try store.optimization(for: suggestion, in: system)
        #expect(optimization.seatBefore === first)
        try store.recordMove(optimization, newLayout: try movedLayout(suggestion, confirmed: true), date: Date(timeIntervalSince1970: 300))
        let after = try store.keep(V2Fixtures.dipReport("after"), in: system, date: Date(timeIntervalSince1970: 400))
        #expect(store.verifies(after, optimization))
        try store.recordVerification(optimization, after: after, comparison: V2Fixtures.comparison())
        #expect(store.canPutBack(optimization))
        try store.putBack(optimization, date: Date(timeIntervalSince1970: 500))

        // The latest measurement was made in the moved layout; the baseline is the one made where the speaker is now.
        #expect(store.latestSeatMeasurement(in: system) === after)
        #expect(store.baseline(in: system) === first)
        let status = store.optimizeStatus(in: system)
        #expect(status.progress == OptimizeProgress(scanned: true, measured: true))
        #expect(status.baseline == V2Fixtures.dipReport("first"))
        #expect(status.comparison == nil && status.placement == nil)

        // The move that was tried and put back is not offered again while the room and the problem are the same.
        #expect(status.declined.contains { OptimizeRules.isSame($0, suggestion) })
        let next = shownSuggestion()
        #expect(next.map { !OptimizeRules.isSame($0, suggestion) } ?? true)

        // A new optimisation starts from the baseline, not from the measurement made in the moved layout.
        if let next {
            let second = try store.optimization(for: next, in: system)
            #expect(second.seatBefore === first)
        }
    }

    @Test func aPutBackMoveComesBackOnceTheProblemOrTheLayoutChanges() throws {
        let (_, suggestion) = try measured()
        let optimization = try store.optimization(for: suggestion, in: system)
        try store.recordMove(optimization, newLayout: try movedLayout(suggestion, confirmed: true), date: Date(timeIntervalSince1970: 300))
        try store.putBack(optimization, date: Date(timeIntervalSince1970: 500))
        #expect(store.declinedSuggestions(in: system).count == 1)

        // Measured again in the restored layout, with the same dip: still turned down.
        try store.keep(V2Fixtures.dipReport("again"), in: system, date: Date(timeIntervalSince1970: 600))
        #expect(store.declinedSuggestions(in: system).count == 1)

        // A different problem: the earlier answer no longer applies.
        try store.keep(V2Fixtures.dipReport("other", at: 95), in: system, date: Date(timeIntervalSince1970: 700))
        #expect(store.declinedSuggestions(in: system).isEmpty)
    }

    @Test func aDeclineStaysUntilTheLayoutChanges() throws {
        let (_, suggestion) = try measured()
        try store.decline(try store.optimization(for: suggestion, in: system))
        #expect(store.declinedSuggestions(in: system).count == 1)
        #expect(shownSuggestion().map { !OptimizeRules.isSame($0, suggestion) } ?? true)
        // An edit of the layout: the room is not the one the suggestion was made for, and it is not measured.
        try store.confirmLayout(V2Fixtures.room(speakerX: -1.3), for: room)
        #expect(store.declinedSuggestions(in: system).isEmpty)
        #expect(!store.progress(in: system).measured)
    }

    // MARK: A rescan or an edit while moved

    @Test func aRescanWhileMovedSupersedesTheMoveAndCannotBePutBack() throws {
        let (_, suggestion) = try measured()
        let optimization = try store.optimization(for: suggestion, in: system)
        try store.recordMove(optimization, newLayout: try movedLayout(suggestion, confirmed: true), date: Date(timeIntervalSince1970: 300))
        #expect(store.progress(in: system) == OptimizeProgress(scanned: true, measured: true, moved: true))

        // A rescan: new walls, new guessed speakers (new ids).
        var rescan = V2Fixtures.room()
        rescan.source = .scanned
        try store.confirmLayout(rescan, for: room, date: Date(timeIntervalSince1970: 400))
        #expect(optimization.outcome == .superseded)
        #expect(store.currentOptimization(in: system) == nil)
        // The new room is not measured, and the next measurement is not a before and after of the old move.
        #expect(store.progress(in: system) == OptimizeProgress(scanned: true))
        let next = try store.keep(V2Fixtures.dipReport("in the new room"), in: system, date: Date(timeIntervalSince1970: 500))
        #expect(!store.verifies(next, optimization))
        // Putting back would overwrite the new scan with the layout from before it.
        #expect(!store.canPutBack(optimization))
        #expect(throws: StoreError.layoutChanged) { try store.putBack(optimization) }
        #expect(room.layout == rescan)
    }

    @Test func anEditThatIsExactlyTheMoveKeepsItOpenAndAnyOtherSupersedesIt() throws {
        let (_, suggestion) = try measured()
        let optimization = try store.optimization(for: suggestion, in: system)
        let moved = try movedLayout(suggestion, confirmed: false)
        try store.recordMove(optimization, newLayout: moved)
        #expect(store.optimizeStatus(in: system).placement == .notConfirmed)

        // The person drags the speaker to where it is: the same spot within the tolerance, now confirmed.
        var same = moved
        let index = try #require(same.speakers.firstIndex { $0.id == suggestion.speakerID })
        same.speakers[index].position.x += LayoutMatch.positionTolerance / 2
        same.speakers[index].isConfirmed = true
        try store.confirmLayout(same, for: room)
        #expect(optimization.outcome == .moved)
        #expect(store.progress(in: system).moved)

        // Then somewhere else: the move no longer describes the room.
        var elsewhere = same
        elsewhere.speakers[index].position.x += 0.2
        try store.confirmLayout(elsewhere, for: room)
        #expect(optimization.outcome == .superseded)
        #expect(!store.progress(in: system).moved)
    }

    @Test func anEditBeforeTheMoveSupersedesTheSuggestion() throws {
        let (_, suggestion) = try measured()
        let optimization = try store.optimization(for: suggestion, in: system)
        // An unchanged layout saved again leaves it open.
        try store.confirmLayout(layout, for: room)
        #expect(optimization.outcome == .suggested)
        try store.confirmLayout(V2Fixtures.room(speakerX: -1.3), for: room)
        #expect(optimization.outcome == .superseded)
    }

    // MARK: Moving

    @Test func moveMyselfIsRecordedAsNotConfirmedAndARAsWhereItWasMarked() throws {
        let (_, suggestion) = try measured()
        let mine = try movedLayout(suggestion, confirmed: false)
        #expect(OptimizeRules.placement(of: suggestion, in: mine) == .notConfirmed)
        #expect(mine.speaker(suggestion.speakerID)?.isConfirmed == false)

        let atTarget = try movedLayout(suggestion, confirmed: true)
        #expect(OptimizeRules.placement(of: suggestion, in: atTarget) == .atTarget)

        var short = suggestion.to
        short.position = short.position + PlanPoint(x: 0, z: -0.06)
        let marked = try #require(OptimizeRules.moved(layout, speaker: suggestion.speakerID, to: short, isConfirmed: true))
        #expect(OptimizeRules.placement(of: suggestion, in: marked) == .approximate)
    }

    @Test func aMeasurementVerifiesOnlyInTheLayoutTheMoveLeft() throws {
        let (_, suggestion) = try measured()
        let optimization = try store.optimization(for: suggestion, in: system)
        // Measured before anything moved: not a verification.
        let early = try store.keep(V2Fixtures.dipReport(), in: system)
        #expect(!store.verifies(early, optimization))
        try store.recordMove(optimization, newLayout: try movedLayout(suggestion, confirmed: false))
        let after = try store.keep(V2Fixtures.dipReport(), in: system)
        #expect(store.verifies(after, optimization))
    }

    @Test func anOptimizationNeedsABaseline() throws {
        try store.confirmLayout(layout, for: room)
        let suggestion = try V2Fixtures.suggestion(in: layout)
        #expect(throws: StoreError.notMeasured) { try store.optimization(for: suggestion, in: system) }
        // The same suggestion while it is only suggested is carried on, not begun again.
        try store.keep(V2Fixtures.dipReport(), in: system)
        let first = try store.optimization(for: suggestion, in: system)
        #expect(try store.optimization(for: suggestion, in: system) === first)
        #expect(store.optimizations(in: system).count == 1)
    }

    // MARK: Status

    @Test func statusForNothingStoredAndForAnUnreadableLayout() throws {
        #expect(store.optimizeStatus(in: nil).progress == OptimizeProgress())
        #expect(store.optimizeStatus(in: system).layout == nil)
        try store.confirmLayout(layout, for: room)
        room.layoutSchemaVersion = 99
        let status = store.optimizeStatus(in: system)
        #expect(status.layoutUnreadable && status.layout == nil)
        #expect(store.baseline(in: system) == nil)
    }
}

@MainActor
struct OptimizeRulesTests {
    @Test func routesOpenOnlyWhenTheStepBeforeHasData() {
        let none = OptimizeProgress()
        let scanned = OptimizeProgress(scanned: true)
        let measured = OptimizeProgress(scanned: true, measured: true)
        let moved = OptimizeProgress(scanned: true, measured: true, moved: true)
        let verified = OptimizeProgress(scanned: true, measured: true, moved: true, verified: true)
        #expect(OptimizeRules.route(for: .scan, progress: none) == .scan)
        #expect(OptimizeRules.route(for: .enterByHand, progress: none) == .manualRoom)
        #expect(OptimizeRules.route(for: .editLayout, progress: none) == .nothing)
        #expect(OptimizeRules.route(for: .editLayout, progress: scanned) == .editStoredLayout)
        #expect(OptimizeRules.route(for: .measure, progress: none) == .nothing)
        #expect(OptimizeRules.route(for: .measure, progress: scanned) == .seatMeasurement)
        #expect(OptimizeRules.route(for: .guideInAR, progress: scanned) == .nothing)
        #expect(OptimizeRules.route(for: .guideInAR, progress: measured) == .guideInAR)
        #expect(OptimizeRules.route(for: .guideInAR, progress: moved) == .nothing)
        #expect(OptimizeRules.route(for: .moveMyself, progress: measured) == .moveThenMeasure)
        #expect(OptimizeRules.route(for: .showVerification, progress: moved) == .nothing)
        #expect(OptimizeRules.route(for: .showVerification, progress: verified) == .verification)
    }

    @Test func afterALayoutANewRoomIsMeasuredAndAnEditClosesWhenStillMeasured() {
        let measured = OptimizeProgress(scanned: true, measured: true)
        #expect(OptimizeRules.afterLayoutConfirmed(isNewRoom: true, progress: measured) == .measure)
        #expect(OptimizeRules.afterLayoutConfirmed(isNewRoom: false, progress: measured) == .close)
        #expect(OptimizeRules.afterLayoutConfirmed(isNewRoom: false, progress: OptimizeProgress(scanned: true)) == .measure)
    }

    @Test func targetsAreTheSameKindAtTheSameFrequency() throws {
        let suggestion = try V2Fixtures.suggestion(in: V2Fixtures.room())
        #expect(OptimizeRules.targets(of: suggestion, in: V2Fixtures.dipReport()).count == 1)
        #expect(OptimizeRules.targets(of: suggestion, in: V2Fixtures.dipReport(at: 70)).isEmpty)
        #expect(OptimizeRules.targets(of: suggestion, in: V2Fixtures.seatReport()).isEmpty)
    }

    @Test func aClosedOptimizationNeverStaysOpen() {
        let room = V2Fixtures.room()
        for outcome in OptimizationOutcome.allCases where outcome.isClosed {
            #expect(!OptimizeRules.staysOpen(outcome: outcome, before: room, after: room, newLayout: room))
        }
        #expect(OptimizationOutcome.superseded.isClosed)
    }
}
