import Foundation
import ResoniqAudio
import ResoniqDiagnostics
import ResoniqDSP
import ResoniqStore
import Synchronization
import Testing

@testable import ResoniqShare

/// Kept recordings on disk, and transports that stand in for the service.
enum ShareFixtures {
    static let baseURL = URL(string: "https://share.example.test")!
    static let installation = ShareInstallation(installId: String(repeating: "a1", count: 16), token: String(repeating: "b2", count: 32))
    static let otherInstallation = ShareInstallation(installId: String(repeating: "c3", count: 16), token: String(repeating: "d4", count: 32))

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resoniq-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A finished three-run test with names everywhere a name can go.
    static func example(date: Date = Date(timeIntervalSince1970: 1_794_661_200)) -> RecordingExample {
        let rate = 48000.0
        let floorSamples = (0..<4800).map { Float(sin(Double($0) * 1.7)) * 1e-4 }
        let floor = NoiseFloor.measure(floorSamples, sampleRate: rate)
        let runs = (1...3).map { run in
            let samples = (0..<4800).map { Float(sin(Double($0) * 0.05 * Double(run))) * 0.2 }
            return RunRecording(
                run: run, samples: samples, sampleRate: rate, leadIn: 2400, arrivalDelay: 0.07,
                verdict: RecordingQuality.assess(recording: samples, noiseFloor: floor), spliceCount: 0, phoneMoved: false,
                attempt: 1, sweepTiedSound: nil, takeOffsets: [], measuredDelay: 0.071
            )
        }
        let result = MeasurementResult(
            channel: .left, sweep: LogSweep.measurement(sampleRate: rate), noiseFloor: floor, runs: runs,
            source: .thisPhone, noiseFloorSamples: floorSamples,
            outputRoute: AudioOutputRoute(kind: .airPlay, name: "Anna's Living Room"),
            inputRoute: AudioInputRoute(kind: .builtInMicrophone, name: "Anna's iPhone Microphone")
        )
        let silent = RecordingQuality.assess(recording: [Float](repeating: 0, count: 4800), noiseFloor: floor)
        let report = SpeakerDiagnosis.diagnose(runs: Array(repeating: RunAnalysis(verdict: silent, measurement: nil), count: 3), counterpart: nil)
        return RecordingExample(
            result: result, report: report, speaker: .left, systemName: "Anna's speakers", systemKind: .stereoPair,
            roomName: "Anna's den", date: date,
            device: .init(model: "iPhone18,2", systemName: "iOS", systemVersion: "26.1", appVersion: "0.1.0 (1)")
        )
    }

    /// A recordings store with `count` kept examples; their folder names, sorted.
    static func store(examples count: Int) throws -> (RecordingStore, [String]) {
        let store = RecordingStore(root: try directory())
        var names: [String] = []
        for index in 0..<count {
            let date = Date(timeIntervalSince1970: 1_794_661_200 + Double(index) * 60)
            let name = RecordingStore.folderName(date: date, speaker: .left)
            try store.write(example(date: date), named: name)
            names.append(name)
        }
        return (store, names.sorted())
    }

    /// The four files of a kept example, in the order the queue sends them.
    static let files = ["manifest.json", "noise-floor.wav", "run-1.wav", "run-2.wav", "run-3.wav"]
}

/// A transport that fails the test on any request: with sharing off, or no URL, nothing may reach it.
struct FailingTransport: ShareTransport {
    func send(_ request: ShareRequest) async throws -> ShareResponse {
        Issue.record("A request was made: \(request.method.rawValue) \(request.url)")
        throw ShareTransportFailure.unreachable
    }
}

/// A stand-in for the service: answers each request with `respond` and records it, with the body it carried.
final class StubTransport: ShareTransport {
    struct Sent: Sendable, Equatable {
        var request: ShareRequest
        /// The bytes of a `.data` or `.file` body, read when it was sent.
        var body: Data
    }

    private let log = Mutex<[Sent]>([])
    private let respond: @Sendable (ShareRequest, Int) -> Result<ShareResponse, any Error>

    /// `respond` gets the request and its 0-based index among all requests.
    init(_ respond: @escaping @Sendable (ShareRequest, Int) -> Result<ShareResponse, any Error>) {
        self.respond = respond
    }

    /// A service that works: makes `installation` and takes every file.
    static func working(_ installation: ShareInstallation = ShareFixtures.installation) -> StubTransport {
        StubTransport { request, _ in .success(StubTransport.success(request, installation)) }
    }

    static func success(_ request: ShareRequest, _ installation: ShareInstallation = ShareFixtures.installation) -> ShareResponse {
        switch request.method {
        case .post:
            ShareResponse(status: 201, body: Data("{\"installId\":\"\(installation.installId)\",\"token\":\"\(installation.token)\"}".utf8))
        case .put: ShareResponse(status: 201, body: Data("{\"ok\":true}".utf8))
        case .delete: ShareResponse(status: 200, body: Data("{\"ok\":true}".utf8))
        }
    }

    var sent: [Sent] { log.withLock { $0 } }
    var requests: [ShareRequest] { sent.map(\.request) }

    /// "PUT /v1/installs/…/examples/…/manifest.json", for reading a sequence at a glance.
    var lines: [String] { requests.map { "\($0.method.rawValue) \($0.url.path())" } }

    func send(_ request: ShareRequest) async throws -> ShareResponse {
        let body: Data = switch request.body {
        case .none: Data()
        case .data(let data): data
        case .file(let url): (try? Data(contentsOf: url)) ?? Data()
        }
        let index = log.withLock { log in
            log.append(Sent(request: request, body: body))
            return log.count - 1
        }
        return try respond(request, index).get()
    }
}

/// A switch the tests flip, standing in for `SharePreference.isOn`.
final class Switch: Sendable {
    private let value: Mutex<Bool>
    init(_ isOn: Bool) { value = Mutex(isOn) }
    var isOn: Bool {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// A clock the tests move.
final class TestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_794_700_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// A credential store that refuses every save, as the Keychain does for an app without its entitlement.
final class RefusingCredentials: ShareCredentialStore {
    struct Refused: Error {}
    func load() -> ShareInstallation? { nil }
    func save(_ installation: ShareInstallation) throws { throw Refused() }
    func delete() {}
}
