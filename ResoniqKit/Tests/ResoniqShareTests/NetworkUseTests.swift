import Foundation
import Testing

/// `ResoniqShare` is the only code in the repository that may use the network: every other Kit module and the app
/// itself are read here, and a networking API named anywhere in them fails the test.
struct NetworkUseTests {
    /// The repository's root, from this file's place in `ResoniqKit/Tests/ResoniqShareTests/`.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The words that open, or describe, a connection.
    private static let forbidden = [
        "URLSession", "URLRequest", "URLProtocol", "NSURLConnection", "CFNetwork", "NWConnection", "NWPathMonitor",
        "NWListener", "NWBrowser", "NetworkConnection", "CFStream", "WebSocket", "WKWebView", "SFSafariViewController",
    ]

    private static func swiftFiles(under folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private static var checkedFiles: [URL] {
        let kit = root.appendingPathComponent("ResoniqKit/Sources")
        let modules = (try? FileManager.default.contentsOfDirectory(at: kit, includingPropertiesForKeys: nil)) ?? []
        let others = modules.filter { $0.lastPathComponent != "ResoniqShare" }
        return others.flatMap(swiftFiles) + swiftFiles(under: root.appendingPathComponent("Resoniq"))
    }

    @Test func `the files are found`() {
        let files = Self.checkedFiles.map(\.lastPathComponent)
        #expect(files.contains("RecordingStore.swift"))
        #expect(files.contains("AppComposition.swift"))
        #expect(!files.contains("HTTPShareTransport.swift"))
    }

    @Test func `no module but ResoniqShare names a networking API`() throws {
        for file in Self.checkedFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in Self.forbidden where text.contains(word) {
                Issue.record("\(file.path) names \(word)")
            }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("import Network") || trimmed.hasPrefix("@preconcurrency import Network")
                    || trimmed.hasPrefix("import WebKit") || trimmed.hasPrefix("import SafariServices") {
                    Issue.record("\(file.path): \(trimmed)")
                }
            }
        }
    }

    @Test func `the app makes the transport only through ResoniqShare's setup`() throws {
        // `HTTPShareTransport` appears in the app in one file, the composition that runs `ShareSetup`.
        let users = try Self.swiftFiles(under: Self.root.appendingPathComponent("Resoniq")).filter {
            try String(contentsOf: $0, encoding: .utf8).contains("HTTPShareTransport")
        }
        #expect(users.map(\.lastPathComponent).allSatisfy { $0 == "AppComposition.swift" || $0 == "ShareComposition.swift" })
    }
}
