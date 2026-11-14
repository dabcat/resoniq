import Foundation

/// The one place in the app that opens a network connection: `URLSession`, in the foreground.
///
/// - **Wi-Fi only for uploads**: `allowsExpensiveNetworkAccess` and `allowsConstrainedNetworkAccess` are false, so
///   nothing goes over cellular, a personal hotspot or Low Data Mode. "Delete what I shared" alone uses a second
///   session that allows them (`ShareRequest.allowsExpensiveNetwork`).
/// - **No waiting**: `waitsForConnectivity` is false. A request with no allowed network fails at once and the queue
///   tries later, instead of holding a task open for minutes.
/// - **Nothing kept, nothing extra sent**: an ephemeral configuration with no cookie store, no cache and no credential
///   store; a fixed `User-Agent` ("Resoniq", no version, no device) and `Accept-Language: en`, so the phone's language
///   does not go either. TLS 1.2 at least, and App Transport Security as the system has it.
/// - **Foreground, not background**: a background session would need app-delegate wiring for its events, and a
///   recording is a few megabytes sent in seconds on Wi-Fi, so uploads run while Resoniq is open; one cut off when the
///   app closes is sent again the next time it opens.
/// - **Streamed**: a `.file` body goes through `upload(for:fromFile:)`, which reads it from disk as it sends.
public final class HTTPShareTransport: ShareTransport {
    public static let userAgent = "Resoniq"

    private let wifiOnly: URLSession
    private let anyNetwork: URLSession

    public convenience init() {
        self.init(protocolClasses: nil)
    }

    /// `protocolClasses` puts a `URLProtocol` stub in front of the network, for tests.
    init(protocolClasses: [AnyClass]?) {
        wifiOnly = URLSession(configuration: Self.configuration(allowsExpensive: false, protocolClasses: protocolClasses))
        anyNetwork = URLSession(configuration: Self.configuration(allowsExpensive: true, protocolClasses: protocolClasses))
    }

    static func configuration(allowsExpensive: Bool, protocolClasses: [AnyClass]?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsExpensiveNetworkAccess = allowsExpensive
        configuration.allowsConstrainedNetworkAccess = allowsExpensive
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpAdditionalHeaders = Self.fixedHeaders
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    /// Added to every request, and the only headers besides the request's own.
    static let fixedHeaders = ["User-Agent": userAgent, "Accept": "application/json", "Accept-Language": "en"]

    public func send(_ request: ShareRequest) async throws -> ShareResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        urlRequest.allowsExpensiveNetworkAccess = request.allowsExpensiveNetwork
        urlRequest.allowsConstrainedNetworkAccess = request.allowsExpensiveNetwork
        for (name, value) in Self.fixedHeaders.merging(request.headers, uniquingKeysWith: { _, new in new }) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let session = request.allowsExpensiveNetwork ? anyNetwork : wifiOnly
        do {
            let (data, response) = try await {
                switch request.body {
                case .none: try await session.data(for: urlRequest)
                case .data(let body): try await session.upload(for: urlRequest, from: body)
                case .file(let url): try await session.upload(for: urlRequest, fromFile: url)
                }
            }()
            guard let http = response as? HTTPURLResponse else { throw ShareTransportFailure.unreachable }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return ShareResponse(status: http.statusCode, body: data, retryAfter: retryAfter)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ShareTransportFailure.unreachable
        }
    }
}
