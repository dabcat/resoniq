import Foundation
import ResoniqDiagnostics
import ResoniqRoom
import SwiftData
import Testing

@testable import ResoniqStore

/// Fixtures built with public initialisers only.
enum V2Fixtures {
    static func room(speakerX: Double = -1) -> RoomModel {
        var room = ManualRoom(width: 4.2, length: 5.6).model()!
        let seat = PlanPoint(x: 0, z: 0.3)
        let left = PlanPoint(x: speakerX, z: -1.4), right = PlanPoint(x: 1, z: -1.4)
        room.seats = [Seat(position: seat, isConfirmed: true)]
        room.speakers = [
            PlacedSpeaker(role: .left, position: left, facing: (seat - left).angle, isConfirmed: true),
            PlacedSpeaker(role: .right, position: right, facing: (seat - right).angle, isConfirmed: true),
        ]
        return room
    }

    static func seatReport(_ verdict: String = "From your seat, the bass is uneven.", schemaVersion: Int = SeatReport.currentSchemaVersion) -> SeatReport {
        SeatReport(
            schemaVersion: schemaVersion, verdict: verdict, isConclusive: true, validSpotCount: 3, requiredSpotCount: 3,
            spots: [], curve: nil, leftCurve: nil, rightCurve: nil, spotCurves: [], spread: nil, assessed: nil,
            evenBandDecibels: 4, extremes: [], leftRightDifference: nil, findings: [], numbers: [],
            distortionPercent: nil, bassDecay: nil)
    }

    static func comparison(_ verdict: String = "The missing bass note is back.") -> ComparisonReport {
        ComparisonReport(verdict: verdict, rows: [], note: "All measured just now.", outcome: .improved, nextTarget: nil, isConclusive: true)
    }

    static func suggestion(in room: RoomModel) throws -> PlacementSuggestion {
        let problem = AcousticProblem(frequency: 61, deviation: 11, kind: .dip)
        return try #require(PlacementAdvisor.suggestions(room: room, problems: [problem]).first)
    }
}

@MainActor
struct StoreV2Tests {
    let container: ModelContainer
    let store: ResoniqStore
    let room: Room
    let system: SoundSystem

    init() throws {
        container = try ResoniqStore.inMemoryContainer()
        store = ResoniqStore(container: container)
        (room, system) = try store.defaultContext()
    }

    // MARK: Layout

    @Test func layoutRoundTrips() throws {
        #expect(try store.layout(of: room) == nil)
        let model = V2Fixtures.room()
        let date = Date(timeIntervalSince1970: 5000)
        try store.setLayout(model, for: room, date: date)
        #expect(try store.layout(of: room) == model)
        #expect(room.layout == model)
        #expect(room.layoutUpdatedAt == date)
        #expect(room.layoutSchemaVersion == RoomModel.currentSchemaVersion)
        let again = ResoniqStore(container: container)
        #expect(try again.layout(of: again.rooms()[0]) == model)
    }

    @Test func unknownLayoutVersionAndDamagedDataAreReported() throws {
        try store.setLayout(V2Fixtures.room(), for: room)
        room.layoutSchemaVersion = 99
        #expect(throws: ReportReadError.unknownSchemaVersion(99)) { try store.layout(of: room) }
        #expect(room.layout == nil)
        room.layoutSchemaVersion = RoomModel.currentSchemaVersion
        room.layoutData = Data("nope".utf8)
        #expect(throws: ReportReadError.undecodable) { try store.layout(of: room) }
    }

    // MARK: Seat measurements

    @Test func seatMeasurementKeepLatestHistoryDiscard() throws {
        let t0 = Date(timeIntervalSince1970: 1000)
        let old = try store.keep(V2Fixtures.seatReport("a"), in: system, date: t0)
        let new = try store.keep(V2Fixtures.seatReport("c"), in: system, date: t0 + 200)
        let mid = try store.keep(V2Fixtures.seatReport("b"), in: system, date: t0 + 100)
        #expect(store.seatHistory(in: system) == [new, mid, old])
        #expect(store.latestSeatMeasurement(in: system) == new)
        #expect(try new.readReport() == V2Fixtures.seatReport("c"))
        try store.discard(new)
        #expect(store.latestSeatMeasurement(in: system) == mid)
        #expect(try container.mainContext.fetch(FetchDescriptor<SeatMeasurement>()).count == 2)
    }

    @Test func seatMeasurementSnapshotsTheLayoutItWasMadeIn() throws {
        let first = V2Fixtures.room(speakerX: -1)
        let second = V2Fixtures.room(speakerX: -1.3)
        let noLayout = try store.keep(V2Fixtures.seatReport(), in: system)
        #expect(noLayout.layoutData == nil)
        #expect(try noLayout.readLayout() == nil)
        try store.setLayout(first, for: room)
        let inFirst = try store.keep(V2Fixtures.seatReport(), in: system)
        try store.setLayout(second, for: room)
        let inSecond = try store.keep(V2Fixtures.seatReport(), in: system)
        #expect(try inFirst.readLayout() == first)
        #expect(try inSecond.readLayout() == second)
    }

    @Test func unreadableSeatReportIsReported() throws {
        let m = try store.keep(V2Fixtures.seatReport(), in: system)
        m.reportSchemaVersion = 7
        #expect(throws: ReportReadError.unknownSchemaVersion(7)) { try m.readReport() }
        #expect(m.report == nil)
        m.reportSchemaVersion = SeatReport.currentSchemaVersion
        m.reportData = Data("x".utf8)
        #expect(throws: ReportReadError.undecodable) { try m.readReport() }
    }

    // MARK: Optimisation life cycle

    func begin() throws -> (Optimization, SeatMeasurement, RoomModel) {
        let layout = V2Fixtures.room()
        try store.setLayout(layout, for: room, date: Date(timeIntervalSince1970: 100))
        let before = try store.keep(V2Fixtures.seatReport("before"), in: system, date: Date(timeIntervalSince1970: 200))
        let optimization = try store.beginOptimization(suggestion: V2Fixtures.suggestion(in: layout), in: system, before: before)
        return (optimization, before, layout)
    }

    @Test func beginNeedsALayout() throws {
        let m = try store.keep(V2Fixtures.seatReport(), in: system)
        let suggestion = try V2Fixtures.suggestion(in: V2Fixtures.room())
        #expect(throws: StoreError.noLayout) { try store.beginOptimization(suggestion: suggestion, in: system, before: m) }
    }

    @Test func lifeCycleThroughVerifiedAndKept() throws {
        let (optimization, before, layout) = try begin()
        #expect(optimization.outcome == .suggested)
        #expect(optimization.seatBefore === before)
        #expect(try optimization.readLayoutBefore() == layout)
        #expect(try optimization.readLayoutAfter() == nil)
        #expect(optimization.suggestion != nil)
        #expect(store.currentOptimization(in: system) === optimization)

        let moved = V2Fixtures.room(speakerX: -1.4)
        try store.recordMove(optimization, newLayout: moved, date: Date(timeIntervalSince1970: 300))
        #expect(optimization.outcome == .moved)
        #expect(try optimization.readLayoutAfter() == moved)
        #expect(room.layout == moved)
        #expect(room.layoutUpdatedAt == Date(timeIntervalSince1970: 300))

        let after = try store.keep(V2Fixtures.seatReport("after"), in: system, date: Date(timeIntervalSince1970: 400))
        #expect(try after.readLayout() == moved)
        let comparison = V2Fixtures.comparison()
        try store.recordVerification(optimization, after: after, comparison: comparison)
        #expect(optimization.outcome == .verified)
        #expect(optimization.seatAfter === after)
        #expect(try optimization.readComparison() == comparison)
        #expect(store.currentOptimization(in: system) === optimization)

        try store.keep(optimization)
        #expect(optimization.outcome == .kept)
        #expect(room.layout == moved)
        #expect(store.currentOptimization(in: system) == nil)
        #expect(store.optimizations(in: system) == [optimization])
    }

    @Test func putBackRestoresTheEarlierLayout() throws {
        let (optimization, _, layout) = try begin()
        try store.recordMove(optimization, newLayout: V2Fixtures.room(speakerX: -1.4), date: Date(timeIntervalSince1970: 300))
        try store.putBack(optimization, date: Date(timeIntervalSince1970: 500))
        #expect(optimization.outcome == .putBack)
        #expect(room.layout == layout)
        #expect(room.layoutUpdatedAt == Date(timeIntervalSince1970: 500))
        #expect(store.currentOptimization(in: system) == nil)
        #expect(try optimization.readLayoutAfter() != nil)
    }

    @Test func declineClosesTheOptimization() throws {
        let (optimization, _, layout) = try begin()
        try store.decline(optimization)
        #expect(optimization.outcome == .declined)
        #expect(store.currentOptimization(in: system) == nil)
        #expect(room.layout == layout)
    }

    @Test func currentOptimizationIsTheLatestOpenOne() throws {
        let (first, before, layout) = try begin()
        try store.decline(first)
        let suggestion = try V2Fixtures.suggestion(in: layout)
        let second = try store.beginOptimization(suggestion: suggestion, in: system, before: before, date: .now + 10)
        let third = try store.beginOptimization(suggestion: suggestion, in: system, before: before, date: .now + 20)
        #expect(store.currentOptimization(in: system) === third)
        try store.keep(third)
        #expect(store.currentOptimization(in: system) === second)
        #expect(store.optimizations(in: system) == [third, second, first])
    }

    @Test func outcomesAreStoredAsRawStrings() throws {
        let (optimization, _, _) = try begin()
        for outcome in OptimizationOutcome.allCases {
            optimization.outcome = outcome
            #expect(optimization.outcomeRaw == outcome.rawValue)
        }
        optimization.outcomeRaw = "from the future"
        #expect(optimization.outcome == .suggested)
    }

    // MARK: Progress

    @Test func progressForEachCombination() throws {
        #expect(store.progress(in: system) == OptimizeProgress())

        // A measurement without a layout counts as measured; nothing is scanned.
        let early = try store.keep(V2Fixtures.seatReport(), in: system, date: Date(timeIntervalSince1970: 50))
        #expect(store.progress(in: system) == OptimizeProgress(measured: true))
        try store.discard(early)

        // A layout alone: scanned, not measured.
        let layout = V2Fixtures.room()
        try store.setLayout(layout, for: room, date: Date(timeIntervalSince1970: 100))
        #expect(store.progress(in: system) == OptimizeProgress(scanned: true))

        // A measurement older than the layout, made in another one: not measured.
        let stale = try store.keep(V2Fixtures.seatReport(), in: system, date: Date(timeIntervalSince1970: 90))
        stale.layoutData = try JSONEncoder().encode(V2Fixtures.room(speakerX: -2))
        #expect(store.progress(in: system) == OptimizeProgress(scanned: true))

        // One newer than the layout: measured.
        let before = try store.keep(V2Fixtures.seatReport(), in: system, date: Date(timeIntervalSince1970: 200))
        #expect(store.progress(in: system) == OptimizeProgress(scanned: true, measured: true))

        // The layout changes without a new measurement: the old one snapshots a different layout and is older.
        let optimization = try store.beginOptimization(suggestion: V2Fixtures.suggestion(in: layout), in: system, before: before)
        #expect(store.progress(in: system) == OptimizeProgress(scanned: true, measured: true))
        try store.recordMove(optimization, newLayout: V2Fixtures.room(speakerX: -1.4), date: Date(timeIntervalSince1970: 300))
        // Moved; measured stays true through the optimisation's own baseline.
        #expect(store.progress(in: system) == OptimizeProgress(scanned: true, measured: true, moved: true))

        let after = try store.keep(V2Fixtures.seatReport("after"), in: system, date: Date(timeIntervalSince1970: 400))
        // A second measurement alone is not a verification.
        try store.recordVerification(optimization, after: after, comparison: V2Fixtures.comparison())
        #expect(store.progress(in: system) == OptimizeProgress(scanned: true, measured: true, moved: true, verified: true))

        // Kept: the cycle is over; the new layout is measured (the "after" snapshots it).
        try store.keep(optimization)
        #expect(store.progress(in: system) == OptimizeProgress(scanned: true, measured: true))
    }

    @Test func aMeasurementOfTheCurrentLayoutCountsEvenIfOlder() throws {
        let layout = V2Fixtures.room()
        try store.setLayout(layout, for: room, date: Date(timeIntervalSince1970: 100))
        _ = try store.keep(V2Fixtures.seatReport(), in: system, date: Date(timeIntervalSince1970: 150))
        // The layout is saved again later, unchanged in bytes: the snapshot still matches.
        room.layoutUpdatedAt = Date(timeIntervalSince1970: 900)
        #expect(store.progress(in: system).measured)
        // Edited: the same measurement no longer counts.
        try store.setLayout(V2Fixtures.room(speakerX: -1.2), for: room, date: Date(timeIntervalSince1970: 1000))
        #expect(!store.progress(in: system).measured)
    }

    @Test func progressAfterPutBackCountsTheBaseline() throws {
        let (optimization, _, _) = try begin()
        try store.recordMove(optimization, newLayout: V2Fixtures.room(speakerX: -1.4), date: Date(timeIntervalSince1970: 300))
        try store.putBack(optimization, date: Date(timeIntervalSince1970: 500))
        // The baseline snapshots the restored layout.
        #expect(store.progress(in: system) == OptimizeProgress(scanned: true, measured: true))
    }

    // MARK: Delete rules

    @Test func deletingARoomDeletesEverythingUnderIt() throws {
        let (optimization, _, _) = try begin()
        _ = try store.keep(V2Fixtures.seatReport(), in: system)
        _ = optimization
        try store.delete(room)
        for count in [
            try container.mainContext.fetchCount(FetchDescriptor<SoundSystem>()),
            try container.mainContext.fetchCount(FetchDescriptor<SeatMeasurement>()),
            try container.mainContext.fetchCount(FetchDescriptor<Optimization>()),
            try container.mainContext.fetchCount(FetchDescriptor<Room>()),
        ] { #expect(count == 0) }
    }

    @Test func deletingASystemDeletesItsMeasurementsAndOptimizations() throws {
        let other = try store.addSystem(name: "Bar", kind: .soundbar, to: room)
        _ = try begin()
        _ = try store.keep(V2Fixtures.seatReport(), in: other)
        try store.delete(system)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Optimization>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SeatMeasurement>()) == 1)
    }

    @Test func discardingAReferencedMeasurementNullifiesTheReference() throws {
        let (optimization, before, _) = try begin()
        let moved = V2Fixtures.room(speakerX: -1.4)
        try store.recordMove(optimization, newLayout: moved)
        let after = try store.keep(V2Fixtures.seatReport("after"), in: system)
        try store.recordVerification(optimization, after: after, comparison: V2Fixtures.comparison())
        try store.discard(before)
        #expect(optimization.seatBefore == nil)
        try store.discard(after)
        #expect(optimization.seatAfter == nil)
        // The optimisation and its stored values are intact and can be read.
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Optimization>()) == 1)
        #expect(try optimization.readComparison() != nil)
        let again = ResoniqStore(container: container)
        let fetched = try #require(again.context.fetch(FetchDescriptor<Optimization>()).first)
        #expect(fetched.seatBefore == nil && fetched.seatAfter == nil)
    }

    @Test func deletingASystemWithLinkedMeasurementsDoesNotCrash() throws {
        let (optimization, before, _) = try begin()
        try store.delete(system)
        _ = optimization.outcome
        _ = before.date
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SeatMeasurement>()) == 0)
    }

    @Test func deletingTheSelectedSystemStillClearsTheSelection() throws {
        try store.select(system)
        _ = try begin()
        try store.delete(system)
        #expect(store.selectedSystem == nil)
    }
}

@MainActor
struct ScanFileTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("resoniq-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeExport(_ text: String = "usdz") throws -> URL {
        let url = directory.appendingPathComponent("export-\(UUID().uuidString).usdz")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func copiesAndResolves() throws {
        let files = ScanFileStore(root: directory.appendingPathComponent("support"))
        let source = try makeExport("one")
        let name = try files.importScan(from: source)
        #expect(name.hasSuffix(".usdz"))
        let url = try #require(files.url(for: name))
        #expect(url.deletingLastPathComponent().lastPathComponent == "Scans")
        #expect(try Data(contentsOf: url) == Data("one".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(files.url(for: "missing.usdz") == nil)
        #expect(files.url(for: "../escape") == nil)
        #expect(files.url(for: "") == nil)
    }

    @Test func rescanReplacesTheOldFile() throws {
        let files = ScanFileStore(root: directory)
        let first = try files.importScan(from: try makeExport("one"))
        let second = try files.importScan(from: try makeExport("two"), replacing: first)
        #expect(first != second)
        #expect(files.url(for: first) == nil)
        #expect(try Data(contentsOf: try #require(files.url(for: second))) == Data("two".utf8))
    }

    @Test func aFailedCopyKeepsTheOldFile() throws {
        let files = ScanFileStore(root: directory)
        let first = try files.importScan(from: try makeExport())
        #expect(throws: (any Error).self) { try files.importScan(from: directory.appendingPathComponent("nope.usdz"), replacing: first) }
        #expect(files.url(for: first) != nil)
    }

    @Test func deleteIsQuietWhenMissing() throws {
        let files = ScanFileStore(root: directory)
        files.delete("missing.usdz")
        files.delete("../x")
    }

    @Test func storeDeletesTheFileWithTheRoomAndOnRescan() throws {
        let files = ScanFileStore(root: directory)
        let store = ResoniqStore(container: try ResoniqStore.inMemoryContainer(), scanFiles: files)
        let room = try store.defaultContext().room
        let first = try files.importScan(from: try makeExport("one"))
        try store.setLayout(V2Fixtures.room(), for: room, scanFile: first)
        #expect(room.scanFileName == first)

        // An edit without a file keeps the reference.
        try store.setLayout(V2Fixtures.room(speakerX: -1.2), for: room)
        #expect(room.scanFileName == first)
        #expect(files.url(for: first) != nil)

        // A rescan replaces it and removes the old file.
        let second = try files.importScan(from: try makeExport("two"))
        try store.setLayout(V2Fixtures.room(), for: room, scanFile: second)
        #expect(room.scanFileName == second)
        #expect(files.url(for: first) == nil)
        #expect(files.url(for: second) != nil)

        try store.delete(room)
        #expect(files.url(for: second) == nil)
    }
}

@MainActor
struct MigrationTests {
    /// A store written by the shipped app (schema V1) opens under V2 with everything in it, and the new fields empty.
    @Test func aVersion1StoreOnDiskMigratesToVersion2() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resoniq-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Resoniq.store")
        let reportData = try JSONEncoder().encode(
            try JSONDecoder().decode(SpeakerReport.self, from: JSONEncoder().encode(SpeakerDiagnosis.diagnose(runs: [], counterpart: nil))))
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let v1 = try ModelContainer(
                for: Schema(versionedSchema: ResoniqSchemaV1.self),
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let context = v1.mainContext
            let room = ResoniqSchemaV1.Room(name: "Study", createdAt: date)
            let system = ResoniqSchemaV1.SoundSystem(name: "Desk", kind: .soundbar, createdAt: date)
            let test = ResoniqSchemaV1.SpeakerTest(date: date, speaker: .left, reportData: reportData)
            let state = ResoniqSchemaV1.StoreState()
            context.insert(room)
            context.insert(system)
            context.insert(test)
            context.insert(state)
            system.room = room
            test.system = system
            state.selectedSystem = system
            try context.save()
        }

        let container = try ResoniqStore.makeContainer(ModelConfiguration(url: url, cloudKitDatabase: .none))
        let store = ResoniqStore(container: container)
        let room = try #require(try store.rooms().first)
        #expect(try store.rooms().count == 1)
        #expect(room.name == "Study")
        #expect(room.createdAt == date)
        #expect(room.layoutData == nil)
        #expect(room.layoutUpdatedAt == nil)
        #expect(room.scanFileName == nil)
        #expect(try store.layout(of: room) == nil)

        let system = try #require(room.systems.first)
        #expect(system.name == "Desk")
        #expect(system.kind == .soundbar)
        #expect(system.seatMeasurements.isEmpty)
        #expect(system.optimizations.isEmpty)
        #expect(store.selectedSystem === system)

        let test = try #require(system.tests.first)
        #expect(test.speaker == .left)
        #expect(test.date == date)
        #expect(test.reportData == reportData)
        #expect(test.report != nil)
        #expect(store.progress(in: system) == OptimizeProgress())

        // The migrated store takes V2 data.
        try store.setLayout(V2Fixtures.room(), for: room)
        let measurement = try store.keep(V2Fixtures.seatReport(), in: system)
        #expect(try measurement.readLayout() != nil)
        #expect(store.progress(in: system) == OptimizeProgress(scanned: true, measured: true))
    }
}
