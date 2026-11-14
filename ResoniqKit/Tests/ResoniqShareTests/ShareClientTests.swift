import Foundation
import Testing

@testable import ResoniqShare

/// The client against the contract in `docs/plans/phase-10-share-recordings.md`, "The service".
struct ShareClientTests {
    private func client(_ transport: some ShareTransport) -> ShareClient {
        ShareClient(baseURL: ShareFixtures.baseURL, transport: transport)
    }

    @Test func `register posts to the installs path with no body and no header`() async throws {
        let transport = StubTransport.working()
        let installation = try await client(transport).register()
        #expect(installation == ShareFixtures.installation)
        let request = try #require(transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://share.example.test/v1/installs")
        #expect(request.headers.isEmpty)
        #expect(request.body == .none)
        #expect(!request.allowsExpensiveNetwork)
    }

    @Test(arguments: [
        "{}", "{\"installId\":\"short\",\"token\":\"x\"}", "not json",
        "{\"installId\":\"\(String(repeating: "z", count: 32))\",\"token\":\"\(String(repeating: "b", count: 64))\"}",
    ])
    func `a registration the contract does not allow is a bad response`(body: String) async {
        let transport = StubTransport { _, _ in .success(ShareResponse(status: 201, body: Data(body.utf8))) }
        await #expect(throws: ShareError.badResponse) { try await client(transport).register() }
    }

    @Test func `an upload puts one file with the bearer token and its type, nothing else`() async throws {
        let transport = StubTransport.working()
        let file = try ShareFixtures.directory().appendingPathComponent("run-1.wav")
        try Data([1, 2, 3]).write(to: file)
        try await client(transport).upload(.file(file), file: "run-1.wav", example: "abcdef0123456789", installation: ShareFixtures.installation)
        let sent = try #require(transport.sent.first)
        #expect(sent.request.method == .put)
        #expect(sent.request.url.absoluteString
            == "https://share.example.test/v1/installs/\(ShareFixtures.installation.installId)/examples/abcdef0123456789/run-1.wav")
        #expect(sent.request.headers == [
            "Authorization": "Bearer \(ShareFixtures.installation.token)", "Content-Type": "audio/wav",
        ])
        #expect(sent.request.body == .file(file))
        #expect(sent.body == Data([1, 2, 3]))
        #expect(!sent.request.allowsExpensiveNetwork)
    }

    @Test func `the manifest goes as JSON`() async throws {
        let transport = StubTransport.working()
        try await client(transport).upload(.data(Data("{}".utf8)), file: "manifest.json", example: "abcdef0123456789", installation: ShareFixtures.installation)
        #expect(transport.requests.first?.headers["Content-Type"] == "application/json")
    }

    @Test(arguments: [
        ("short", "run-1.wav"), ("has a space in it", "run-1.wav"), ("abcdef0123456789", "run-10.wav"),
        ("abcdef0123456789", "../manifest.json"), ("abcdef0123456789", "notes.txt"), (String(repeating: "a", count: 65), "run-1.wav"),
    ])
    func `a name the contract refuses is refused before any request`(example: String, file: String) async {
        await #expect(throws: ShareError.badName) {
            try await client(FailingTransport()).upload(.none, file: file, example: example, installation: ShareFixtures.installation)
        }
    }

    @Test(arguments: [
        (400, ShareError.badName), (401, .unauthorized), (404, .notFound), (413, .tooLarge), (429, .rateLimited(retryAfter: nil)),
        (507, .overQuota), (500, .server(status: 500)), (503, .server(status: 503)),
    ])
    func `each status of the contract maps to its error`(status: Int, error: ShareError) async {
        let transport = StubTransport { _, _ in .success(ShareResponse(status: status, body: Data("{\"error\":\"x\"}".utf8))) }
        await #expect(throws: error) {
            try await client(transport).upload(.none, file: "run-1.wav", example: "abcdef0123456789", installation: ShareFixtures.installation)
        }
    }

    @Test func `a rate limit carries the service's Retry-After`() async {
        let transport = StubTransport { _, _ in .success(ShareResponse(status: 429, retryAfter: 120)) }
        await #expect(throws: ShareError.rateLimited(retryAfter: 120)) { try await client(transport).register() }
    }

    @Test func `any 2xx is a success, as the service answers 200`() async throws {
        let transport = StubTransport { _, _ in .success(ShareResponse(status: 200, body: Data("{\"ok\":true}".utf8))) }
        try await client(transport).upload(.data(Data("{}".utf8)), file: "manifest.json", example: "abcdef0123456789", installation: ShareFixtures.installation)
        try await client(transport).delete(ShareFixtures.installation)
    }

    @Test func `delete deletes the installation with its token, on any network`() async throws {
        let transport = StubTransport.working()
        try await client(transport).delete(ShareFixtures.installation)
        let request = try #require(transport.requests.first)
        #expect(request.method == .delete)
        #expect(request.url.absoluteString == "https://share.example.test/v1/installs/\(ShareFixtures.installation.installId)")
        #expect(request.headers == ["Authorization": "Bearer \(ShareFixtures.installation.token)"])
        #expect(request.allowsExpensiveNetwork)
    }

    @Test func `deleting what is gone already is done`() async throws {
        let transport = StubTransport { _, _ in .success(ShareResponse(status: 404)) }
        try await client(transport).delete(ShareFixtures.installation)
    }

    @Test func `no answer is unreachable, a cancelled task is cancelled`() async {
        let down = StubTransport { _, _ in .failure(ShareTransportFailure.unreachable) }
        await #expect(throws: ShareError.unreachable) { try await client(down).register() }
        let cancelled = StubTransport { _, _ in .failure(CancellationError()) }
        await #expect(throws: ShareError.cancelled) { try await client(cancelled).register() }
    }

    @Test func `a base URL with a path keeps it`() async throws {
        let transport = StubTransport.working()
        _ = try await ShareClient(baseURL: URL(string: "https://example.test/share")!, transport: transport).register()
        #expect(transport.requests.first?.url.absoluteString == "https://example.test/share/v1/installs")
    }

    @Test func `example ids are random and fit the contract`() {
        let ids = (0..<20).map { _ in ShareClient.newExampleID() }
        #expect(Set(ids).count == 20)
        #expect(ids.allSatisfy { ShareClient.isExampleID($0) && $0.count == 32 })
    }
}

struct ShareConfigurationTests {
    @Test(arguments: [nil, "", "   ", "$(RESONIQ_SHARE_URL)", "http://example.com", "ftp://example.com", "https://", "not a url",
                      "https://example.com?x=1", "https://user:pw@example.com"])
    func `no usable URL means no sharing in this build`(text: String?) {
        #expect(ShareConfiguration(baseURLString: text) == nil)
    }

    @Test(arguments: ["https://share.example.com", "https://example.com/share", "http://localhost:8787", "http://127.0.0.1:8787"])
    func `an https URL, or a local one for wrangler dev, is used`(text: String) {
        #expect(ShareConfiguration(baseURLString: text)?.baseURL.absoluteString == text)
    }
}

struct SharePreferenceTests {
    private func defaults() -> UserDefaults {
        let name = "resoniq-share-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func keys(_ defaults: UserDefaults) -> Set<String> {
        Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(SharePreference.key) })
    }

    @Test func `off by default, and reading it writes nothing`() {
        let defaults = defaults()
        let preference = SharePreference(defaults: defaults)
        #expect(!preference.isOn)
        #expect(preference.consent == nil)
        #expect(keys(defaults).isEmpty)
    }

    @Test func `turning it on records the consent's date and version`() {
        let defaults = defaults()
        let preference = SharePreference(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_794_700_000)
        preference.turnOn(consentedAt: date)
        #expect(preference.isOn)
        #expect(preference.consent == .init(date: date, version: SharePreference.currentConsentVersion))
    }

    @Test func `turning it off keeps the record of the consent`() {
        let preference = SharePreference(defaults: defaults())
        preference.turnOn()
        preference.turnOff()
        #expect(!preference.isOn)
        #expect(preference.consent != nil)
    }

    @Test func `a consent to older words does not count`() {
        let defaults = defaults()
        defaults.set(true, forKey: SharePreference.key)
        defaults.set(SharePreference.currentConsentVersion - 1, forKey: SharePreference.consentVersionKey)
        #expect(!SharePreference(defaults: defaults).isOn)
        // The flag alone, as a hand-edited defaults file might have it, is not consent either.
        defaults.removeObject(forKey: SharePreference.consentVersionKey)
        #expect(!SharePreference(defaults: defaults).isOn)
    }
}

struct MemoryCredentialsTests {
    @Test func `the memory store keeps, returns and forgets the installation`() throws {
        let store = MemoryShareCredentials()
        #expect(store.load() == nil)
        try store.save(ShareFixtures.installation)
        #expect(store.load() == ShareFixtures.installation)
        store.delete()
        #expect(store.load() == nil)
    }
}
