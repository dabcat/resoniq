import Foundation

/// One HTTP request to the sharing service, as plain values: what `ShareClient` decides and a `ShareTransport` sends.
/// Tests read these to check that exactly the contract's requests go out, and nothing else.
public struct ShareRequest: Sendable, Equatable {
    public enum Method: String, Sendable {
        case post = "POST", put = "PUT", delete = "DELETE"
    }

    public enum Body: Sendable, Equatable {
        case none
        /// A few kilobytes made in memory: the shared manifest.
        case data(Data)
        /// A file streamed from disk by the transport, never read whole into memory: a recording.
        case file(URL)
    }

    public var method: Method
    public var url: URL
    /// Only `Authorization` and `Content-Type`; the transport adds its fixed, generic ones.
    public var headers: [String: String]
    public var body: Body
    /// Whether the request may use a cellular or Low Data Mode network. Only "Delete what I shared" may: it is a few
    /// bytes, and a person who wants their recordings gone should not have to find Wi-Fi first. Uploads never may.
    public var allowsExpensiveNetwork: Bool

    public init(method: Method, url: URL, headers: [String: String] = [:], body: Body = .none, allowsExpensiveNetwork: Bool = false) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.allowsExpensiveNetwork = allowsExpensiveNetwork
    }
}

public struct ShareResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    /// The `Retry-After` header in seconds, when the service sent one (a 429 on registration).
    public var retryAfter: TimeInterval?

    public init(status: Int, body: Data = Data(), retryAfter: TimeInterval? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

/// Why a request got no answer at all.
public enum ShareTransportFailure: Error, Sendable, Equatable {
    /// No allowed network (no Wi-Fi), the host could not be reached, or the connection dropped or timed out.
    case unreachable
}

/// Sends a `ShareRequest` and returns the service's answer, whatever its status. `HTTPShareTransport` in the app; a stub
/// in tests. Throws `ShareTransportFailure` when there was no answer and `CancellationError` when the task was cancelled.
public protocol ShareTransport: Sendable {
    func send(_ request: ShareRequest) async throws -> ShareResponse
}
