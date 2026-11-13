#if os(iOS)
import AVFAudio
#endif

/// Whether the app may record the microphone.
public enum MicrophoneAccess: Sendable, Hashable {
    /// Not asked yet.
    case undetermined
    case denied
    case granted
}

/// The microphone permission: its status and the system prompt.
public protocol MicrophonePermission: Sendable {
    var status: MicrophoneAccess { get }
    /// Shows the system prompt when the status is undetermined; returns whether access is granted.
    func request() async -> Bool
}

/// A permission with a fixed answer, for tests, previews, the simulator and the Mac.
public struct SimulatedMicrophonePermission: MicrophonePermission {
    public var status: MicrophoneAccess

    public init(_ status: MicrophoneAccess = .granted) {
        self.status = status
    }

    /// Grants an undetermined permission, as a user tapping Allow would.
    public func request() async -> Bool {
        status != .denied
    }
}

#if os(iOS)
/// The system's record permission, through `AVAudioApplication`.
public struct SystemMicrophonePermission: MicrophonePermission {
    public init() {}

    public var status: MicrophoneAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
    }

    public func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
#endif
