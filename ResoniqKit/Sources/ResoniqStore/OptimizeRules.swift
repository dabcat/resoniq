import Foundation
import ResoniqDiagnostics
import ResoniqRoom

/// The Optimize tab's decisions, as plain functions of store and Kit values: which route a home action takes, what
/// follows a confirmed layout, whether an open optimisation survives a layout change, whether a suggestion was
/// already turned down, how a move was placed. The app's coordinator calls them and navigates; the store's
/// optimisation calls (`ResoniqStore+Optimize`) use them on the stored models. Tested on the Mac.
public enum OptimizeRules {
    // MARK: Routes

    /// What a person pressed on Optimize home.
    public enum HomeAction: Sendable, Equatable {
        case scan, enterByHand, editLayout, measure, guideInAR, moveMyself, showVerification, rescan
    }

    /// Where an action leads.
    public enum Route: Sendable, Equatable {
        case scan
        case manualRoom
        case editStoredLayout
        case seatMeasurement
        case guideInAR
        /// Record the suggestion as where the person means to put the speaker (not confirmed), then measure.
        case moveThenMeasure
        case verification
        /// The action does not apply to what the store holds (a stale button): do nothing.
        case nothing
    }

    /// The route for an action given what the store holds. A step is open only when the one before it has its data:
    /// there is nothing to edit or measure without a layout, nothing to move before a measurement, and nothing to
    /// show before a comparison.
    public static func route(for action: HomeAction, progress: OptimizeProgress) -> Route {
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
    public enum AfterLayout: Sendable, Equatable {
        case measure
        case close
    }

    /// A new room (a scan or entry by hand) is always measured next. An edit of the stored layout only closes when the
    /// tracker still counts the room as measured after the save (a measurement matches the saved layout, or an open
    /// move still has its baseline).
    public static func afterLayoutConfirmed(isNewRoom: Bool, progress: OptimizeProgress) -> AfterLayout {
        isNewRoom || !progress.measured ? .measure : .close
    }

    // MARK: Layout changes and open optimisations

    /// The layout an open optimisation expects the room to have: the one after the move once moved (or verified),
    /// else the one it started from. Nil for a closed one.
    public static func expectedLayout(outcome: OptimizationOutcome, before: RoomModel?, after: RoomModel?) -> RoomModel? {
        switch outcome {
        case .suggested: before
        case .moved, .verified: after
        case .kept, .putBack, .declined, .superseded: nil
        }
    }

    /// Whether an open optimisation stays open when the room's layout becomes `newLayout` (a rescan, an edit, entry by
    /// hand): only when the new layout is the one it expects (`LayoutMatch`). An edit that puts the speaker exactly
    /// where the recorded move put it keeps the move; anything else supersedes it, so the next measurement is not
    /// shown as the before and after of a move in a room that has changed since.
    public static func staysOpen(
        outcome: OptimizationOutcome, before: RoomModel?, after: RoomModel?, newLayout: RoomModel
    ) -> Bool {
        guard !outcome.isClosed, let expected = expectedLayout(outcome: outcome, before: before, after: after) else {
            return false
        }
        return LayoutMatch.matches(expected, newLayout)
    }

    /// "Put the speaker back" is offered only for a move not yet finished with, while the room still has the layout
    /// the move left (otherwise putting back would overwrite a newer scan or edit with an older layout).
    public static func canPutBack(outcome: OptimizationOutcome, after: RoomModel?, current: RoomModel?) -> Bool {
        guard outcome == .moved || outcome == .verified, let after, let current else { return false }
        return LayoutMatch.matches(after, current)
    }

    /// Whether a seat measurement made in `measuredIn` is the second measurement of an optimisation: the speaker was
    /// moved, and the measurement was made in the layout the move left.
    public static func verifies(outcome: OptimizationOutcome, after: RoomModel?, measuredIn: RoomModel?) -> Bool {
        guard outcome == .moved, let after, let measuredIn else { return false }
        return LayoutMatch.matches(after, measuredIn)
    }

    // MARK: Suggestions

    /// Whether an optimisation already begun can carry on with this suggestion rather than starting another: it is
    /// still only suggested, and the Kit's suggestion is the same speaker going between the same poses.
    public static func canReuse(outcome: OptimizationOutcome, stored: PlacementSuggestion?, for suggestion: PlacementSuggestion) -> Bool {
        guard outcome == .suggested, let stored else { return false }
        return isSame(stored, suggestion)
    }

    /// Two suggestions are the same move when they are for the same speaker and go between the same poses. Score and
    /// words can differ between two calls of the advisor on a changed room; the move is what a person declined.
    public static func isSame(_ a: PlacementSuggestion, _ b: PlacementSuggestion) -> Bool {
        a.speakerID == b.speakerID && a.from == b.from && a.to == b.to
    }

    public static func isDeclined(_ suggestion: PlacementSuggestion, among declined: [PlacementSuggestion]) -> Bool {
        declined.contains { isSame($0, suggestion) }
    }

    /// The first of the advisor's suggestions the person has not declined, in the advisor's order.
    public static func firstOpen(_ suggestions: [PlacementSuggestion], declined: [PlacementSuggestion]) -> PlacementSuggestion? {
        suggestions.first { !isDeclined($0, among: declined) }
    }

    /// Whether a suggestion turned down earlier (declined, or tried and put back) still stands turned down: the room
    /// has the layout it was made for, and the measured problem it answered is still there (for a suggestion from the
    /// room's shape, there is still no measured problem). Once either changes, the advisor's answer is new and may be
    /// offered again.
    public static func staysDeclined(
        _ suggestion: PlacementSuggestion, madeFor layout: RoomModel?, current: RoomModel?, baseline: SeatReport?
    ) -> Bool {
        guard let layout, let current, let baseline, LayoutMatch.matches(layout, current) else { return false }
        guard suggestion.problem != nil else { return baseline.placementTargets.isEmpty }
        return !targets(of: suggestion, in: baseline).isEmpty
    }

    /// The extremes of the first measurement the suggestion was for. A suggestion from a measured problem targets the
    /// bass extreme of the same kind at the same place; one from the room's shape names no problem, so nothing is
    /// targeted and the comparison reports every bass extreme as it was found.
    public static func targets(of suggestion: PlacementSuggestion, in report: SeatReport) -> [SeatExtreme] {
        guard let problem = suggestion.problem else { return [] }
        let wanted: SeatExtreme.Kind = problem.kind == .peak ? .peak : .dip
        let matching = report.placementTargets.filter {
            $0.kind == wanted && abs(Double($0.frequency) - problem.frequency) < frequencyTolerance
        }
        return Array(matching.prefix(1))
    }

    /// The suggestion's problem is copied from the report's extreme, so they agree to rounding, hertz.
    public static let frequencyTolerance = 0.5

    // MARK: Layout

    /// The layout with a speaker at a pose, as the Kit places it (it may nudge the speaker off a wall). `isConfirmed`
    /// says whether anyone saw the speaker there: true when it was marked in AR, false for "I'll move it myself", where
    /// the pose is only where the suggestion meant it to go. Nil when the layout has no such speaker.
    public static func moved(_ layout: RoomModel, speaker id: UUID, to pose: PlanPose, isConfirmed: Bool) -> RoomModel? {
        guard layout.speaker(id) != nil else { return nil }
        var result = layout.moving(id, to: pose.position).room
        result = result.rotating(id, to: pose.facing).room
        guard let index = result.speakers.firstIndex(where: { $0.id == id }) else { return nil }
        result.speakers[index].isConfirmed = isConfirmed
        return result
    }

    /// A scanned room has the walls and furniture but no speakers (RoomPlan cannot see them): the Kit guesses them.
    public static func withGuess(_ room: RoomModel) -> RoomModel {
        room.speakers.isEmpty && room.seats.isEmpty ? LayoutGuess.place(in: room) : room
    }

    /// How sure the stored layout after a move is of where the speaker went.
    public enum MovePlacement: Sendable, Equatable {
        /// Marked in AR within `MoveGuidance.positionTolerance` of the suggested spot.
        case atTarget
        /// Marked in AR, farther than the tolerance from the suggested spot: the layout has where it was marked.
        case approximate
        /// Nobody saw it: "I'll move it myself" stored the suggested spot as the intention.
        case notConfirmed
    }

    /// The placement of the moved speaker in the layout after a move; nil when the layout has no such speaker.
    public static func placement(of suggestion: PlacementSuggestion, in after: RoomModel) -> MovePlacement? {
        guard let speaker = after.speaker(suggestion.speakerID) else { return nil }
        guard speaker.isConfirmed else { return .notConfirmed }
        return speaker.position.distance(to: suggestion.to.position) > MoveGuidance.positionTolerance ? .approximate : .atTarget
    }
}
