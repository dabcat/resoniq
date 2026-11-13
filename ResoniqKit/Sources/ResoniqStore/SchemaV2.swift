import Foundation
import ResoniqDiagnostics
import ResoniqRoom
import SwiftData

public typealias Room = ResoniqSchemaV2.Room
public typealias SoundSystem = ResoniqSchemaV2.SoundSystem
public typealias SpeakerTest = ResoniqSchemaV2.SpeakerTest
public typealias StoreState = ResoniqSchemaV2.StoreState
public typealias SeatMeasurement = ResoniqSchemaV2.SeatMeasurement
public typealias Optimization = ResoniqSchemaV2.Optimization

/// Where an optimisation stands. Stored as its raw string.
public enum OptimizationOutcome: String, Codable, Sendable, CaseIterable {
    /// A suggestion was chosen; nothing has moved yet.
    case suggested
    /// The speaker was moved and the new layout stored; not yet measured again.
    case moved
    /// Measured again and compared.
    case verified
    /// The user keeps the new setup.
    case kept
    /// The speaker went back where it was.
    case putBack
    /// The suggestion was turned down before any move.
    case declined
    /// The room's layout changed under it (a rescan, entry by hand, or an edit that is not the recorded move), so its
    /// before and after no longer describe the room. Stored as a new raw string; an older build reads it as
    /// `suggested` (`outcome`'s fallback), which only an app downgrade could meet.
    case superseded

    /// Whether the user has finished with it (kept, put back, declined, or superseded by a new layout).
    public var isClosed: Bool { self == .kept || self == .putBack || self == .declined || self == .superseded }
}

/// Decodes the values a model keeps as `Data` with a schema version beside them.
enum StoredValue {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, version: Int, expected: Int) throws(ReportReadError) -> T {
        guard version == expected else { throw .unknownSchemaVersion(version) }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw .undecodable }
        return value
    }
}

/// Version 2 of the stored schema: a room keeps its layout and scan file name; seat measurements and optimisations
/// are new. Migration from V1 is lightweight (only optional or defaulted properties and new models are added).
public enum ResoniqSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [Room.self, SoundSystem.self, SpeakerTest.self, StoreState.self, SeatMeasurement.self, Optimization.self]
    }

    @Model
    public final class Room {
        public var name: String = ""
        public var createdAt: Date = Date.now
        @Relationship(deleteRule: .cascade, inverse: \SoundSystem.room)
        public var systems: [SoundSystem] = []

        /// The `RoomModel`, encoded. Nil until the room is scanned or entered.
        public var layoutData: Data?
        /// The version of the encoding of `layoutData` (`RoomModel.schemaVersion` when it was written).
        public var layoutSchemaVersion: Int = 1
        /// When the layout was last set (scan, edit, move, put back).
        public var layoutUpdatedAt: Date?
        /// File name of the USDZ export in `ScanFileStore`. A reference only; the file is not in the database.
        public var scanFileName: String?

        public init(name: String, createdAt: Date = .now) {
            self.name = name
            self.createdAt = createdAt
        }

        /// Systems oldest first.
        public var orderedSystems: [SoundSystem] { systems.sorted { $0.createdAt < $1.createdAt } }

        /// The stored layout; nil when the room has none; throws when it cannot be read. Never crashes.
        public func readLayout() throws(ReportReadError) -> RoomModel? {
            guard let layoutData else { return nil }
            return try StoredValue.decode(RoomModel.self, from: layoutData, version: layoutSchemaVersion, expected: RoomModel.currentSchemaVersion)
        }

        /// The stored layout, nil when absent or unreadable.
        public var layout: RoomModel? { (try? readLayout()) ?? nil }
    }

    @Model
    public final class SoundSystem {
        public var name: String = ""
        public var kindRaw: String = SoundSystemKind.stereoPair.rawValue
        public var createdAt: Date = Date.now
        public var room: Room?
        @Relationship(deleteRule: .cascade, inverse: \SpeakerTest.system)
        public var tests: [SpeakerTest] = []
        @Relationship(deleteRule: .cascade, inverse: \SeatMeasurement.system)
        public var seatMeasurements: [SeatMeasurement] = []
        @Relationship(deleteRule: .cascade, inverse: \Optimization.system)
        public var optimizations: [Optimization] = []

        public init(name: String, kind: SoundSystemKind, createdAt: Date = .now) {
            self.name = name
            self.kindRaw = kind.rawValue
            self.createdAt = createdAt
        }

        public var kind: SoundSystemKind {
            get { SoundSystemKind(rawValue: kindRaw) ?? .stereoPair }
            set { kindRaw = newValue.rawValue }
        }
    }

    @Model
    public final class SpeakerTest {
        /// The version of the encoding of `reportData`. Bump `currentReportSchemaVersion` when `SpeakerReport` changes.
        public var reportSchemaVersion: Int = 1
        public var date: Date = Date.now
        public var speakerRaw: String = SpeakerPosition.single.rawValue
        public var reportData: Data = Data()
        /// Reserved: file name of the raw recording, relative to a future recordings folder. Always nil in phase 2.
        public var recordingFileName: String?
        public var system: SoundSystem?

        public static let currentReportSchemaVersion = 1

        public init(date: Date, speaker: SpeakerPosition, reportData: Data, reportSchemaVersion: Int = 1) {
            self.date = date
            self.speakerRaw = speaker.rawValue
            self.reportData = reportData
            self.reportSchemaVersion = reportSchemaVersion
        }

        public var speaker: SpeakerPosition {
            get { SpeakerPosition(rawValue: speakerRaw) ?? .single }
            set { speakerRaw = newValue.rawValue }
        }

        /// The stored report, or why it cannot be read. Never crashes on old or damaged data.
        public func readReport() throws(ReportReadError) -> SpeakerReport {
            try StoredValue.decode(SpeakerReport.self, from: reportData, version: reportSchemaVersion, expected: Self.currentReportSchemaVersion)
        }

        /// The stored report, nil when it is unreadable.
        public var report: SpeakerReport? { try? readReport() }
    }

    /// One row holding app-level state that must stay consistent with deletes.
    @Model
    public final class StoreState {
        @Relationship(deleteRule: .nullify)
        public var selectedSystem: SoundSystem?

        public init() {}
    }

    /// One kept measurement at the seat, with the layout the room had when it was made.
    @Model
    public final class SeatMeasurement {
        public var date: Date = Date.now
        public var system: SoundSystem?
        /// The version of the encoding of `reportData` (`SeatReport.schemaVersion`).
        public var reportSchemaVersion: Int = 1
        public var reportData: Data = Data()
        /// The `RoomModel` the room had when this was measured, so a later comparison knows where the speakers stood.
        /// Nil when the room had no layout.
        public var layoutData: Data?
        public var layoutSchemaVersion: Int = 1
        /// Optimisations that started from this measurement. Deleting the measurement clears their reference.
        @Relationship(deleteRule: .nullify, inverse: \Optimization.seatBefore)
        public var asBefore: [Optimization] = []
        /// Optimisations that were verified with this measurement.
        @Relationship(deleteRule: .nullify, inverse: \Optimization.seatAfter)
        public var asAfter: [Optimization] = []

        public init(date: Date, reportData: Data, reportSchemaVersion: Int = SeatReport.currentSchemaVersion,
                    layoutData: Data? = nil, layoutSchemaVersion: Int = RoomModel.currentSchemaVersion) {
            self.date = date
            self.reportData = reportData
            self.reportSchemaVersion = reportSchemaVersion
            self.layoutData = layoutData
            self.layoutSchemaVersion = layoutSchemaVersion
        }

        public func readReport() throws(ReportReadError) -> SeatReport {
            try StoredValue.decode(SeatReport.self, from: reportData, version: reportSchemaVersion, expected: SeatReport.currentSchemaVersion)
        }

        public var report: SeatReport? { try? readReport() }

        /// The layout at measurement time; nil when there was none; throws when it cannot be read.
        public func readLayout() throws(ReportReadError) -> RoomModel? {
            guard let layoutData else { return nil }
            return try StoredValue.decode(RoomModel.self, from: layoutData, version: layoutSchemaVersion, expected: RoomModel.currentSchemaVersion)
        }

        /// The layout at measurement time, nil when there was none or it is unreadable.
        public var layout: RoomModel? { (try? readLayout()) ?? nil }
    }

    /// One try at improving the seat: a suggestion, the layouts before and after, and what the second measurement said.
    @Model
    public final class Optimization {
        public static let currentSuggestionSchemaVersion = 1

        public var createdAt: Date = Date.now
        public var system: SoundSystem?
        public var suggestionSchemaVersion: Int = 1
        public var suggestionData: Data = Data()
        public var layoutBeforeData: Data = Data()
        public var layoutBeforeVersion: Int = 1
        /// Nil until the move is confirmed.
        public var layoutAfterData: Data?
        public var layoutAfterVersion: Int = 1
        public var seatBefore: SeatMeasurement?
        public var seatAfter: SeatMeasurement?
        public var comparisonData: Data?
        public var comparisonSchemaVersion: Int = 1
        public var outcomeRaw: String = OptimizationOutcome.suggested.rawValue

        public init(createdAt: Date = .now, suggestionData: Data, layoutBeforeData: Data,
                    layoutBeforeVersion: Int = RoomModel.currentSchemaVersion) {
            self.createdAt = createdAt
            self.suggestionData = suggestionData
            self.layoutBeforeData = layoutBeforeData
            self.layoutBeforeVersion = layoutBeforeVersion
        }

        public var outcome: OptimizationOutcome {
            get { OptimizationOutcome(rawValue: outcomeRaw) ?? .suggested }
            set { outcomeRaw = newValue.rawValue }
        }

        public func readSuggestion() throws(ReportReadError) -> PlacementSuggestion {
            try StoredValue.decode(PlacementSuggestion.self, from: suggestionData, version: suggestionSchemaVersion, expected: Self.currentSuggestionSchemaVersion)
        }

        public func readLayoutBefore() throws(ReportReadError) -> RoomModel {
            try StoredValue.decode(RoomModel.self, from: layoutBeforeData, version: layoutBeforeVersion, expected: RoomModel.currentSchemaVersion)
        }

        /// Nil until the move is confirmed.
        public func readLayoutAfter() throws(ReportReadError) -> RoomModel? {
            guard let layoutAfterData else { return nil }
            return try StoredValue.decode(RoomModel.self, from: layoutAfterData, version: layoutAfterVersion, expected: RoomModel.currentSchemaVersion)
        }

        /// Nil until the second measurement is compared.
        public func readComparison() throws(ReportReadError) -> ComparisonReport? {
            guard let comparisonData else { return nil }
            return try StoredValue.decode(ComparisonReport.self, from: comparisonData, version: comparisonSchemaVersion, expected: ComparisonReport.currentSchemaVersion)
        }

        public var suggestion: PlacementSuggestion? { try? readSuggestion() }
        public var comparison: ComparisonReport? { (try? readComparison()) ?? nil }
        /// The layout before, nil when unreadable.
        public var layoutBefore: RoomModel? { try? readLayoutBefore() }
        /// The layout after, nil before the move or when unreadable.
        public var layoutAfter: RoomModel? { (try? readLayoutAfter()) ?? nil }
    }
}

/// V1 to V2 is lightweight: `Room` gains optional or defaulted properties, `SoundSystem` gains two relationships, and
/// two models are new. No existing value changes.
public enum ResoniqMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [ResoniqSchemaV1.self, ResoniqSchemaV2.self] }
    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ResoniqSchemaV1.self, toVersion: ResoniqSchemaV2.self)]
    }
}
