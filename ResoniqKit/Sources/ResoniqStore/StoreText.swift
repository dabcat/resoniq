/// Every user-visible string that originates in the store, in one place.
public enum StoreText {
    /// The room used when the user has never named one.
    public static let defaultRoomName = "My room"
    /// The sound system used when the user has never named one.
    public static let defaultSystemName = "My speakers"

    /// The title of every alert about a save that failed.
    public static let saveFailedTitle = "I couldn't save that"
    /// A seat measurement finished but could not be written down: it stays on Measure home, unsaved.
    public static let measurementNotSaved =
        "The phone wouldn't let me write this measurement down. It stays on screen until you measure again, but it isn't saved. Free up some space, then measure again."
}

extension SoundSystemKind {
    /// How the kind is named on screen. Nothing about make or model is ever asked.
    public var displayName: String {
        switch self {
        case .stereoPair: "Stereo pair"
        case .stereoWithSubwoofer: "Stereo + subwoofer"
        case .soundbar: "Soundbar"
        case .singleSpeaker: "Single speaker"
        case .surround: "Surround"
        }
    }
}

extension SpeakerPosition {
    /// How the speaker is named on screen.
    public var displayName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .single: "Single"
        }
    }
}
