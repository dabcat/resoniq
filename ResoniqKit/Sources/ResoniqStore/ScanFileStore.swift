import Foundation

/// Keeps the USDZ export of a room scan on disk; the database keeps only the file name. Plain `FileManager` code.
///
/// Files live in `<root>/Scans/`, with `root` the Application Support directory in the app (a temporary directory
/// in tests). Backup: the folder is left in the backup. A scan is user data that cannot be recreated without
/// walking the room again, and it is small; Application Support is backed up by default and only re-downloadable
/// or re-creatable files are excluded (data skill, `storage.md`). Recordings are not stored at all.
public struct ScanFileStore: Sendable {
    public static let folderName = "Scans"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The store in the app's Application Support directory.
    public static func applicationSupport() throws -> ScanFileStore {
        ScanFileStore(root: try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
    }

    public var folder: URL { root.appendingPathComponent(Self.folderName, isDirectory: true) }

    /// Copies the file at `source` (a temporary export) into the folder under a new unique name and returns the name
    /// to store on the room. When `replacing` names an older file, it is removed once the copy succeeded.
    public func importScan(from source: URL, replacing old: String? = nil) throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "usdz" : source.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        try fileManager.copyItem(at: source, to: folder.appendingPathComponent(name))
        if let old, old != name { delete(old) }
        return name
    }

    /// The file's URL, or nil when the name is not a plain file name or the file is missing.
    public func url(for name: String) -> URL? {
        guard Self.isPlain(name) else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Removes the file. A missing file or an odd name is not an error.
    public func delete(_ name: String) {
        guard Self.isPlain(name) else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }

    /// Removes every file in the folder whose name is not in `kept` (the names rooms refer to). Returns the names
    /// removed. A missing folder is not an error.
    @discardableResult
    public func sweep(keeping kept: Set<String>) -> [String] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
        var removed: [String] = []
        for name in names.sorted() where !kept.contains(name) && Self.isPlain(name) {
            if (try? fileManager.removeItem(at: folder.appendingPathComponent(name))) != nil { removed.append(name) }
        }
        return removed
    }

    // MARK: Temporary exports

    /// RoomPlan's USDZ export is written to the temporary directory under this prefix before it is imported.
    public static let temporaryExportPrefix = "Resoniq-scan-"

    /// A new URL for a scan's temporary export in `directory`.
    public static func temporaryExportURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(temporaryExportPrefix)\(UUID().uuidString).usdz")
    }

    /// Removes the temporary exports left in `directory` (a scan closed while RoomPlan was processing, the app
    /// stopped before Confirm layout). Run at launch, when no scan is in progress. Returns the names removed.
    @discardableResult
    public static func removeTemporaryExports(in directory: URL) -> [String] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var removed: [String] = []
        for name in names.sorted() where name.hasPrefix(temporaryExportPrefix) {
            if (try? fileManager.removeItem(at: directory.appendingPathComponent(name))) != nil { removed.append(name) }
        }
        return removed
    }

    private static func isPlain(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }
}
