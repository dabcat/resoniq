import Foundation
import ResoniqDiagnostics
import ResoniqRoom
import ResoniqStore

/// The Optimize tab's decisions as plain functions: which route follows an action, whether a measurement verifies an
/// optimisation, whether a suggestion was already declined. The Kit decides everything acoustic; these decide
/// navigation and what to store, so they can be read (and tested) without a view or a store.
nonisolated enum OptimizeRules {
    // MARK: Routes

    /// What a person pressed on Optimize home.
    enum HomeAction: Equatable {
        case scan, enterByHand, editLayout, measure, guideInAR, moveMyself, showVerification, rescan
    }

    /// Where an action leads.
    enum Route: Equatable {
        case scan
        case manualRoom
        case editStoredLayout
        case seatMeasurement
        case guideInAR
        /// Record the suggestion as the person's stated intention, then measure.
        case moveThenMeasure
        case verification
        /// The action does not apply to what the store holds (a stale button): do nothing.
        case nothing
    }

    /// The route for an action given what the store holds. A step is open only when the one before it has its data:
    /// there is nothing to edit or measure without a layout, nothing to move before a measurement, and nothing to
    /// show before a comparison.
    static func route(for action: HomeAction, progress: OptimizeProgress) -> Route {
        switch action {
        case .scan, .rescan: .scan
        case .enterByHand: .manualRoom
        case .editLayout: progress.scanned ? .editStoredLayout : .nothing
        case .measure: progress.scanned ? .seatMeasurement : .nothing
        case .guideInAR: progress.measured && !progress.moved ? .guideInAR : .nothing
        case .moveMyself: progress.measured && !progress.moved ? .moveThenMeasure : .nothing
        case .showVerification: progress.verified ? .verification : .nothing
        }
    }

    /// What follows "Looks right, measure the room" once the layout is saved.
    enum AfterLayout: Equatable {
        case measure
        case close
    }

    /// A new room (a scan or entry by hand) is always measured next. An edit of the stored layout only closes when a
    /// measurement already matches the layout that was just saved (the store's own `measured` says so).
    static func afterLayoutConfirmed(isNewRoom: Bool, measurementMatchesLayout: Bool) -> AfterLayout {
        isNewRoom || !measurementMatchesLayout ? .measure : .close
    }

    // MARK: Optimisations

    /// A seat measurement verifies the current optimisation only once the speaker was moved: the second measurement is
    /// the one that can say "improved".
    static func verifies(outcome: OptimizationOutcome?) -> Bool {
        outcome == .moved
    }

    /// Whether an optimisation already begun can carry on with this suggestion rather than starting another: it is
    /// still only suggested, and the Kit's suggestion is the same speaker going between the same poses.
    static func canReuse(outcome: OptimizationOutcome, stored: PlacementSuggestion?, for suggestion: PlacementSuggestion) -> Bool {
        guard outcome == .suggested, let stored else { return false }
        return isSame(stored, suggestion)
    }

    /// Two suggestions are the same move when they are for the same speaker and go between the same poses. Score and
    /// words can differ between two calls of the advisor on a changed room; the move is what a person declined.
    static func isSame(_ a: PlacementSuggestion, _ b: PlacementSuggestion) -> Bool {
        a.speakerID == b.speakerID && a.from == b.from && a.to == b.to
    }

    static func isDeclined(_ suggestion: PlacementSuggestion, among declined: [PlacementSuggestion]) -> Bool {
        declined.contains { isSame($0, suggestion) }
    }

    /// The first of the advisor's suggestions the person has not declined, in the advisor's order.
    static func firstOpen(_ suggestions: [PlacementSuggestion], declined: [PlacementSuggestion]) -> PlacementSuggestion? {
        suggestions.first { !isDeclined($0, among: declined) }
    }

    /// The extremes of the first measurement the suggestion was for. A suggestion from a measured problem targets the
    /// bass extreme of the same kind at the same place; one from the room's shape names no problem, so nothing is
    /// targeted and the comparison reports every bass extreme as it was found.
    static func targets(of suggestion: PlacementSuggestion, in report: SeatReport) -> [SeatExtreme] {
        guard let problem = suggestion.problem else { return [] }
        let wanted: SeatExtreme.Kind = problem.kind == .peak ? .peak : .dip
        let matching = report.placementTargets.filter {
            $0.kind == wanted && abs(Double($0.frequency) - problem.frequency) < frequencyTolerance
        }
        return Array(matching.prefix(1))
    }

    /// The suggestion's problem is copied from the report's extreme, so they agree to rounding.
    static let frequencyTolerance = 0.5

    // MARK: Layout

    /// The layout with a speaker at a pose, as the Kit places it (it may nudge the speaker off a wall), marked as
    /// confirmed because a person put it there. Nil when the layout has no such speaker.
    static func moved(_ layout: RoomModel, speaker id: UUID, to pose: PlanPose) -> RoomModel? {
        guard layout.speaker(id) != nil else { return nil }
        var result = layout.moving(id, to: pose.position).room
        result = result.rotating(id, to: pose.facing).room
        guard let index = result.speakers.firstIndex(where: { $0.id == id }) else { return nil }
        result.speakers[index].isConfirmed = true
        return result
    }

    /// A scanned room has the walls and furniture but no speakers (RoomPlan cannot see them): the Kit guesses them.
    static func withGuess(_ room: RoomModel) -> RoomModel {
        room.speakers.isEmpty && room.seats.isEmpty ? LayoutGuess.place(in: room) : room
    }
}

// MARK: - What the home reads

extension OptimizeHomeInput {
    /// Everything the home needs, read from the store for a system. A layout that cannot be read is reported, not
    /// hidden, and counts as no room.
    @MainActor
    static func read(from store: ResoniqStore?, system: SoundSystem?) -> OptimizeHomeInput {
        guard let store, let system else { return OptimizeHomeInput(layout: nil, seat: nil, progress: OptimizeProgress()) }
        var layout: RoomModel?
        var unreadable = false
        if let room = system.room {
            do { layout = try store.layout(of: room) } catch { unreadable = true }
        }
        guard !unreadable else {
            return OptimizeHomeInput(layout: nil, seat: nil, progress: OptimizeProgress(), layoutUnreadable: true)
        }
        let progress = store.progress(in: system)
        let latest = store.latestSeatMeasurement(in: system)
        // A suggestion declined for this measurement stays out of the way until there is a new one.
        let declined = store.optimizations(in: system)
            .filter { $0.outcome == .declined && $0.seatBefore != nil && $0.seatBefore?.persistentModelID == latest?.persistentModelID }
            .compactMap(\.suggestion)
        return OptimizeHomeInput(
            layout: layout,
            // A measurement made in another layout is not this room's.
            seat: progress.measured ? latest?.report : nil,
            progress: progress,
            comparison: store.currentOptimization(in: system)?.comparison,
            declined: declined)
    }
}
