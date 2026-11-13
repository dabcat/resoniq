import Foundation
import SwiftData

/// How much of each kind of thing is kept. Settings shows the whole store's; the rooms sheet shows what one room or
/// one system would take with it when it is deleted.
public struct StoreCounts: Equatable, Sendable {
    public var rooms: Int
    public var systems: Int
    public var speakerTests: Int
    public var seatMeasurements: Int
    /// Rooms that keep a scan file.
    public var roomScans: Int

    public init(rooms: Int = 0, systems: Int = 0, speakerTests: Int = 0, seatMeasurements: Int = 0, roomScans: Int = 0) {
        self.rooms = rooms
        self.systems = systems
        self.speakerTests = speakerTests
        self.seatMeasurements = seatMeasurements
        self.roomScans = roomScans
    }

    /// Speaker tests and seat measurements together: what "Delete all results" removes.
    public var results: Int { speakerTests + seatMeasurements }

    /// What deleting `system` removes: its tests and seat measurements.
    public init(system: SoundSystem) {
        self.init(
            rooms: 0, systems: 1, speakerTests: system.tests.count, seatMeasurements: system.seatMeasurements.count,
            roomScans: 0
        )
    }

    /// What deleting `room` removes: its systems, their tests and seat measurements, and its scan.
    public init(room: Room) {
        self.init(
            rooms: 1, systems: room.systems.count,
            speakerTests: room.systems.reduce(0) { $0 + $1.tests.count },
            seatMeasurements: room.systems.reduce(0) { $0 + $1.seatMeasurements.count },
            roomScans: room.scanFileName == nil ? 0 : 1
        )
    }
}

extension StoreText {
    /// "Room 2" for the second room.
    public static func newRoomName(existing count: Int) -> String { "Room \(count + 1)" }
    /// "Speakers 2" for the second system of a room.
    public static func newSystemName(existing count: Int) -> String { "Speakers \(count + 1)" }
}

extension ResoniqStore {
    /// What is kept, for Settings.
    public func counts() throws -> StoreCounts {
        let rooms = try rooms()
        return StoreCounts(
            rooms: rooms.count,
            systems: try context.fetchCount(FetchDescriptor<SoundSystem>()),
            speakerTests: try context.fetchCount(FetchDescriptor<SpeakerTest>()),
            seatMeasurements: try context.fetchCount(FetchDescriptor<SeatMeasurement>()),
            roomScans: rooms.filter { $0.scanFileName != nil }.count
        )
    }

    /// A room can go unless it is the last one: the app always has a room to listen in.
    public func canDelete(_ room: Room) throws -> Bool {
        try rooms().count > 1
    }

    /// A system can go unless it is the last one of its room: every room keeps a system to measure.
    public func canDelete(_ system: SoundSystem) -> Bool {
        (system.room?.systems.count ?? 0) > 1
    }

    /// "Delete all results": every speaker test, seat measurement and optimisation. Rooms, systems, layouts and scans
    /// stay.
    public func deleteAllResults() throws {
        try deleteAllObjects(of: Optimization.self)
        try deleteAllObjects(of: SeatMeasurement.self)
        try deleteAllObjects(of: SpeakerTest.self)
        try context.save()
        onDataReset?()
    }

    /// "Delete everything": all rooms with their systems, results and scan files. "My room" and "My speakers" are
    /// created again and selected, so the app is never without a room and a system.
    public func deleteEverything() throws {
        let scanFileNames = try rooms().compactMap(\.scanFileName)
        try select(nil)
        try deleteAllObjects(of: Optimization.self)
        try deleteAllObjects(of: SeatMeasurement.self)
        try deleteAllObjects(of: SpeakerTest.self)
        try deleteAllObjects(of: SoundSystem.self)
        try deleteAllObjects(of: Room.self)
        try context.save()
        for name in scanFileNames { scanFiles?.delete(name) }
        try select(try defaultContext().system)
        onDataReset?()
    }

    /// Removes scan files no room refers to: one imported for a scan whose layout was never confirmed (the app was
    /// closed on Confirm layout), or left by a failed save. Run once at launch. Returns the names removed.
    @discardableResult
    public func sweepScanFiles() throws -> [String] {
        guard let scanFiles else { return [] }
        return scanFiles.sweep(keeping: Set(try rooms().compactMap(\.scanFileName)))
    }

    /// One by one: a batch delete cannot honour the relationships between the models.
    private func deleteAllObjects<Model: PersistentModel>(of type: Model.Type) throws {
        for object in try context.fetch(FetchDescriptor<Model>()) { context.delete(object) }
    }
}
