import Foundation
import ResoniqStore

/// Makes the sharing objects, or nothing. The app calls this once at launch; with no usable `RESONIQ_SHARE_URL` it
/// returns nil before the transport, the credentials or the queue are made, so no object that could open a connection
/// exists in that build.
public enum ShareSetup {
    public static func queue(
        configuration: ShareConfiguration?,
        recordings: RecordingStore?,
        transport: () -> any ShareTransport,
        credentials: () -> any ShareCredentialStore,
        isAllowed: @escaping @Sendable () -> Bool
    ) -> ShareQueue? {
        guard let configuration, let recordings else { return nil }
        return ShareQueue(
            client: ShareClient(baseURL: configuration.baseURL, transport: transport()),
            credentials: credentials(), recordings: recordings, isAllowed: isAllowed
        )
    }
}
