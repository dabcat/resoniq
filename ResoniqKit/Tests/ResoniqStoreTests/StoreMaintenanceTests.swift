import Foundation
import ResoniqRoom
import SwiftData
import Testing

@testable import ResoniqStore

/// Scan files that nothing refers to, a hand-entered room replacing a scanned one, and the hook that lets the app drop
/// what it holds about deleted data.
@MainActor
struct StoreMaintenanceTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("resoniq-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeExport(_ text: String = "usdz") throws -> URL {
        let url = directory.appendingPathComponent("export-\(UUID().uuidString).usdz")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func theSweepRemovesScanFilesNoRoomRefersTo() throws {
        let files = ScanFileStore(root: directory.appendingPathComponent("support"))
        let store = ResoniqStore(container: try ResoniqStore.inMemoryContainer(), scanFiles: files)
        let room = try store.defaultContext().room
        let kept = try files.importScan(from: try makeExport("kept"))
        try store.setLayout(V2Fixtures.room(), for: room, scanFile: kept)
        // Imported for a scan whose layout was never confirmed (the app was closed on Confirm layout).
        let orphan = try files.importScan(from: try makeExport("orphan"))

        #expect(try store.sweepScanFiles() == [orphan])
        #expect(files.url(for: kept) != nil)
        #expect(files.url(for: orphan) == nil)
        // Nothing left to remove.
        #expect(try store.sweepScanFiles().isEmpty)
        // A store without a files folder sweeps nothing, and a missing folder is not an error.
        #expect(try ResoniqStore(container: try ResoniqStore.inMemoryContainer()).sweepScanFiles().isEmpty)
        #expect(ScanFileStore(root: directory.appendingPathComponent("none")).sweep(keeping: []).isEmpty)
    }

    @Test func temporaryExportsLeftBehindAreRemoved() throws {
        let leftover = ScanFileStore.temporaryExportURL(in: directory)
        try Data("usdz".utf8).write(to: leftover)
        let other = directory.appendingPathComponent("someone-else.usdz")
        try Data("x".utf8).write(to: other)
        #expect(leftover.lastPathComponent.hasPrefix(ScanFileStore.temporaryExportPrefix))

        #expect(ScanFileStore.removeTemporaryExports(in: directory) == [leftover.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func aHandEnteredRoomDropsTheScanOfTheRoomBefore() throws {
        let files = ScanFileStore(root: directory)
        let store = ResoniqStore(container: try ResoniqStore.inMemoryContainer(), scanFiles: files)
        let room = try store.defaultContext().room
        var scanned = V2Fixtures.room()
        scanned.source = .scanned
        let scan = try files.importScan(from: try makeExport())
        try store.confirmLayout(scanned, for: room, scanFile: scan)
        #expect(room.scanFileName == scan)

        // An edit of the scanned room keeps the scan.
        try store.confirmLayout(scanned, for: room)
        #expect(room.scanFileName == scan)

        let manual = try #require(ManualRoom(width: 3.5, length: 4.5).model())
        #expect(manual.source == .manual)
        try store.confirmLayout(manual, for: room)
        #expect(room.scanFileName == nil)
        #expect(files.url(for: scan) == nil)
        #expect(try store.counts().roomScans == 0)
    }

    @Test func deletingDataTellsTheApp() throws {
        let store = ResoniqStore(container: try ResoniqStore.inMemoryContainer())
        let system = try store.defaultContext().system
        var resets = 0
        store.onDataReset = { resets += 1 }
        try store.keep(V2Fixtures.seatReport(), in: system)
        try store.rename(system, to: "Desk")
        #expect(resets == 0)
        try store.deleteAllResults()
        #expect(resets == 1)
        try store.deleteEverything()
        #expect(resets == 2)
    }
}
