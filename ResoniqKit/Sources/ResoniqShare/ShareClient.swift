import Foundation

/// What went wrong talking to the service, from the contract's status codes (`docs/plans/phase-10-share-recordings.md`,
/// "The service").
public enum ShareError: Error, Sendable, Equatable, Codable {
    /// 400: a name the service refuses (`bad_name`), or an upload with no body (`empty_body`). The client checks both
    /// first, so this means the two disagree.
    case badName
    /// 401: no token, a wrong one, or an installation the service does not know (deleted there).
    case unauthorized
    /// 404.
    case notFound
    /// 413: one file over the service's limit (`maximumFileSize`). The queue does not even send such a file.
    case tooLarge
    /// 429: too many requests; try later, not before `retryAfter` seconds when the service said.
    case rateLimited(retryAfter: TimeInterval?)
    /// 507: this installation holds all the service allows.
    case overQuota
    /// Any other status.
    case server(status: Int)
    /// No answer: no Wi-Fi, no network, the service down.
    case unreachable
    /// A success that did not hold what the contract says.
    case badResponse
    /// The task was cancelled (sharing turned off, the app closed): not a failure of the service.
    case cancelled

    init(_ response: ShareResponse) {
        switch response.status {
        case 400: self = .badName
        case 401: self = .unauthorized
        case 404: self = .notFound
        case 413: self = .tooLarge
        case 429: self = .rateLimited(retryAfter: response.retryAfter)
        case 507: self = .overQuota
        default: self = .server(status: response.status)
        }
    }
}

/// An installation the service made: its id and the token that lets it write its own folder. Kept in the Keychain
/// (`KeychainShareCredentials`).
public struct ShareInstallation: Codable, Sendable, Equatable {
    /// 32 hexadecimal digits.
    public var installId: String
    /// 64 hexadecimal digits.
    public var token: String

    public init(installId: String, token: String) {
        self.installId = installId
        self.token = token
    }

    var isWellFormed: Bool {
        Self.isHex(installId, count: 32) && Self.isHex(token, count: 64)
    }

    private static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }
}

/// The three requests of the contract, and nothing else: make an installation, store one file of an example, delete the
/// installation with everything in it. Stateless; the token is passed in.
public struct ShareClient: Sendable {
    /// The service's limit for one file, inclusive: 4 MB.
    public static let maximumFileSize = 4 * 1024 * 1024

    public let baseURL: URL
    private let transport: any ShareTransport

    public init(baseURL: URL, transport: any ShareTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// `POST /v1/installs`.
    public func register() async throws(ShareError) -> ShareInstallation {
        let response = try await send(ShareRequest(method: .post, url: url("v1", "installs")))
        guard (200..<300).contains(response.status) else { throw ShareError(response) }
        guard let installation = try? JSONDecoder().decode(ShareInstallation.self, from: response.body),
              installation.isWellFormed else { throw .badResponse }
        return installation
    }

    /// `PUT /v1/installs/<installId>/examples/<exampleId>/<file>`, with the token. A name the contract would refuse is
    /// refused here, before any request.
    public func upload(_ body: ShareRequest.Body, file: String, example: String, installation: ShareInstallation) async throws(ShareError) {
        guard Self.isExampleID(example), Self.isFileName(file) else { throw .badName }
        let request = ShareRequest(
            method: .put,
            url: url("v1", "installs", installation.installId, "examples", example, file),
            headers: [
                "Authorization": "Bearer \(installation.token)",
                "Content-Type": file.hasSuffix(".json") ? "application/json" : "audio/wav",
            ],
            body: body
        )
        let response = try await send(request)
        guard (200..<300).contains(response.status) else { throw ShareError(response) }
    }

    /// `DELETE /v1/installs/<installId>`, with the token. A 404 means it is gone already, which is what was asked.
    public func delete(_ installation: ShareInstallation) async throws(ShareError) {
        let request = ShareRequest(
            method: .delete, url: url("v1", "installs", installation.installId),
            headers: ["Authorization": "Bearer \(installation.token)"], allowsExpensiveNetwork: true
        )
        let response = try await send(request)
        guard (200..<300).contains(response.status) || response.status == 404 else { throw ShareError(response) }
    }

    // MARK: Names

    /// 8 to 64 characters of `[A-Za-z0-9_-]`.
    public static func isExampleID(_ id: String) -> Bool {
        (8...64).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
        }
    }

    /// `manifest.json`, `noise-floor.wav` or `run-1.wav` … `run-9.wav`.
    public static func isFileName(_ file: String) -> Bool {
        if file == "manifest.json" || file == "noise-floor.wav" { return true }
        return (1...9).contains { file == "run-\($0).wav" }
    }

    /// A new example id: 32 random lowercase hexadecimal digits, unrelated to the folder's name (which holds the time).
    public static func newExampleID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: Sending

    private func url(_ components: String...) -> URL {
        components.reduce(baseURL) { $0.appending(path: $1, directoryHint: .notDirectory) }
    }

    private func send(_ request: ShareRequest) async throws(ShareError) -> ShareResponse {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw Task.isCancelled ? .cancelled : .unreachable
        }
    }
}
