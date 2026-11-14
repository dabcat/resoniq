import Foundation
import Observation
import ResoniqShare
import ResoniqStore
import SwiftUI

/// "Share recordings for research" in this build: the person's choice, the queue's status for Settings, and the hooks
/// the Diagnose coordinator calls. Made at launch only when the build has a share URL (`ShareSetup` returns nil
/// otherwise), so a build without one has no model, no queue and no transport, and Settings shows no row.
///
/// Every call into the queue is a fire-and-forget task: nothing in a measurement waits on the network.
@Observable
final class ShareModel {
    /// Whether sharing is on (`SharePreference.isOn`).
    private(set) var isOn: Bool
    private(set) var status = ShareStatus()

    @ObservationIgnored private let queue: ShareQueue
    @ObservationIgnored private let preference: SharePreference
    @ObservationIgnored private let recordingPreference: RecordingPreference
    @ObservationIgnored private var listening: Task<Void, Never>?
    /// A debug screen's model keeps the status it was given.
    @ObservationIgnored private var isFixed = false

    /// The model of this build, or nil when its `RESONIQ_SHARE_URL` is empty (or there is no recordings folder).
    static func launch(recordings: RecordingStore?) -> ShareModel? {
        guard let queue = ShareSetup.queue(
            configuration: ShareConfiguration.main(), recordings: recordings,
            transport: { HTTPShareTransport() }, credentials: { KeychainShareCredentials() },
            isAllowed: { SharePreference().isOn }
        ) else { return nil }
        let model = ShareModel(queue: queue)
        // Launch: recordings swept away since last time leave the queue, and what is due is tried.
        Task {
            await queue.forgetMissing()
            await queue.start()
            await model.refresh()
        }
        return model
    }

    init(queue: ShareQueue, preference: SharePreference = SharePreference(), recordingPreference: RecordingPreference = RecordingPreference()) {
        self.queue = queue
        self.preference = preference
        self.recordingPreference = recordingPreference
        isOn = preference.isOn
        listening = Task { [weak self, queue] in
            for await status in queue.updates {
                self?.status = status
            }
        }
    }

    func refresh() async {
        guard !isFixed else { return }
        status = await queue.status()
    }

    // MARK: The choice

    /// The person confirmed the consent screen: sharing goes on, and so does "Keep recordings", which it needs.
    func confirmConsent() {
        preference.turnOn()
        recordingPreference.isOn = true
        isOn = true
        Task { [queue] in await queue.sharingTurnedOn() }
    }

    /// Off: nothing more is sent, the request in flight is cancelled.
    func turnOff() {
        preference.turnOff()
        isOn = false
        Task { [queue] in await queue.stop() }
    }

    /// "Send the recordings I already have".
    func sendExisting() {
        Task { [queue] in await queue.queueExisting() }
    }

    /// "Delete what I shared". False when the service could not be reached; nothing changed then.
    func deleteShared() async -> Bool {
        do {
            try await queue.deleteShared()
            await refresh()
            return true
        } catch {
            return false
        }
    }

    // MARK: Hooks

    /// A kept test's recording was written. Sent only if sharing was on when the test was kept, and still is.
    func recordingKept(_ folder: String, sharingWhenKept: Bool) {
        guard sharingWhenKept, isOn else { return }
        Task { [queue] in await queue.kept(folder) }
    }

    /// A kept test was discarded ("Don't keep").
    func recordingDiscarded(_ folder: String) {
        Task { [queue] in await queue.forget(folder) }
    }

    /// Recordings were deleted (all of them, or with results): the queue drops what is no longer on the phone.
    func recordingsDeleted() {
        Task { [queue] in
            await queue.forgetMissing()
            await self.refresh()
        }
    }

    /// The app came back to the foreground: what is due is tried.
    func becameActive() {
        Task { [queue] in await queue.start() }
    }
}

extension EnvironmentValues {
    /// Sharing, in a build that has it; nil otherwise, and Settings shows nothing about it.
    @Entry var shareModel: ShareModel?
}

#if DEBUG
extension ShareModel {
    /// A model for screenshots and previews whose queue can reach nothing: its transport fails every request and its
    /// preference is a throwaway defaults suite, so a tap in a debug screen sends nothing and changes nothing kept.
    static func preview(isOn: Bool, status: ShareStatus) -> ShareModel {
        let defaults = previewDefaults
        defaults.removePersistentDomain(forName: previewSuite)
        let preference = SharePreference(defaults: defaults)
        if isOn { preference.turnOn() }
        RecordingPreference(defaults: defaults).isOn = isOn
        let folder = URL.temporaryDirectory.appendingPathComponent("share-preview", isDirectory: true)
        let queue = ShareQueue(
            client: ShareClient(baseURL: URL(string: "https://share.invalid")!, transport: NoTransport()),
            credentials: MemoryShareCredentials(), recordings: RecordingStore(root: folder), isAllowed: { false }
        )
        let model = ShareModel(queue: queue, preference: preference, recordingPreference: RecordingPreference(defaults: defaults))
        model.listening?.cancel()
        model.status = status
        model.isFixed = true
        return model
    }

    static let previewSuite = "resoniq-share-preview"
    /// The defaults a debug screen's Settings reads (`.defaultAppStorage`), so its toggles match the model's.
    static var previewDefaults: UserDefaults { UserDefaults(suiteName: previewSuite) ?? .standard }

    /// Answers nothing: debug screens only.
    private struct NoTransport: ShareTransport {
        func send(_ request: ShareRequest) async throws -> ShareResponse {
            throw ShareTransportFailure.unreachable
        }
    }
}
#endif
