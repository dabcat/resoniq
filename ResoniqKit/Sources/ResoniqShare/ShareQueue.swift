import Foundation
import ResoniqStore

/// What Settings says about sharing.
public struct ShareStatus: Sendable, Equatable {
    /// Kept tests whose files have all been stored by the service.
    public var sent: Int
    /// Kept tests queued and not sent yet (failures that will be tried again included).
    public var waiting: Int
    /// Kept tests the service would not take (a file over its limit); never tried again.
    public var refused: Int
    /// Kept recordings on this phone that were never queued: kept before sharing was on, or after it was turned off.
    /// "Send the recordings I already have" queues them.
    public var notQueued: Int
    /// The last thing that went wrong, until something is sent again; nil when all is well.
    public var problem: ShareProblem?

    public init(sent: Int = 0, waiting: Int = 0, refused: Int = 0, notQueued: Int = 0, problem: ShareProblem? = nil) {
        self.sent = sent
        self.waiting = waiting
        self.refused = refused
        self.notQueued = notQueued
        self.problem = problem
    }
}

/// The last problem, in the words Settings needs to choose its sentence.
public enum ShareProblem: String, Sendable, Equatable, Codable {
    /// No Wi-Fi, or the service could not be reached: tried again later.
    case unreachable
    /// The service failed or asked to slow down: tried again later.
    case serviceError
    /// The installation is full (507): the queue stopped and waits for "Delete what I shared".
    case overQuota
    /// The service refused the installation even after making a new one: the queue stopped.
    case rejected
    /// A test the service would not take; the others go on.
    case refused
    /// This device could not keep the installation's token (the Keychain refused it): the queue stopped, and nothing
    /// was sent.
    case tokenNotKept
}

/// Which kept tests are waiting to be shared, which went and which failed, and the sending itself: the shared manifest
/// and then the audio of one example at a time, over `ShareClient`.
///
/// **Nothing goes without consent.** Every request is preceded by a check of `isAllowed` (the person's
/// `SharePreference`, read live), so turning sharing off stops the queue before its next request, and `stop()` cancels
/// the one in flight. A test is queued only by `kept(_:)` while sharing is on, or by `queueExisting()` when the person
/// asks ("Send the recordings I already have"); a recording kept while sharing was off is never queued by itself.
///
/// **State** is a small JSON file beside the recordings (`stateFile(for:)`), written after every change, so a queue
/// survives the app being closed. It holds folder names (local only) and the random example id each was given; the id
/// the service sees is never the folder's name, which holds the time.
///
/// **Failures** are tried again later with a backoff (`retryDelay(afterAttempts:)`), never in a tight loop: a drain ends
/// at the first failure and the app starts another at launch, when it comes back to the foreground and when a test is
/// kept. A 401 or 404 on upload means the installation is gone on the service: the queue makes a new one once and
/// stops if that is refused too. A 507 stops the queue until "Delete what I shared".
public actor ShareQueue {
    public static let stateFileName = ".share-queue.json"

    /// Where the state goes for the recordings in `store`: beside its `Recordings` folder, hidden from the Files app.
    public static func stateFile(for store: RecordingStore) -> URL {
        store.root.appendingPathComponent(stateFileName)
    }

    /// Seconds before a test that failed is tried again: one minute, doubling with each failure, at most six hours.
    public static func retryDelay(afterAttempts attempts: Int) -> TimeInterval {
        min(60 * pow(2, Double(max(attempts, 1) - 1)), 6 * 3600)
    }

    struct Entry: Codable, Equatable {
        enum Status: String, Codable { case waiting, sent, refused }

        var folder: String
        var exampleID: String
        var status: Status
        /// Files of this example already stored, so a drain that stopped halfway goes on from there.
        var sentFiles: [String]
        var attempts: Int
        var nextAttempt: Date?
    }

    struct State: Codable, Equatable {
        static let currentSchemaVersion = 1
        var schemaVersion = currentSchemaVersion
        var entries: [Entry] = []
        var problem: ShareProblem?
        /// Set by a 507 or a second refusal; the queue sends nothing while it is set.
        var stopped: ShareProblem?
    }

    private let client: ShareClient
    private let credentials: any ShareCredentialStore
    private let recordings: RecordingStore
    private let stateFile: URL
    private let isAllowed: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    private var state: State
    private var drainTask: Task<Void, Never>?
    private var drainGeneration = 0
    private var isDeleting = false
    private let continuation: AsyncStream<ShareStatus>.Continuation

    /// Every status after a change, for Settings. One reader.
    public nonisolated let updates: AsyncStream<ShareStatus>

    public init(
        client: ShareClient, credentials: any ShareCredentialStore, recordings: RecordingStore,
        stateFile: URL? = nil, isAllowed: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { .now }, calendar: Calendar = .current
    ) {
        self.client = client
        self.credentials = credentials
        self.recordings = recordings
        self.stateFile = stateFile ?? Self.stateFile(for: recordings)
        self.isAllowed = isAllowed
        self.now = now
        self.calendar = calendar
        state = Self.load(from: self.stateFile)
        (updates, continuation) = AsyncStream.makeStream(of: ShareStatus.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: Reading

    public func status() -> ShareStatus {
        let queued = Set(state.entries.map(\.folder))
        return ShareStatus(
            sent: state.entries.count { $0.status == .sent },
            waiting: state.entries.count { $0.status == .waiting },
            refused: state.entries.count { $0.status == .refused },
            notQueued: recordings.names().count { !queued.contains($0) },
            problem: state.stopped ?? state.problem
        )
    }

    // MARK: What is queued

    /// A test was kept and its recording written. Queued only while sharing is on; then a drain starts.
    public func kept(_ folder: String) {
        guard isAllowed(), recordings.contains(folder), !state.entries.contains(where: { $0.folder == folder }) else { return }
        state.entries.append(Entry(folder: folder, exampleID: ShareClient.newExampleID(), status: .waiting, sentFiles: [], attempts: 0))
        save()
        start()
    }

    /// "Send the recordings I already have": queues every kept recording not queued yet. Only while sharing is on.
    public func queueExisting() {
        guard isAllowed() else { return }
        let queued = Set(state.entries.map(\.folder))
        let new = recordings.names().filter { !queued.contains($0) }
        guard !new.isEmpty else { return }
        state.entries += new.map { Entry(folder: $0, exampleID: ShareClient.newExampleID(), status: .waiting, sentFiles: [], attempts: 0) }
        save()
        start()
    }

    /// The test was discarded or its recording deleted: it is not sent (what was already stored stays until "Delete
    /// what I shared").
    public func forget(_ folder: String) {
        guard state.entries.contains(where: { $0.folder == folder }) else { return }
        state.entries.removeAll { $0.folder == folder }
        save()
    }

    /// Drops every entry whose recording is no longer on the phone. Run at launch, after the recordings' sweep.
    public func forgetMissing() {
        let before = state.entries.count
        state.entries.removeAll { !recordings.contains($0.folder) }
        if state.entries.count != before { save() }
    }

    // MARK: Sending

    /// Starts a drain in the background unless one is running. Does nothing visible while sharing is off.
    public func start() {
        _ = startDrain()
    }

    /// Sends what is due now and returns when the drain ends: everything sent, the first failure, or sharing off.
    public func send() async {
        await startDrain().value
    }

    /// Sharing was turned on: a stop from before (507, a refused installation) is lifted, and a drain starts.
    public func sharingTurnedOn() {
        if state.stopped != nil {
            state.stopped = nil
            state.problem = nil
            save()
        }
        start()
    }

    /// Sharing was turned off: the request in flight is cancelled. The queue keeps what it holds.
    public func stop() {
        drainTask?.cancel()
    }

    private func startDrain() -> Task<Void, Never> {
        if let drainTask, !drainTask.isCancelled { return drainTask }
        let previous = drainTask
        drainGeneration += 1
        let generation = drainGeneration
        let task = Task {
            await previous?.value
            await drain()
            drainEnded(generation)
        }
        drainTask = task
        return task
    }

    private func drainEnded(_ generation: Int) {
        if generation == drainGeneration { drainTask = nil }
    }

    private var mayRequest: Bool {
        !Task.isCancelled && !isDeleting && isAllowed() && state.stopped == nil
    }

    private func drain() async {
        var registeredAgain = false
        while mayRequest, let folder = nextDue() {
            switch await send(folder, registeredAgain: &registeredAgain) {
            case .done: continue
            case .later: return
            }
        }
    }

    private func nextDue() -> String? {
        let date = now()
        return state.entries.first { $0.status == .waiting && ($0.nextAttempt ?? .distantPast) <= date }?.folder
    }

    private enum Outcome { case done, later }

    /// Sends one example: the shared manifest first, then the noise floor and the runs, each file once.
    private func send(_ folder: String, registeredAgain: inout Bool) async -> Outcome {
        guard recordings.contains(folder), let manifest = try? recordings.manifest(folder) else {
            forget(folder)
            return .done
        }
        let shared: Data
        do {
            shared = try RecordingManifest.encoder.encode(manifest.shared(calendar: calendar))
        } catch {
            mark(folder, .refused)
            return .done
        }
        let files: [(name: String, body: ShareRequest.Body)] =
            [(RecordingStore.manifestFileName, .data(shared))]
            + ([manifest.noiseFloor.file] + manifest.runs.map(\.file)).compactMap { file in
                recordings.fileURL(folder, file: file).map { (file, .file($0)) }
            }
        guard files.allSatisfy({ ShareClient.isFileName($0.name) }) else {
            mark(folder, .refused)
            return .done
        }
        // A file over the service's limit would be refused (413) every time: the test is not shareable, and is not sent.
        let sizes = files.map { file -> Int in
            switch file.body {
            case .data(let data): data.count
            case .file(let url): (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            case .none: 0
            }
        }
        guard sizes.allSatisfy({ $0 <= ShareClient.maximumFileSize }) else {
            mark(folder, .refused)
            state.problem = .refused
            save()
            return .done
        }

        var index = 0
        while index < files.count {
            let file = files[index]
            guard let current = entry(folder) else { return .done }
            if current.sentFiles.contains(file.name) {
                index += 1
                continue
            }
            guard mayRequest else { return .later }
            do throws(ShareError) {
                let installation = try await installation()
                guard mayRequest else { return .later }
                guard entry(folder) != nil else { return .done }
                // Discarded or deleted while the installation was made: the test is forgotten, not sent.
                guard recordings.contains(folder) else {
                    forget(folder)
                    return .done
                }
                try await client.upload(file.body, file: file.name, example: current.exampleID, installation: installation)
                update(folder) { $0.sentFiles.append(file.name) }
                index += 1
            } catch .unauthorized, .notFound {
                // The installation is gone on the service (deleted there): make a new one, once.
                guard !registeredAgain else {
                    stopQueue(.rejected)
                    return .later
                }
                registeredAgain = true
                credentials.delete()
                // What this example stored went with the old installation: send all of it again.
                update(folder) { $0.sentFiles = [] }
                index = 0
            } catch .overQuota {
                stopQueue(.overQuota)
                return .later
            } catch .tooLarge, .badName {
                mark(folder, .refused)
                state.problem = .refused
                save()
                return .done
            } catch .cancelled {
                return .later
            } catch .tokenNotKept {
                // Trying again would only make and delete another installation.
                stopQueue(.tokenNotKept)
                return .later
            } catch .rateLimited(let retryAfter) {
                failed(folder, .serviceError, notBefore: retryAfter)
                return .later
            } catch {
                failed(folder, error == .unreachable ? .unreachable : .serviceError)
                return .later
            }
        }
        mark(folder, .sent)
        state.problem = nil
        save()
        return .done
    }

    /// The installation in the Keychain, or a new one from the service.
    private func installation() async throws(ShareError) -> ShareInstallation {
        if let installation = credentials.load() { return installation }
        let installation = try await client.register()
        do {
            try credentials.save(installation)
        } catch {
            // A token that cannot be kept would make an installation nobody can delete: do not use it, and take it
            // off the service again while the token is still in hand, so a retry does not leave one behind each time.
            try? await client.delete(installation)
            throw .tokenNotKept
        }
        return installation
    }

    // MARK: Deleting

    /// "Delete what I shared": deletes the installation and everything in it on the service, forgets it here, and
    /// clears the queue (what was sent, and what was waiting: nothing kept before goes again unless asked). Works with
    /// sharing off. On a failure nothing here changes, so it can be tried again.
    public func deleteShared() async throws(ShareError) {
        isDeleting = true
        defer { isDeleting = false }
        drainTask?.cancel()
        await drainTask?.value
        if let installation = credentials.load() {
            try await client.delete(installation)
            credentials.delete()
        }
        state.entries.removeAll()
        state.problem = nil
        state.stopped = nil
        save()
    }

    // MARK: State

    private func entry(_ folder: String) -> Entry? {
        state.entries.first { $0.folder == folder }
    }

    private func update(_ folder: String, _ change: (inout Entry) -> Void) {
        guard let index = state.entries.firstIndex(where: { $0.folder == folder }) else { return }
        change(&state.entries[index])
        save()
    }

    private func mark(_ folder: String, _ status: Entry.Status) {
        update(folder) {
            $0.status = status
            $0.nextAttempt = nil
        }
    }

    /// Tries the test again after the backoff, or after `notBefore` seconds (the service's `Retry-After`) if later.
    private func failed(_ folder: String, _ problem: ShareProblem, notBefore: TimeInterval? = nil) {
        let date = now()
        update(folder) {
            $0.attempts += 1
            $0.nextAttempt = date.addingTimeInterval(max(Self.retryDelay(afterAttempts: $0.attempts), notBefore ?? 0))
        }
        state.problem = problem
        save()
    }

    private func stopQueue(_ problem: ShareProblem) {
        state.stopped = problem
        state.problem = problem
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateFile, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = stateFile
            try? url.setResourceValues(values)
        }
        continuation.yield(status())
    }

    private static func load(from url: URL) -> State {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(State.self, from: data),
              state.schemaVersion == State.currentSchemaVersion else { return State() }
        return state
    }

    // MARK: Tests

    func entries() -> [Entry] { state.entries }
}
