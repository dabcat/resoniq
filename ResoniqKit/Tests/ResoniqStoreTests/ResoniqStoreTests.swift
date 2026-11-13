import Foundation
import ResoniqDiagnostics
import SwiftData
import Testing

@testable import ResoniqStore

@MainActor
struct ResoniqStoreTests {
    let container: ModelContainer
    let store: ResoniqStore

    init() throws {
        container = try ResoniqStore.inMemoryContainer()
        store = ResoniqStore(container: container)
    }

    /// An inconclusive report with a chosen verdict, so two reports differ.
    func report(_ verdict: String = "Not heard yet") throws -> SpeakerReport {
        let base = SpeakerDiagnosis.diagnose(runs: [], counterpart: nil)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        json["verdict"] = verdict
        return try JSONDecoder().decode(SpeakerReport.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func defaultContextIsCreatedOnceAndReused() throws {
        let first = try store.defaultContext()
        let second = try store.defaultContext()
        #expect(first.room.name == "My room")
        #expect(first.system.name == "My speakers")
        #expect(first.system.kind == .stereoPair)
        #expect(first.system === second.system)
        #expect(try store.rooms().count == 1)
        #expect(first.room.systems.count == 1)
    }

    @Test func keptReportReadsBackEqual() throws {
        let system = try store.defaultContext().system
        let original = try report("Woofer may buzz")
        let test = try store.keep(original, speaker: .left, in: system)
        #expect(try test.readReport() == original)
        #expect(test.report == original)
        #expect(test.speaker == .left)
        #expect(test.recordingFileName == nil)
    }

    @Test func latestAndHistoryAreOrderedByDate() throws {
        let system = try store.defaultContext().system
        let t0 = Date(timeIntervalSince1970: 1000)
        let old = try store.keep(report("a"), speaker: .left, in: system, date: t0)
        let new = try store.keep(report("c"), speaker: .left, in: system, date: t0 + 200)
        let mid = try store.keep(report("b"), speaker: .left, in: system, date: t0 + 100)
        _ = try store.keep(report("r"), speaker: .right, in: system, date: t0 + 300)
        #expect(store.history(for: .left, in: system) == [new, mid, old])
        #expect(store.latestTest(for: .left, in: system) == new)
        #expect(store.latestTest(for: .single, in: system) == nil)
    }

    @Test func discardRemovesTest() throws {
        let system = try store.defaultContext().system
        let test = try store.keep(report(), speaker: .single, in: system)
        try store.discard(test)
        #expect(store.history(for: .single, in: system).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<SpeakerTest>()).isEmpty)
    }

    @Test func deletingSystemRemovesItsTests() throws {
        let (room, system) = try store.defaultContext()
        let other = try store.addSystem(name: "Bar", kind: .soundbar, to: room)
        _ = try store.keep(report(), speaker: .left, in: system)
        _ = try store.keep(report(), speaker: .single, in: other)
        try store.delete(system)
        let remaining = try container.mainContext.fetch(FetchDescriptor<SpeakerTest>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.system === other)
    }

    @Test func deletingRoomRemovesSystemsAndTests() throws {
        let (room, system) = try store.defaultContext()
        _ = try store.keep(report(), speaker: .left, in: system)
        try store.delete(room)
        #expect(try container.mainContext.fetch(FetchDescriptor<SpeakerTest>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<SoundSystem>()).isEmpty)
        #expect(try store.rooms().isEmpty)
    }

    @Test func selectionSurvivesANewStoreOnTheSameContainer() throws {
        let (room, _) = try store.defaultContext()
        let sub = try store.addSystem(name: "Sub", kind: .stereoWithSubwoofer, to: room)
        try store.select(sub)
        // A second context reads what was saved, not the objects the first one holds.
        let again = ResoniqStore(container: container, context: ModelContext(container))
        #expect(again.selectedSystem?.persistentModelID == sub.persistentModelID)
        #expect(again.selectedSystem !== sub)
        #expect(try again.defaultContext().system.persistentModelID == sub.persistentModelID)
    }

    @Test func selectionFallsBackToDefaultWhenDeleted() throws {
        let (room, original) = try store.defaultContext()
        let sub = try store.addSystem(name: "Sub", kind: .stereoWithSubwoofer, to: room)
        try store.select(sub)
        try store.delete(sub)
        #expect(store.selectedSystem == nil)
        #expect(try store.defaultContext().system === original)
    }

    @Test func deletingEverythingRecreatesDefaults() throws {
        let (room, _) = try store.defaultContext()
        try store.delete(room)
        let fresh = try store.defaultContext()
        #expect(fresh.room.name == "My room")
        #expect(try store.rooms().count == 1)
    }

    @Test func unreadableReportsAreReportedNotCrashed() throws {
        let system = try store.defaultContext().system
        let future = SpeakerTest(date: .now, speaker: .left, reportData: try JSONEncoder().encode(report()), reportSchemaVersion: 99)
        let damaged = SpeakerTest(date: .now, speaker: .left, reportData: Data("nope".utf8))
        for test in [future, damaged] {
            container.mainContext.insert(test)
            test.system = system
        }
        #expect(throws: ReportReadError.unknownSchemaVersion(99)) { try future.readReport() }
        #expect(throws: ReportReadError.undecodable) { try damaged.readReport() }
        #expect(future.report == nil)
        #expect(damaged.report == nil)
    }

    @Test func renamingPersists() throws {
        let (room, system) = try store.defaultContext()
        try store.rename(room, to: "Study")
        try store.rename(system, to: "Desk")
        let again = ResoniqStore(container: container, context: ModelContext(container))
        #expect(try again.rooms().first !== room)
        #expect(try again.rooms().first?.name == "Study")
        #expect(try again.defaultContext().system.name == "Desk")
    }

    @Test func displayNamesExist() {
        for kind in SoundSystemKind.allCases { #expect(!kind.displayName.isEmpty) }
    }
}
