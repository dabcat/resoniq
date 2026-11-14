import Foundation
import ResoniqAudio

/// Keeps the raw recordings of kept speaker tests on disk, one folder per test; the database keeps only the folder's
/// name (`SpeakerTest.recordingFileName`). Plain `FileManager` code, callable from any thread.
///
/// ```
/// <root>/Recordings/2026-11-14_153012_left_1A2B3C4D/
///     manifest.json      RecordingManifest
///     noise-floor.wav    mono, 32-bit float, the stream's rate
///     run-1.wav …        one per run, the same
/// ```
///
/// `root` is the app's Documents directory, so the owner reaches the folders with the Files app and with
/// `xcrun devicectl device copy from --domain-type appDataContainer`; a temporary directory in tests.
///
/// **Backup.** The `Recordings` folder is excluded from the backup: a recording is the room's raw sound, kept only
/// for the owner to take off the phone themselves, and an iCloud backup would send it off the device without being
/// asked.
///
/// **Writes are whole or absent.** An example is written into `.<name>.partial` and moved to `<name>` once every file
/// is in, so a folder with a plain name is always complete. A partial folder a stopped write left behind is removed
/// by `sweep(keeping:)`.
public struct RecordingStore: Sendable {
    public static let folderName = "Recordings"
    public static let manifestFileName = "manifest.json"
    public static let noiseFloorFileName = "noise-floor.wav"

    public static func runFileName(_ run: Int) -> String { "run-\(run).wav" }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The store in the app's Documents directory.
    public static func documents() throws -> RecordingStore {
        RecordingStore(root: try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
    }

    public var folder: URL { root.appendingPathComponent(Self.folderName, isDirectory: true) }

    /// A folder name that sorts by date and says which speaker: `2026-11-14_153012_left_1A2B3C4D` (local time, the
    /// first eight hex digits of `id`).
    public static func folderName(date: Date, speaker: SpeakerPosition, id: UUID = UUID(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return "\(formatter.string(from: date))_\(speaker.rawValue)_\(id.uuidString.prefix(8))"
    }

    // MARK: Writing and reading

    /// Writes the example under `name`, replacing what is there.
    public func write(_ example: RecordingExample, named name: String) throws {
        guard Self.isPlain(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let fileManager = FileManager.default
        try makeFolder()
        let partial = folder.appendingPathComponent(".\(name).partial", isDirectory: true)
        try? fileManager.removeItem(at: partial)
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            let rate = example.manifest.sampleRate
            try WAVFile.float32(channels: [example.noiseFloor], sampleRate: rate)
                .write(to: partial.appendingPathComponent(Self.noiseFloorFileName))
            for (index, samples) in example.runs.enumerated() {
                let file = index < example.manifest.runs.count ? example.manifest.runs[index].file : Self.runFileName(index + 1)
                try WAVFile.float32(channels: [samples], sampleRate: rate).write(to: partial.appendingPathComponent(file))
            }
            try RecordingManifest.encoder.encode(example.manifest)
                .write(to: partial.appendingPathComponent(Self.manifestFileName))
            let final = folder.appendingPathComponent(name, isDirectory: true)
            try? fileManager.removeItem(at: final)
            try fileManager.moveItem(at: partial, to: final)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    /// Reads an example back.
    public func read(_ name: String) throws -> RecordingExample {
        guard Self.isPlain(name) else { throw CocoaError(.fileReadInvalidFileName) }
        let directory = folder.appendingPathComponent(name, isDirectory: true)
        let manifest = try RecordingManifest.decoder.decode(
            RecordingManifest.self, from: Data(contentsOf: directory.appendingPathComponent(Self.manifestFileName)))
        func mono(_ file: String) throws -> [Float] {
            try WAVFile.read(Data(contentsOf: directory.appendingPathComponent(file))).channels.first ?? []
        }
        return RecordingExample(
            manifest: manifest, runs: try manifest.runs.map { try mono($0.file) }, noiseFloor: try mono(manifest.noiseFloor.file))
    }

    /// Reads only an example's manifest, without its audio.
    public func manifest(_ name: String) throws -> RecordingManifest {
        guard Self.isPlain(name) else { throw CocoaError(.fileReadInvalidFileName) }
        let url = folder.appendingPathComponent(name, isDirectory: true).appendingPathComponent(Self.manifestFileName)
        return try RecordingManifest.decoder.decode(RecordingManifest.self, from: Data(contentsOf: url))
    }

    /// Where one file of an example is, for a reader that streams it (sharing); nil for an odd name.
    public func fileURL(_ name: String, file: String) -> URL? {
        guard Self.isPlain(name), Self.isPlain(file) else { return nil }
        return folder.appendingPathComponent(name, isDirectory: true).appendingPathComponent(file)
    }

    /// Whether a complete example is kept under `name`.
    public func contains(_ name: String) -> Bool {
        guard Self.isPlain(name) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: What is there

    /// The complete examples, by name, sorted.
    public func names() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Bytes on disk of every file under the folder, partial writes included.
    public func totalSize() -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    // MARK: Deleting

    /// Removes the example. A missing folder or an odd name is not an error.
    public func delete(_ name: String) {
        guard Self.isPlain(name) else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name, isDirectory: true))
    }

    /// Removes every example and partial write.
    public func deleteAll() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names { try? fileManager.removeItem(at: folder.appendingPathComponent(name)) }
    }

    /// Removes every folder whose name is not in `kept`, partial writes included. Run when no write is under way (at
    /// launch). Returns the names removed.
    @discardableResult
    public func sweep(keeping kept: Set<String>) -> [String] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
        var removed: [String] = []
        for name in names.sorted() where !kept.contains(name) && name != "." && name != ".." {
            if (try? fileManager.removeItem(at: folder.appendingPathComponent(name))) != nil { removed.append(name) }
        }
        return removed
    }

    private func makeFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = folder
        try url.setResourceValues(values)
    }

    private static func isPlain(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
    }
}

/// Whether kept speaker tests also keep their recordings ("Keep recordings" in Settings). Off until the owner turns
/// it on; kept in `UserDefaults` under `key`, as `IntroGate` keeps its flag.
public struct RecordingPreference {
    public static let key = "keepRecordings"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isOn: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
