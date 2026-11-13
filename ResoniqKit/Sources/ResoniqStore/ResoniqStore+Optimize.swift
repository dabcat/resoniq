import Foundation
import ResoniqDiagnostics
import ResoniqRoom
import SwiftData

/// Why a store call could not be made.
public enum StoreError: Error, Equatable, Sendable {
    /// The system is not in a room.
    case noRoom
    /// The room has no layout yet, so there is nothing to snapshot or move.
    case noLayout
    /// No seat measurement was made in the room's current layout, so there is nothing to improve on.
    case notMeasured
    /// The room's layout is no longer the one the move left (a rescan or an edit since), so putting the speaker back
    /// would overwrite it with an older one.
    case layoutChanged
}

/// Which of the four tracker steps have data behind them. A step is done only when its data exists.
///
/// - `scanned`: the room has a layout (scanned or entered by hand).
/// - `measured`: the room has a baseline (`ResoniqStore.baseline(in:)`: a seat measurement made in the current
///   layout, by `LayoutMatch`), or the open optimisation has been moved and keeps the measurement it started from, so
///   a move does not undo the measurement it was made from. A room with no layout counts any measurement.
/// - `moved`: the current optimisation has a layout after.
/// - `verified`: the current optimisation has a seat measurement after and a comparison.
///
/// The current optimisation is the latest one not yet kept, put back, declined or superseded.
public struct OptimizeProgress: Equatable, Sendable {
    public var scanned: Bool
    public var measured: Bool
    public var moved: Bool
    public var verified: Bool

    public init(scanned: Bool = false, measured: Bool = false, moved: Bool = false, verified: Bool = false) {
        self.scanned = scanned
        self.measured = measured
        self.moved = moved
        self.verified = verified
    }

    /// How many steps are done.
    public var completedCount: Int { [scanned, measured, moved, verified].filter { $0 }.count }
}

/// Everything Optimize home needs for one system, read from the store: plain values, so the app maps them and
/// decides nothing.
public struct OptimizeStatus: Sendable {
    /// The room's layout; nil when it has none or it cannot be read.
    public var layout: RoomModel?
    /// The stored layout exists and cannot be read.
    public var layoutUnreadable: Bool
    public var progress: OptimizeProgress
    /// The baseline's report: the seat measurement the next suggestion is computed from. Nil when the room was not
    /// measured in its current layout (or the report cannot be read).
    public var baseline: SeatReport?
    /// The current optimisation's comparison, once it has one.
    public var comparison: ComparisonReport?
    /// Suggestions turned down (declined, or tried and put back) that still stand turned down
    /// (`OptimizeRules.staysDeclined`).
    public var declined: [PlacementSuggestion]
    /// How the open move was placed, once moved.
    public var placement: OptimizeRules.MovePlacement?

    public init(
        layout: RoomModel? = nil, layoutUnreadable: Bool = false, progress: OptimizeProgress = OptimizeProgress(),
        baseline: SeatReport? = nil, comparison: ComparisonReport? = nil, declined: [PlacementSuggestion] = [],
        placement: OptimizeRules.MovePlacement? = nil
    ) {
        self.layout = layout
        self.layoutUnreadable = layoutUnreadable
        self.progress = progress
        self.baseline = baseline
        self.comparison = comparison
        self.declined = declined
        self.placement = placement
    }
}

extension ResoniqStore {
    // MARK: Layout

    /// The room's layout; nil when it has none; throws when the stored one cannot be read.
    public func layout(of room: Room) throws(ReportReadError) -> RoomModel? {
        try room.readLayout()
    }

    /// Stores the room's layout. With `scanFile`, the room refers to that file from now on and its earlier file, if
    /// any, is deleted (a rescan). Without it the reference stays (an edit of the plan), unless the layout was entered
    /// by hand (`RoomSource.manual`): a hand-entered room has no scan, so the old one is dropped and its file deleted.
    ///
    /// This is the raw write. A new or edited layout confirmed by the person goes through `confirmLayout`, which also
    /// closes an optimisation the change makes stale.
    public func setLayout(_ layout: RoomModel, for room: Room, scanFile: String? = nil, date: Date = .now) throws {
        let data = try JSONEncoder().encode(layout)
        let oldFile = room.scanFileName
        room.layoutData = data
        room.layoutSchemaVersion = layout.schemaVersion
        room.layoutUpdatedAt = date
        if let scanFile {
            room.scanFileName = scanFile
        } else if layout.source == .manual {
            room.scanFileName = nil
        }
        try context.save()
        if let oldFile, oldFile != room.scanFileName { scanFiles?.delete(oldFile) }
    }

    /// "Looks right": stores a new or edited layout and closes, as `superseded`, every open optimisation of the room's
    /// systems that the change makes stale (`OptimizeRules.staysOpen`): an edit that is exactly the recorded move
    /// keeps the move open; a rescan, entry by hand or any other edit does not.
    public func confirmLayout(_ layout: RoomModel, for room: Room, scanFile: String? = nil, date: Date = .now) throws {
        for system in room.systems {
            guard let current = currentOptimization(in: system) else { continue }
            if !OptimizeRules.staysOpen(
                outcome: current.outcome, before: current.layoutBefore, after: current.layoutAfter, newLayout: layout) {
                current.outcome = .superseded
            }
        }
        try setLayout(layout, for: room, scanFile: scanFile, date: date)
    }

    // MARK: Seat measurements

    /// Keeps a seat report, with a snapshot of the room's current layout (none when the room has none).
    @discardableResult
    public func keep(_ report: SeatReport, in system: SoundSystem, date: Date = .now) throws -> SeatMeasurement {
        let room = system.room
        let measurement = SeatMeasurement(
            date: date, reportData: try JSONEncoder().encode(report), reportSchemaVersion: report.schemaVersion,
            layoutData: room?.layoutData, layoutSchemaVersion: room?.layoutSchemaVersion ?? RoomModel.currentSchemaVersion)
        context.insert(measurement)
        measurement.system = system
        try context.save()
        return measurement
    }

    /// The most recent seat measurement ("Tuesday · 3 spots at your seat").
    public func latestSeatMeasurement(in system: SoundSystem) -> SeatMeasurement? {
        seatHistory(in: system).first
    }

    /// Every seat measurement, newest first.
    public func seatHistory(in system: SoundSystem) -> [SeatMeasurement] {
        system.seatMeasurements.sorted { $0.date > $1.date }
    }

    /// The measurement Optimize works from: the newest seat measurement made in the room's current layout (its
    /// snapshot matches by `LayoutMatch`). Not simply the latest: after "Put the speaker back" the latest was made
    /// in the moved layout, and a suggestion or a comparison from it would describe a room that is no longer there.
    /// A room with no layout takes the newest measurement; a layout that cannot be read has no baseline.
    public func baseline(in system: SoundSystem) -> SeatMeasurement? {
        let history = seatHistory(in: system)
        guard let room = system.room, let layoutData = room.layoutData else { return history.first }
        guard let current = room.layout else { return nil }
        return history.first { measurement in
            guard let snapshot = measurement.layoutData else { return false }
            if snapshot == layoutData { return true }
            return measurement.layout.map { LayoutMatch.matches($0, current) } ?? false
        }
    }

    /// Deletes a measurement. Optimisations that refer to it lose that reference (cleared here too, because the
    /// nullify rule does not update live objects).
    public func discard(_ measurement: SeatMeasurement) throws {
        for optimization in measurement.asBefore { optimization.seatBefore = nil }
        for optimization in measurement.asAfter { optimization.seatAfter = nil }
        context.delete(measurement)
        try context.save()
    }

    // MARK: Optimisations

    /// Starts an optimisation from a suggestion and the measurement it is meant to improve. Stores the room's
    /// current layout as the layout before. Throws `noRoom` or `noLayout`.
    @discardableResult
    public func beginOptimization(
        suggestion: PlacementSuggestion,
        in system: SoundSystem,
        before: SeatMeasurement,
        date: Date = .now
    ) throws -> Optimization {
        guard let room = system.room else { throw StoreError.noRoom }
        guard let layoutData = room.layoutData else { throw StoreError.noLayout }
        let optimization = Optimization(
            createdAt: date, suggestionData: try JSONEncoder().encode(suggestion),
            layoutBeforeData: layoutData, layoutBeforeVersion: room.layoutSchemaVersion)
        context.insert(optimization)
        optimization.system = system
        optimization.seatBefore = before
        try context.save()
        return optimization
    }

    /// The optimisation for a suggestion the home shows: the open one when it is the same suggestion still only
    /// suggested (`OptimizeRules.canReuse`), else a new one from the baseline. Throws `notMeasured` without a
    /// baseline, or what `beginOptimization` throws.
    public func optimization(for suggestion: PlacementSuggestion, in system: SoundSystem, date: Date = .now) throws -> Optimization {
        if let current = currentOptimization(in: system),
           OptimizeRules.canReuse(outcome: current.outcome, stored: current.suggestion, for: suggestion) {
            return current
        }
        guard let before = baseline(in: system) else { throw StoreError.notMeasured }
        return try beginOptimization(suggestion: suggestion, in: system, before: before, date: date)
    }

    /// The speaker was moved: stores the layout after and makes it the room's layout.
    public func recordMove(_ optimization: Optimization, newLayout: RoomModel, date: Date = .now) throws {
        guard let room = optimization.system?.room else { throw StoreError.noRoom }
        optimization.layoutAfterData = try JSONEncoder().encode(newLayout)
        optimization.layoutAfterVersion = newLayout.schemaVersion
        optimization.outcome = .moved
        try setLayout(newLayout, for: room, date: date)
    }

    /// Whether a seat measurement just kept is the second measurement of the optimisation
    /// (`OptimizeRules.verifies`): the speaker was moved and the measurement was made in the layout the move left.
    public func verifies(_ measurement: SeatMeasurement, _ optimization: Optimization) -> Bool {
        OptimizeRules.verifies(outcome: optimization.outcome, after: optimization.layoutAfter, measuredIn: measurement.layout)
    }

    /// The seat was measured again and compared.
    public func recordVerification(_ optimization: Optimization, after: SeatMeasurement, comparison: ComparisonReport) throws {
        optimization.seatAfter = after
        optimization.comparisonData = try JSONEncoder().encode(comparison)
        optimization.comparisonSchemaVersion = comparison.schemaVersion
        optimization.outcome = .verified
        try context.save()
    }

    /// "Keep this setup".
    public func keep(_ optimization: Optimization) throws {
        optimization.outcome = .kept
        try context.save()
    }

    /// Whether "Put the speaker back" can be offered (`OptimizeRules.canPutBack`).
    public func canPutBack(_ optimization: Optimization) -> Bool {
        OptimizeRules.canPutBack(
            outcome: optimization.outcome, after: optimization.layoutAfter, current: optimization.system?.room?.layout)
    }

    /// "Put the speaker back where it was": the room's layout returns to the one before the move. Throws
    /// `layoutChanged` when the room no longer has the layout the move left.
    public func putBack(_ optimization: Optimization, date: Date = .now) throws {
        guard let room = optimization.system?.room else { throw StoreError.noRoom }
        guard canPutBack(optimization) else { throw StoreError.layoutChanged }
        room.layoutData = optimization.layoutBeforeData
        room.layoutSchemaVersion = optimization.layoutBeforeVersion
        room.layoutUpdatedAt = date
        optimization.outcome = .putBack
        try context.save()
    }

    /// The suggestion was turned down.
    public func decline(_ optimization: Optimization) throws {
        optimization.outcome = .declined
        try context.save()
    }

    /// The latest optimisation that is not yet closed (kept, put back, declined or superseded).
    public func currentOptimization(in system: SoundSystem) -> Optimization? {
        optimizations(in: system).first { !$0.outcome.isClosed }
    }

    /// Every optimisation, newest first.
    public func optimizations(in system: SoundSystem) -> [Optimization] {
        system.optimizations.sorted { $0.createdAt > $1.createdAt }
    }

    /// Suggestions turned down (declined, or tried and put back) that still stand turned down for the room as it is
    /// and its baseline (`OptimizeRules.staysDeclined`).
    public func declinedSuggestions(in system: SoundSystem) -> [PlacementSuggestion] {
        let current = system.room?.layout
        let baseline = baseline(in: system)?.report
        return optimizations(in: system).compactMap { optimization in
            guard optimization.outcome == .declined || optimization.outcome == .putBack,
                  let suggestion = optimization.suggestion,
                  OptimizeRules.staysDeclined(
                    suggestion, madeFor: optimization.layoutBefore, current: current, baseline: baseline)
            else { return nil }
            return suggestion
        }
    }

    // MARK: Progress

    /// Which tracker steps have data (the rule is on `OptimizeProgress`).
    public func progress(in system: SoundSystem) -> OptimizeProgress {
        let current = currentOptimization(in: system)
        let moved = current?.layoutAfterData != nil
        return OptimizeProgress(
            scanned: system.room?.layoutData != nil,
            measured: baseline(in: system) != nil || (moved && current?.seatBefore != nil),
            moved: moved,
            verified: current?.seatAfter != nil && current?.comparisonData != nil)
    }

    /// What Optimize home shows for a system (nil: nothing stored yet).
    public func optimizeStatus(in system: SoundSystem?) -> OptimizeStatus {
        guard let system else { return OptimizeStatus() }
        var layout: RoomModel?
        if let room = system.room {
            do { layout = try self.layout(of: room) } catch { return OptimizeStatus(layoutUnreadable: true) }
        }
        let current = currentOptimization(in: system)
        var placement: OptimizeRules.MovePlacement?
        if let current, current.outcome == .moved, let suggestion = current.suggestion, let after = current.layoutAfter {
            placement = OptimizeRules.placement(of: suggestion, in: after)
        }
        return OptimizeStatus(
            layout: layout,
            progress: progress(in: system),
            baseline: baseline(in: system)?.report,
            comparison: current?.comparison,
            declined: declinedSuggestions(in: system),
            placement: placement)
    }
}
