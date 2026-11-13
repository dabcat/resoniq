/// Every user-visible string that originates in the store, in one place.
public enum StoreText {
    /// The room used when the user has never named one.
    public static let defaultRoomName = "My room"
    /// The sound system used when the user has never named one.
    public static let defaultSystemName = "My speakers"
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
