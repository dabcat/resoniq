import Foundation
import ResoniqDiagnostics
import SwiftData

/// Local persistence for rooms, sound systems and speaker tests. Nothing leaves the device (no CloudKit).
///
/// A quick check saves nothing: the caller simply never calls `keep(_:speaker:in:)`.
@MainActor
public final class ResoniqStore {
    /// Put this in the SwiftUI environment (`.modelContainer(store.container)`) to use `@Query`.
    public let container: ModelContainer

    public var context: ModelContext { container.mainContext }

    public init(container: ModelContainer) {
        self.container = container
    }

    /// A store on disk (local only) or, for tests and previews, in memory.
    public convenience init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(
            "Resoniq",
            schema: Schema(versionedSchema: ResoniqSchemaV1.self),
            isStoredInMemoryOnly: inMemory,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        self.init(container: try Self.makeContainer(configuration))
    }

    public static func makeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: ResoniqSchemaV1.self),
            migrationPlan: ResoniqMigrationPlan.self,
            configurations: configuration
        )
    }

    /// An in-memory container with its own storage.
    public static func inMemoryContainer() throws -> ModelContainer {
        try makeContainer(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    // MARK: Rooms and systems

    /// All rooms, oldest first.
    public func rooms() throws -> [Room] {
        try context.fetch(FetchDescriptor<Room>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    /// The room and system to use now: the selected system, else the first one, creating "My room" and
    /// "My speakers" (stereo pair) when nothing exists. Created once and reused.
    @discardableResult
    public func defaultContext() throws -> (room: Room, system: SoundSystem) {
        if let selected = try state().selectedSystem, let room = selected.room {
            return (room, selected)
        }
        for room in try rooms() {
            if let system = room.orderedSystems.first {
                return (room, system)
            }
        }
        let room = try rooms().first ?? addRoom(name: StoreText.defaultRoomName)
        let system = try addSystem(name: StoreText.defaultSystemName, kind: .stereoPair, to: room)
        return (room, system)
    }

    @discardableResult
    public func addRoom(name: String) throws -> Room {
        let room = Room(name: name)
        context.insert(room)
        try context.save()
        return room
    }

    @discardableResult
    public func addSystem(name: String, kind: SoundSystemKind, to room: Room) throws -> SoundSystem {
        let system = SoundSystem(name: name, kind: kind)
        context.insert(system)
        system.room = room
        try context.save()
        return system
    }

    public func rename(_ room: Room, to name: String) throws {
        room.name = name
        try context.save()
    }

    public func rename(_ system: SoundSystem, to name: String) throws {
        system.name = name
        try context.save()
    }

    /// Deletes the room, its systems and their tests.
    public func delete(_ room: Room) throws {
        clearSelection(ifIn: room.systems)
        context.delete(room)
        try context.save()
    }

    /// Deletes the system and its tests.
    public func delete(_ system: SoundSystem) throws {
        clearSelection(ifIn: [system])
        context.delete(system)
        try context.save()
    }

    // MARK: Selection

    /// The chosen system, persisted in the database. Nil falls back to `defaultContext()`.
    public var selectedSystem: SoundSystem? {
        (try? state())?.selectedSystem
    }

    public func select(_ system: SoundSystem?) throws {
        try state().selectedSystem = system
        try context.save()
    }

    /// SwiftData's nullify rule does not update the in-memory relationship of a live object, so clear it first.
    private func clearSelection(ifIn systems: [SoundSystem]) {
        guard let state = try? state(), let selected = state.selectedSystem,
              systems.contains(where: { $0 === selected }) else { return }
        state.selectedSystem = nil
    }

    private func state() throws -> StoreState {
        if let existing = try context.fetch(FetchDescriptor<StoreState>()).first {
            return existing
        }
        let created = StoreState()
        context.insert(created)
        return created
    }

    // MARK: Tests

    /// Saves a finished report ("Kept in: room · system"). Not calling this is "Don't keep" / a quick check.
    @discardableResult
    public func keep(
        _ report: SpeakerReport,
        speaker: SpeakerPosition,
        in system: SoundSystem,
        date: Date = .now
    ) throws -> SpeakerTest {
        let test = SpeakerTest(date: date, speaker: speaker, reportData: try JSONEncoder().encode(report))
        context.insert(test)
        test.system = system
        try context.save()
        return test
    }

    /// "Don't keep".
    public func discard(_ test: SpeakerTest) throws {
        context.delete(test)
        try context.save()
    }

    /// The most recent test of that speaker, for the home screen.
    public func latestTest(for speaker: SpeakerPosition, in system: SoundSystem) -> SpeakerTest? {
        history(for: speaker, in: system).first
    }

    /// Every test of that speaker, newest first.
    public func history(for speaker: SpeakerPosition, in system: SoundSystem) -> [SpeakerTest] {
        system.tests
            .filter { $0.speakerRaw == speaker.rawValue }
            .sorted { $0.date > $1.date }
    }
}
