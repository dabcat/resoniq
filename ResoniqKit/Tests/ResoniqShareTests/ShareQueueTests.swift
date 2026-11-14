import Foundation
import ResoniqStore
import Synchronization
import Testing

@testable import ResoniqShare

/// The queue, and the proof of the privacy claim: nothing is sent unless the person turned sharing on.
struct ShareQueueTests {
    private struct Rig {
        let store: RecordingStore
        let names: [String]
        let queue: ShareQueue
        let sharing: Switch
        let clock: TestClock
        let credentials: MemoryShareCredentials
    }

    private func rig(
        examples: Int = 1, sharing: Bool = true, transport: some ShareTransport,
        credentials: MemoryShareCredentials = MemoryShareCredentials(), stateFile: URL? = nil
    ) throws -> Rig {
        let (store, names) = try ShareFixtures.store(examples: examples)
        let sharing = Switch(sharing)
        let clock = TestClock()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let queue = ShareQueue(
            client: ShareClient(baseURL: ShareFixtures.baseURL, transport: transport), credentials: credentials,
            recordings: store, stateFile: stateFile, isAllowed: { sharing.isOn }, now: { clock.now }, calendar: utc
        )
        return Rig(store: store, names: names, queue: queue, sharing: sharing, clock: clock, credentials: credentials)
    }

    private func path(_ example: String, _ file: String) -> String {
        "PUT /v1/installs/\(ShareFixtures.installation.installId)/examples/\(example)/\(file)"
    }

    // MARK: Nothing without consent

    @Test func `with sharing off, keeping tests and launching the queue never calls the transport`() async throws {
        let rig = try rig(examples: 3, sharing: false, transport: FailingTransport())
        for name in rig.names { await rig.queue.kept(name) }
        await rig.queue.forgetMissing()
        await rig.queue.start()
        await rig.queue.queueExisting()
        await rig.queue.sharingTurnedOn()
        await rig.queue.send()
        #expect(await rig.queue.entries().isEmpty)
        #expect(await rig.queue.status() == ShareStatus(notQueued: 3))
    }

    @Test func `with no URL there is no queue, and no transport or credentials are even made`() throws {
        let (store, _) = try ShareFixtures.store(examples: 1)
        for text in [nil, "", "  ", "$(RESONIQ_SHARE_URL)"] {
            let queue = ShareSetup.queue(
                configuration: ShareConfiguration(baseURLString: text), recordings: store,
                transport: {
                    Issue.record("A transport was made")
                    return FailingTransport()
                },
                credentials: {
                    Issue.record("Credentials were made")
                    return MemoryShareCredentials()
                },
                isAllowed: { true }
            )
            #expect(queue == nil)
        }
    }

    @Test func `with sharing on, exactly the contract's requests go, in order, with the token and nothing else`() async throws {
        let transport = StubTransport.working()
        let rig = try rig(transport: transport)
        await rig.queue.kept(rig.names[0])
        await rig.queue.send()

        let example = try #require(await rig.queue.entries().first?.exampleID)
        #expect(transport.lines == ["POST /v1/installs"] + ShareFixtures.files.map { path(example, $0) })
        #expect(transport.requests[0].headers.isEmpty)
        for request in transport.requests.dropFirst() {
            #expect(Set(request.headers.keys) == ["Authorization", "Content-Type"])
            #expect(request.headers["Authorization"] == "Bearer \(ShareFixtures.installation.token)")
            #expect(!request.allowsExpensiveNetwork)
            // Nothing in the address says when or which speaker: the folder's name never goes.
            #expect(!request.url.absoluteString.contains(rig.names[0]))
        }
        #expect(rig.credentials.load() == ShareFixtures.installation)
        #expect(await rig.queue.status() == ShareStatus(sent: 1))
    }

    @Test func `the manifest sent is the shared one, and the audio is the files on disk`() async throws {
        let transport = StubTransport.working()
        let rig = try rig(transport: transport)
        await rig.queue.kept(rig.names[0])
        await rig.queue.send()

        let manifest = try #require(transport.sent.first { $0.request.url.lastPathComponent == "manifest.json" })
        let decoded = try RecordingManifest.decoder.decode(RecordingManifest.self, from: manifest.body)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(decoded == (try rig.store.manifest(rig.names[0])).shared(calendar: utc))
        let text = String(decoding: manifest.body, as: UTF8.self)
        #expect(!text.contains("Anna"))

        let audio = try #require(transport.sent.first { $0.request.url.lastPathComponent == "run-2.wav" })
        let file = try #require(rig.store.fileURL(rig.names[0], file: "run-2.wav"))
        #expect(audio.request.body == .file(file))
        #expect(audio.body == (try Data(contentsOf: file)))
    }

    @Test func `a recording kept before consent is not sent unless asked`() async throws {
        let transport = StubTransport.working()
        let rig = try rig(examples: 2, sharing: true, transport: transport)
        // Both were kept while sharing was off: never queued. Sharing is on now, and a drain runs.
        await rig.queue.sharingTurnedOn()
        await rig.queue.send()
        #expect(transport.requests.isEmpty)
        #expect(await rig.queue.status().notQueued == 2)

        await rig.queue.queueExisting()
        await rig.queue.send()
        #expect(transport.requests.count == 1 + 2 * ShareFixtures.files.count)
        #expect(await rig.queue.status() == ShareStatus(sent: 2))
    }

    @Test func `asking to send the old ones does nothing while sharing is off`() async throws {
        let rig = try rig(examples: 2, sharing: false, transport: FailingTransport())
        await rig.queue.queueExisting()
        await rig.queue.send()
        #expect(await rig.queue.entries().isEmpty)
    }

    @Test func `the queue stops at once when sharing goes off`() async throws {
        // Sharing goes off while the second file is on its way: nothing after it is sent.
        let sharing = Switch(true)
        let transport = StubTransport { request, index in
            if index == 2 { sharing.isOn = false }
            return .success(StubTransport.success(request))
        }
        let (store, _) = try ShareFixtures.store(examples: 2)
        let queue = ShareQueue(
            client: ShareClient(baseURL: ShareFixtures.baseURL, transport: transport), credentials: MemoryShareCredentials(),
            recordings: store, stateFile: nil, isAllowed: { sharing.isOn }
        )
        await queue.queueExisting()
        await queue.send()
        #expect(transport.requests.count == 3)
        await queue.start()
        await queue.send()
        #expect(transport.requests.count == 3)
        #expect(await queue.status().waiting == 2)

        // On again: it goes on from the file after the last one stored.
        sharing.isOn = true
        await queue.send()
        #expect(transport.requests.count == 1 + 2 * ShareFixtures.files.count)
        #expect(await queue.status() == ShareStatus(sent: 2))
    }

    @Test func `stop cancels the request in flight`() async throws {
        let transport = SlowTransport()
        let rig = try rig(transport: transport, credentials: MemoryShareCredentials(ShareFixtures.installation))
        await rig.queue.kept(rig.names[0])
        await transport.started.wait()
        rig.sharing.isOn = false
        await rig.queue.stop()
        await rig.queue.send()
        #expect(transport.count == 1)
        // A cancel is not a failure: no backoff, no problem.
        let entry = try #require(await rig.queue.entries().first)
        #expect(entry.attempts == 0 && entry.nextAttempt == nil)
        #expect(await rig.queue.status().problem == nil)
    }

    // MARK: Removing

    @Test func `removing a test removes it from the queue`() async throws {
        let rig = try rig(examples: 2, sharing: true, transport: StubTransport { _, _ in .failure(ShareTransportFailure.unreachable) })
        await rig.queue.kept(rig.names[0])
        await rig.queue.kept(rig.names[1])
        await rig.queue.send()
        await rig.queue.forget(rig.names[0])
        #expect(await rig.queue.entries().map(\.folder) == [rig.names[1]])
        // A recording deleted from disk (Delete recordings) is dropped at the next launch.
        rig.store.delete(rig.names[1])
        await rig.queue.forgetMissing()
        #expect(await rig.queue.entries().isEmpty)
    }

    @Test func `a recording gone from disk before it is sent is dropped, not sent`() async throws {
        // The test is discarded while the installation is being made.
        let holder = Mutex<RecordingStore?>(nil)
        let folder = Mutex("")
        let transport = StubTransport { request, _ in
            if request.method == .post, let store = holder.withLock({ $0 }) { store.delete(folder.withLock { $0 }) }
            return .success(StubTransport.success(request))
        }
        let rig = try rig(examples: 1, transport: transport)
        holder.withLock { $0 = rig.store }
        folder.withLock { $0 = rig.names[0] }
        await rig.queue.kept(rig.names[0])
        await rig.queue.send()
        #expect(transport.lines == ["POST /v1/installs"])
        #expect(await rig.queue.entries().isEmpty)
    }

    // MARK: Failures

    @Test func `a failure is tried again later, with a backoff`() async throws {
        let down = Switch(true)
        let transport = StubTransport { request, _ in
            down.isOn ? .failure(ShareTransportFailure.unreachable) : .success(StubTransport.success(request))
        }
        let rig = try rig(transport: transport)
        await rig.queue.kept(rig.names[0])
        await rig.queue.send()
        #expect(transport.requests.count == 1)
        #expect(await rig.queue.status() == ShareStatus(waiting: 1, problem: .unreachable))

        // Not before its time.
        await rig.queue.send()
        #expect(transport.requests.count == 1)
        rig.clock.advance(61)
        await rig.queue.send()
        #expect(transport.requests.count == 2)
        // The second failure waits twice as long.
        rig.clock.advance(61)
        await rig.queue.send()
        #expect(transport.requests.count == 2)
        rig.clock.advance(60)
        down.isOn = false
        await rig.queue.send()
        #expect(await rig.queue.status() == ShareStatus(sent: 1))
    }

    @Test func `the backoff doubles and stops growing at six hours`() {
        #expect(ShareQueue.retryDelay(afterAttempts: 1) == 60)
        #expect(ShareQueue.retryDelay(afterAttempts: 2) == 120)
        #expect(ShareQueue.retryDelay(afterAttempts: 5) == 960)
        #expect(ShareQueue.retryDelay(afterAttempts: 30) == 6 * 3600)
    }

    @Test(arguments: [401, 404])
    func `an installation deleted on the service is made again once, then the queue stops`(status: Int) async throws {
        // The kept token is refused; the new one is refused too.
        let transport = StubTransport { request, _ in
            request.method == .put ? .success(ShareResponse(status: status)) : .success(StubTransport.success(request, ShareFixtures.otherInstallation))
        }
        let rig = try rig(transport: transport, credentials: MemoryShareCredentials(ShareFixtures.installation))
        await rig.queue.kept(rig.names[0])
        await rig.queue.send()
        #expect(transport.lines.map { String($0.prefix(4)) } == ["PUT ", "POST", "PUT "])
        #expect(transport.requests[2].headers["Authorization"] == "Bearer \(ShareFixtures.otherInstallation.token)")
        #expect(await rig.queue.status().problem == .rejected)

        // Stopped: later drains send nothing.
        rig.clock.advance(24 * 3600)
        await rig.queue.send()
        #expect(transport.requests.count == 3)
    }

    @Test func `after a new installation the example is sent whole again`() async throws {
        // The first token works for the manifest, then the service forgets it.
        let transport = StubTransport { request, index in
            if request.method == .post { return .success(StubTransport.success(request, ShareFixtures.otherInstallation)) }
            return index == 1 ? .success(ShareResponse(status: 401)) : .success(StubTransport.success(request))
        }
        let rig = try rig(transport: transport, credentials: MemoryShareCredentials(ShareFixtures.installation))
        await rig.queue.kept(rig.names[0])
        await rig.queue.send()
        let puts = transport.requests.filter { $0.method == .put }.map(\.url.lastPathComponent)
        #expect(puts == ["manifest.json", "noise-floor.wav"] + ShareFixtures.files)
        #expect(rig.credentials.load() == ShareFixtures.otherInstallation)
        #expect(await rig.queue.status() == ShareStatus(sent: 1))
    }

    @Test func `over quota stops the queue and says so, and is not retried`() async throws {
        let transport = StubTransport { request, _ in
            request.method == .put ? .success(ShareResponse(status: 507)) : .success(StubTransport.success(request))
        }
        let rig = try rig(examples: 2, transport: transport)
        await rig.queue.kept(rig.names[0])
        await rig.queue.kept(rig.names[1])
        await rig.queue.send()
        #expect(transport.requests.count == 2)
        #expect(await rig.queue.status() == ShareStatus(waiting: 2, problem: .overQuota))
        for _ in 0..<5 {
            rig.clock.advance(24 * 3600)
            await rig.queue.start()
            await rig.queue.send()
        }
        #expect(transport.requests.count == 2)
    }

    @Test func `a file over the limit refuses that test and the next one goes`() async throws {
        let transport = StubTransport { request, index in
            index == 2 ? .success(ShareResponse(status: 413)) : .success(StubTransport.success(request))
        }
        let rig = try rig(examples: 2, transport: transport)
        await rig.queue.kept(rig.names[0])
        await rig.queue.kept(rig.names[1])
        await rig.queue.send()
        let status = await rig.queue.status()
        #expect(status.refused == 1 && status.sent == 1)
    }

    @Test func `a file over four megabytes is not sent, and the test is marked as not shareable`() async throws {
        let transport = StubTransport.working()
        let rig = try rig(examples: 2, transport: transport)
        let big = try #require(rig.store.fileURL(rig.names[0], file: "run-2.wav"))
        try Data(count: ShareClient.maximumFileSize + 1).write(to: big)
        await rig.queue.kept(rig.names[0])
        await rig.queue.kept(rig.names[1])
        await rig.queue.send()
        // Only the other test went: nothing of the one with the large file.
        #expect(transport.requests.count == 1 + ShareFixtures.files.count)
        let status = await rig.queue.status()
        #expect(status.refused == 1 && status.sent == 1)
        #expect(status.problem == nil)
        #expect(ShareClient.maximumFileSize == 4_194_304)
    }

    @Test func `a rate limit waits at least as long as the service asks`() async throws {
        let transport = StubTransport { _, _ in .success(ShareResponse(status: 429, retryAfter: 900)) }
        let rig = try rig(transport: transport)
        await rig.queue.kept(rig.names[0])
        await rig.queue.send()
        let entry = try #require(await rig.queue.entries().first)
        #expect(entry.nextAttempt == rig.clock.now.addingTimeInterval(900))
    }

    @Test func `a rate limit or a server error is tried again later`() async throws {
        for status in [429, 500] {
            let transport = StubTransport { _, _ in .success(ShareResponse(status: status)) }
            let rig = try rig(transport: transport)
            await rig.queue.kept(rig.names[0])
            await rig.queue.send()
            #expect(await rig.queue.status() == ShareStatus(waiting: 1, problem: .serviceError))
            #expect(await rig.queue.entries().first?.nextAttempt != nil)
        }
    }

    // MARK: Deleting

    @Test func `delete what I shared deletes on the service, forgets the installation and clears the queue`() async throws {
        let transport = StubTransport.working()
        let rig = try rig(examples: 2, transport: transport)
        await rig.queue.kept(rig.names[0])
        await rig.queue.send()
        rig.sharing.isOn = false
        await rig.queue.kept(rig.names[1])

        try await rig.queue.deleteShared()
        #expect(transport.lines.last == "DELETE /v1/installs/\(ShareFixtures.installation.installId)")
        #expect(transport.requests.last?.headers == ["Authorization": "Bearer \(ShareFixtures.installation.token)"])
        #expect(rig.credentials.load() == nil)
        #expect(await rig.queue.entries().isEmpty)
        #expect(await rig.queue.status() == ShareStatus(notQueued: 2))
    }

    @Test func `delete with nothing shared makes no request`() async throws {
        let rig = try rig(sharing: false, transport: FailingTransport())
        try await rig.queue.deleteShared()
    }

    @Test func `a delete that fails changes nothing, so it can be tried again`() async throws {
        let transport = StubTransport { request, _ in
            request.method == .delete ? .failure(ShareTransportFailure.unreachable) : .success(StubTransport.success(request))
        }
        let rig = try rig(transport: transport)
        await rig.queue.kept(rig.names[0])
        await rig.queue.send()
        await #expect(throws: ShareError.unreachable) { try await rig.queue.deleteShared() }
        #expect(rig.credentials.load() == ShareFixtures.installation)
        #expect(await rig.queue.status().sent == 1)
    }

    @Test func `deleting lifts an over-quota stop`() async throws {
        let full = Switch(true)
        let transport = StubTransport { request, _ in
            request.method == .put && full.isOn ? .success(ShareResponse(status: 507)) : .success(StubTransport.success(request))
        }
        let rig = try rig(examples: 1, transport: transport)
        await rig.queue.kept(rig.names[0])
        await rig.queue.send()
        try await rig.queue.deleteShared()
        full.isOn = false
        #expect(await rig.queue.status().problem == nil)
        await rig.queue.queueExisting()
        await rig.queue.send()
        #expect(await rig.queue.status().sent == 1)
    }

    // MARK: State

    @Test func `the queue survives a relaunch, beside the recordings`() async throws {
        let transport = StubTransport { request, index in
            index < 3 ? .success(StubTransport.success(request)) : .failure(ShareTransportFailure.unreachable)
        }
        let rig = try rig(examples: 1, transport: transport)
        await rig.queue.kept(rig.names[0])
        await rig.queue.send()
        let file = ShareQueue.stateFile(for: rig.store)
        #expect(file.deletingLastPathComponent() == rig.store.root)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let again = StubTransport.working()
        let relaunched = ShareQueue(
            client: ShareClient(baseURL: ShareFixtures.baseURL, transport: again), credentials: rig.credentials,
            recordings: rig.store, isAllowed: { true }, now: { Date.distantFuture }
        )
        await relaunched.send()
        // The manifest and the floor went before; the runs go now.
        #expect(again.requests.map(\.url.lastPathComponent) == ["run-1.wav", "run-2.wav", "run-3.wav"])
        #expect(await relaunched.status() == ShareStatus(sent: 1))
    }

    @Test func `the state file holds no name and no folder's time in what it would send`() async throws {
        let rig = try rig(transport: StubTransport.working())
        await rig.queue.kept(rig.names[0])
        let text = String(decoding: try Data(contentsOf: ShareQueue.stateFile(for: rig.store)), as: UTF8.self)
        #expect(!text.contains("Anna"))
        #expect(!text.contains(ShareFixtures.installation.token))
    }

    @Test func `updates report each change`() async throws {
        let rig = try rig(transport: StubTransport.working())
        await rig.queue.kept(rig.names[0])
        await rig.queue.send()
        var iterator = rig.queue.updates.makeAsyncIterator()
        #expect(await iterator.next() == ShareStatus(sent: 1))
    }
}

/// A transport that waits until it is cancelled, so a test can stop a request in flight.
final class SlowTransport: ShareTransport {
    let started = Signal()
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }

    func send(_ request: ShareRequest) async throws -> ShareResponse {
        calls.withLock { $0 += 1 }
        started.fire()
        try await Task.sleep(for: .seconds(60))
        return ShareResponse(status: 201)
    }
}

/// Fires once; `wait()` returns when it has.
final class Signal: Sendable {
    private let state = Mutex<(fired: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func fire() {
        let waiters = state.withLock { state in
            state.fired = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let fired = state.withLock { state in
                if !state.fired { state.waiters.append(continuation) }
                return state.fired
            }
            if fired { continuation.resume() }
        }
    }
}
