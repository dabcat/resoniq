import Foundation
import Testing
@testable import ResoniqShare

/// The real transport and client against the real Worker run locally (`cloud/share-worker`, `npx wrangler dev --port
/// 8787 --var RATE_LIMIT_MAX:1000`). Opt-in: runs only when `RESONIQ_SHARE_LOCAL_URL` names it, so `make test` and CI
/// never open a connection.
enum LocalWorker {
    static let url = ProcessInfo.processInfo.environment["RESONIQ_SHARE_LOCAL_URL"].flatMap(URL.init(string:))
}

@Suite(.enabled(if: LocalWorker.url != nil, "RESONIQ_SHARE_LOCAL_URL is not set"))
struct LocalWorkerTests {
    @Test func `register, upload every kind of file, and delete, against the local Worker`() async throws {
        let base = try #require(LocalWorker.url)
        let client = ShareClient(baseURL: base, transport: HTTPShareTransport())
        let installation = try await client.register()
        #expect(installation.isWellFormed)

        let example = ShareClient.newExampleID()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(example).wav")
        try Data(repeating: 7, count: 300_000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await client.upload(.data(Data(#"{"schemaVersion":1}"#.utf8)), file: "manifest.json", example: example, installation: installation)
        try await client.upload(.file(file), file: "noise-floor.wav", example: example, installation: installation)
        try await client.upload(.file(file), file: "run-1.wav", example: example, installation: installation)

        // Another installation's token is refused for this one's folder.
        let other = try await client.register()
        let forged = ShareInstallation(installId: installation.installId, token: other.token)
        await #expect(throws: ShareError.unauthorized) {
            try await client.upload(.file(file), file: "run-2.wav", example: example, installation: forged)
        }

        try await client.delete(installation)
        // Gone: the token no longer works, and deleting again is not an error for the caller.
        await #expect(throws: ShareError.unauthorized) {
            try await client.upload(.file(file), file: "run-2.wav", example: example, installation: installation)
        }
        try await client.delete(other)
    }
}
