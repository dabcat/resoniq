import Foundation
import ResoniqDiagnostics
import SwiftData

/// The kinds of sound system a room can hold.
public enum SoundSystemKind: String, Codable, Sendable, CaseIterable {
    case stereoPair
    case stereoWithSubwoofer
    case soundbar
    case singleSpeaker
    case surround
}

/// Which speaker of a system a test measured.
public enum SpeakerPosition: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case single
}

/// Why a stored report cannot be shown.
public enum ReportReadError: Error, Equatable, Sendable {
    /// Written by a different version of the app than this one reads.
    case unknownSchemaVersion(Int)
    /// The bytes do not decode as the stored type (`SpeakerReport`, `SeatReport`, `RoomModel`...).
    case undecodable
}

/// Version 1 of the stored schema, kept as it shipped so a V1 store can migrate. Never edit it; the live models are
/// `ResoniqSchemaV2` (the typealiases `Room`, `SoundSystem`... point there).
public enum ResoniqSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] { [Room.self, SoundSystem.self, SpeakerTest.self, StoreState.self] }

    @Model
    public final class Room {
        public var name: String = ""
        public var createdAt: Date = Date.now
        @Relationship(deleteRule: .cascade, inverse: \SoundSystem.room)
        public var systems: [SoundSystem] = []

        public init(name: String, createdAt: Date = .now) {
            self.name = name
            self.createdAt = createdAt
        }

        /// Systems oldest first.
        public var orderedSystems: [SoundSystem] { systems.sorted { $0.createdAt < $1.createdAt } }
    }

    @Model
    public final class SoundSystem {
        public var name: String = ""
        public var kindRaw: String = SoundSystemKind.stereoPair.rawValue
        public var createdAt: Date = Date.now
        public var room: Room?
        @Relationship(deleteRule: .cascade, inverse: \SpeakerTest.system)
        public var tests: [SpeakerTest] = []

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
            guard reportSchemaVersion == Self.currentReportSchemaVersion else {
                throw .unknownSchemaVersion(reportSchemaVersion)
            }
            guard let report = try? JSONDecoder().decode(SpeakerReport.self, from: reportData) else {
                throw .undecodable
            }
            return report
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
}

