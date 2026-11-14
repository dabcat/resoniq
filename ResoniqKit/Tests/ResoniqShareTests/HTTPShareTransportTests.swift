import Foundation
import Synchronization
import Testing

@testable import ResoniqShare

/// The `URLSession` transport against a local stub service (`StubService`, a `URLProtocol`): the headers that go, the
/// body that is streamed, the statuses that come back, and the session's configuration. The real Worker is checked by
/// the reviewer with `wrangler dev`.
@Suite(.serialized)
struct HTTPShareTransportTests {
    private let transport = HTTPShareTransport(protocolClasses: [StubService.self])

    init() {
        StubService.reset()
    }

    @Test func `uploads go only over Wi-Fi, with nothing stored and no waiting`() {
        let configuration = HTTPShareTransport.configuration(allowsExpensive: false, protocolClasses: nil)
        #expect(!configuration.allowsExpensiveNetworkAccess)
        #expect(!configuration.allowsConstrainedNetworkAccess)
        #expect(!configuration.waitsForConnectivity)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpAdditionalHeaders?["User-Agent"] as? String == "Resoniq")
        let delete = HTTPShareTransport.configuration(allowsExpensive: true, protocolClasses: nil)
        #expect(delete.allowsExpensiveNetworkAccess && delete.allowsConstrainedNetworkAccess)
        #expect(delete.httpCookieStorage == nil && delete.urlCache == nil)
    }

    @Test func `a request carries its own headers and the fixed generic ones, nothing else`() async throws {
        StubService.respond = { _ in (201, Data("{\"installId\":\"\(ShareFixtures.installation.installId)\",\"token\":\"\(ShareFixtures.installation.token)\"}".utf8)) }
        let client = ShareClient(baseURL: ShareFixtures.baseURL, transport: transport)
        #expect(try await client.register() == ShareFixtures.installation)

        let seen = try #require(StubService.seen.first)
        #expect(seen.method == "POST")
        #expect(seen.url == "https://share.example.test/v1/installs")
        #expect(seen.headers["User-Agent"] == "Resoniq")
        #expect(seen.headers["Accept-Language"] == "en")
        #expect(seen.headers["Cookie"] == nil)
        #expect(seen.headers["Authorization"] == nil)
        // Nothing names the phone or its owner.
        let host = ProcessInfo.processInfo.hostName
        #expect(!seen.headers.values.contains { $0.contains(host) && !host.isEmpty })
    }

    @Test func `a recording is streamed from its file with the token`() async throws {
        StubService.respond = { _ in (201, Data()) }
        let file = try ShareFixtures.directory().appendingPathComponent("run-1.wav")
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        let client = ShareClient(baseURL: ShareFixtures.baseURL, transport: transport)
        try await client.upload(.file(file), file: "run-1.wav", example: "abcdef0123456789", installation: ShareFixtures.installation)

        let seen = try #require(StubService.seen.first)
        #expect(seen.method == "PUT")
        #expect(seen.headers["Authorization"] == "Bearer \(ShareFixtures.installation.token)")
        #expect(seen.headers["Content-Type"] == "audio/wav")
        #expect(seen.body == bytes)
    }

    @Test func `the service's status comes back as it is`() async throws {
        StubService.respond = { _ in (507, Data("{\"error\":\"over_quota\"}".utf8)) }
        let client = ShareClient(baseURL: ShareFixtures.baseURL, transport: transport)
        await #expect(throws: ShareError.overQuota) {
            try await client.upload(.data(Data("{}".utf8)), file: "manifest.json", example: "abcdef0123456789", installation: ShareFixtures.installation)
        }
    }

    @Test func `no connection is unreachable`() async throws {
        StubService.respond = { _ in nil }
        let client = ShareClient(baseURL: ShareFixtures.baseURL, transport: transport)
        await #expect(throws: ShareError.unreachable) { try await client.register() }
    }

    @Test func `the whole queue runs over the real transport`() async throws {
        StubService.respond = { request in
            request.httpMethod == "POST"
                ? (201, Data("{\"installId\":\"\(ShareFixtures.installation.installId)\",\"token\":\"\(ShareFixtures.installation.token)\"}".utf8))
                : (201, Data("{\"ok\":true}".utf8))
        }
        let (store, names) = try ShareFixtures.store(examples: 1)
        let queue = ShareQueue(
            client: ShareClient(baseURL: ShareFixtures.baseURL, transport: transport), credentials: MemoryShareCredentials(),
            recordings: store, isAllowed: { true }
        )
        await queue.kept(names[0])
        await queue.send()
        #expect(StubService.seen.map(\.method) == ["POST", "PUT", "PUT", "PUT", "PUT", "PUT"])
        #expect(await queue.status() == ShareStatus(sent: 1))
        let runFile = try #require(store.fileURL(names[0], file: "run-3.wav"))
        #expect(StubService.seen.last?.body == (try Data(contentsOf: runFile)))
    }
}

/// A local stand-in for the Worker, in front of `URLSession`: records each request with its body and answers with
/// `respond` (nil: the connection fails).
final class StubService: URLProtocol {
    struct Seen: Sendable {
        var method: String
        var url: String
        var headers: [String: String]
        var body: Data
    }

    private static let state = Mutex<(seen: [Seen], respond: @Sendable (URLRequest) -> (Int, Data)?)>(([], { _ in (200, Data()) }))

    static var seen: [Seen] { state.withLock { $0.seen } }
    static var respond: @Sendable (URLRequest) -> (Int, Data)? {
        get { state.withLock { $0.respond } }
        set { state.withLock { $0.respond = newValue } }
    }

    static func reset() {
        state.withLock { $0 = ([], { _ in (200, Data()) }) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        Self.state.withLock {
            $0.seen.append(Seen(
                method: request.httpMethod ?? "", url: request.url?.absoluteString ?? "",
                headers: request.allHTTPHeaderFields ?? [:], body: body
            ))
        }
        guard let url = request.url, let (status, data) = Self.respond(request),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
