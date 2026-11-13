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
}

/// Which of the four tracker steps have data behind them. A step is done only when its data exists.
///
/// - `scanned`: the room has a layout (scanned or entered by hand).
/// - `measured`: a seat measurement exists that was made in the current layout, that is, it snapshots the current
///   layout or is newer than the layout's last change; or the current optimisation started from one (its
///   `seatBefore`), so a move does not undo the measurement it was made from. A room with no layout counts any
///   measurement.
/// - `moved`: the current optimisation has a layout after.
/// - `verified`: the current optimisation has a seat measurement after and a comparison.
///
/// The current optimisation is the latest one not yet kept, put back or declined.
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

extension ResoniqStore {
    // MARK: Layout

    /// The room's layout; nil when it has none; throws when the stored one cannot be read.
    public func layout(of room: Room) throws(ReportReadError) -> RoomModel? {
        try room.readLayout()
    }

    /// Stores the room's layout. With `scanFile`, the room refers to that file from now on and its earlier file, if
    /// any, is deleted (a rescan); without it the file reference stays (an edit of the plan).
    public func setLayout(_ layout: RoomModel, for room: Room, scanFile: String? = nil, date: Date = .now) throws {
        let data = try JSONEncoder().encode(layout)
        let oldFile = room.scanFileName
        room.layoutData = data
        room.layoutSchemaVersion = layout.schemaVersion
        room.layoutUpdatedAt = date
        if let scanFile { room.scanFileName = scanFile }
        try context.save()
        if let scanFile, let oldFile, oldFile != scanFile { scanFiles?.delete(oldFile) }
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

    /// The speaker was moved: stores the layout after and makes it the room's layout.
    public func recordMove(_ optimization: Optimization, newLayout: RoomModel, date: Date = .now) throws {
        guard let room = optimization.system?.room else { throw StoreError.noRoom }
        optimization.layoutAfterData = try JSONEncoder().encode(newLayout)
        optimization.layoutAfterVersion = newLayout.schemaVersion
        optimization.outcome = .moved
        try setLayout(newLayout, for: room, date: date)
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

    /// "Put the speaker back where it was": the room's layout returns to the one before the move.
    public func putBack(_ optimization: Optimization, date: Date = .now) throws {
        guard let room = optimization.system?.room else { throw StoreError.noRoom }
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

    /// The latest optimisation that is not yet kept, put back or declined.
    public func currentOptimization(in system: SoundSystem) -> Optimization? {
        optimizations(in: system).first { !$0.outcome.isClosed }
    }

    /// Every optimisation, newest first.
    public func optimizations(in system: SoundSystem) -> [Optimization] {
        system.optimizations.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Progress

    /// Which tracker steps have data (the rule is on `OptimizeProgress`).
    public func progress(in system: SoundSystem) -> OptimizeProgress {
        let room = system.room
        let current = currentOptimization(in: system)
        let scanned = room?.layoutData != nil
        var measured = false
        if let layoutData = room?.layoutData {
            let layoutDate = room?.layoutUpdatedAt
            measured = system.seatMeasurements.contains { measurement in
                measurement.layoutData == layoutData || layoutDate.map { measurement.date > $0 } ?? false
            }
        } else {
            measured = !system.seatMeasurements.isEmpty
        }
        if current?.seatBefore != nil { measured = true }
        return OptimizeProgress(
            scanned: scanned,
            measured: measured,
            moved: current?.layoutAfterData != nil,
            verified: current?.seatAfter != nil && current?.comparisonData != nil)
    }
}
