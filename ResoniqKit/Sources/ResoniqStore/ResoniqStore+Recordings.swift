import Foundation
import SwiftData

extension ResoniqStore {
    /// Keeps the raw recordings of a kept test: names a folder on the test and saves that, writes the example off the
    /// main actor, then checks the outcome on it. Returns whether the example is on disk and the test refers to it.
    ///
    /// - The report is never touched: a write that fails clears the name again and the test stays kept as it was.
    /// - A test deleted while its example was written (Don't keep, its system or room deleted, a delete of all
    ///   results) has its folder removed once the write ends, so nothing is left behind whatever the order.
    /// - No `recordings` store, a test that already has a recording, or one already deleted: nothing is written.
    @discardableResult
    public func keepRecording(_ example: RecordingExample, for test: SpeakerTest) async -> Bool {
        guard let recordings, test.recordingFileName == nil, !test.isDeleted, test.modelContext != nil else { return false }
        let name = RecordingStore.folderName(date: example.manifest.createdAt, speaker: example.manifest.speaker.position)
        test.recordingFileName = name
        do {
            try context.save()
        } catch {
            test.recordingFileName = nil
            return false
        }
        let written = await Self.write(example, named: name, to: recordings)
        let owners = testsReferring(to: name)
        if !written {
            for owner in owners { owner.recordingFileName = nil }
            if !owners.isEmpty { try? context.save() }
        }
        if !written || owners.isEmpty {
            recordings.delete(name)
            return false
        }
        return true
    }

    /// Encodes and writes away from the main actor: a test's audio is a few megabytes.
    @concurrent
    nonisolated private static func write(_ example: RecordingExample, named name: String, to recordings: RecordingStore) async -> Bool {
        (try? recordings.write(example, named: name)) != nil
    }

    private func testsReferring(to name: String) -> [SpeakerTest] {
        let target: String? = name
        return (try? context.fetch(FetchDescriptor<SpeakerTest>(predicate: #Predicate { $0.recordingFileName == target }))) ?? []
    }

    /// Bytes the kept recordings take on this device; 0 without a recordings store.
    public func recordingsSize() -> Int64 {
        recordings?.totalSize() ?? 0
    }

    /// "Delete recordings": every recording goes, every test and its report stays.
    public func deleteRecordings() throws {
        let tests = try context.fetch(FetchDescriptor<SpeakerTest>(predicate: #Predicate { $0.recordingFileName != nil }))
        for test in tests { test.recordingFileName = nil }
        try context.save()
        recordings?.deleteAll()
    }

    /// Removes recording folders no test refers to (a write the app was stopped in, a test deleted by an older build)
    /// and partial writes. Run once at launch, before any test can be kept. Returns the names removed.
    @discardableResult
    public func sweepRecordings() throws -> [String] {
        guard let recordings else { return [] }
        let kept = try context.fetch(FetchDescriptor<SpeakerTest>()).compactMap(\.recordingFileName)
        return recordings.sweep(keeping: Set(kept))
    }
}
