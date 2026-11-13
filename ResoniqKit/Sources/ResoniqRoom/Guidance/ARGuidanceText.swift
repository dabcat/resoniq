import Foundation

/// One instruction on the AR guide: the sentence and the line under it.
public struct ARGuidanceMessage: Sendable, Equatable {
    public var headline: String
    public var detail: String

    public init(headline: String, detail: String) {
        self.headline = headline
        self.detail = detail
    }
}

/// Every user-facing string of the AR guide that is not part of the readout (V3OAR and its states without a
/// mockup), in the design system's voice: first person, calm, specific, and honest about what the phone can see.
/// The readout's numbers and the V3OAR sentences are in `RoomText`.
public enum ARGuidanceText {
    // MARK: Before the target shows

    public static let findFloor = ARGuidanceMessage(
        headline: "Point the phone at the floor near the speaker.",
        detail: "Move it slowly from side to side until a dot settles on the floor.")

    public static let markSpeaker = ARGuidanceMessage(
        headline: "Put the dot on the floor at the middle of the speaker's front.",
        detail: "Stand in front of the speaker and face it, the way you face it from your seat.")

    /// Marking, with the centre of the screen off the floor.
    public static let markAimLower = ARGuidanceMessage(
        headline: "Put the dot on the floor at the middle of the speaker's front.",
        detail: "Aim a little lower, at the floor just in front of it.")

    // MARK: The steps

    /// The turn step's sentence: "Turn it 12° toward your seat until its front lines up with the blue outline."
    public static func turnInstruction(_ radians: Double) -> String {
        "Turn it \(RoomText.degrees(radians)) toward your seat until its front lines up with the blue outline."
    }

    /// Under the turn step: the phone does not see the speaker rotate, so the person judges it.
    public static let turnHint = "I can't see the speaker turn, so line it up by eye."
    public static let turnLabel = "Turn"
    public static let arrivedInstruction = "That's the spot. Leave it there."
    public static let slideProgressLabel = "Distance moved"

    /// The follow control over the camera, held while the dot is on the speaker's front.
    public static let followHold = "Hold while the dot is on its front"
    public static let following = "Following the speaker"
    /// VoiceOver's name for the follow control, which it toggles.
    public static let followLabel = "Follow the speaker"
    public static let followHint =
        "While this is on, the white outline follows the dot. Keep the dot on the middle of the speaker's front."

    // MARK: Buttons

    public static let markButton = "This is the speaker"
    public static let markAgain = "Mark it again"
    public static let cantMove = "Can't move it"
    public static let inPlace = "It's in place"
    public static let close = "Close AR guide"
    public static let allowCamera = "Allow camera"
    public static let openSettings = "Open Settings"
    public static let notNow = "Not now"
    public static let screenTitle = "Move the speaker"

    // MARK: Tracking

    /// What to say when tracking is not normal; nil when it is.
    public static func tracking(_ tracking: ARTracking) -> ARGuidanceMessage? {
        switch tracking {
        case .normal:
            nil
        case .interrupted:
            ARGuidanceMessage(
                headline: "The camera paused.",
                detail: "When it's back, point the phone where it was and I'll find my place.")
        case .limited(let issue):
            switch issue {
            case .initializing:
                ARGuidanceMessage(headline: "Getting my bearings.", detail: "Hold the phone up and move it slowly.")
            case .excessiveMotion:
                ARGuidanceMessage(
                    headline: "Slow down a little.", detail: "Moving the phone slowly keeps the outline in its place.")
            case .insufficientFeatures:
                ARGuidanceMessage(
                    headline: "I can't see enough detail.",
                    detail: "Plain, bare floors are hard for me to follow. Aim where there's a rug, a pattern or furniture.")
            case .tooDark:
                ARGuidanceMessage(
                    headline: "It's too dark for me to see the floor.", detail: "Turn on a light, then point at the floor again.")
            case .relocalizing:
                ARGuidanceMessage(
                    headline: "Finding my place again.",
                    detail: "Point the phone at the floor near the speaker, where you were before.")
            case .unavailable:
                ARGuidanceMessage(
                    headline: "I can't follow the room right now.",
                    detail: "Close the guide and try again in a moment.")
            }
        }
    }

    // MARK: States without a mockup

    public static let permissionHeadline = "I'll use the camera to show the spot on the floor."
    public static let permissionBody =
        "I draw an outline where the speaker should go. Nothing is recorded, and the camera stays on this iPhone."

    public static let deniedHeadline = "The camera is off for Resoniq."
    public static let deniedBody =
        "To see the outline on the floor, turn on Camera for Resoniq in Settings. Or move the speaker by hand and measure again."

    public static let unsupportedHeadline = "This iPhone can't show the outline."
    public static let unsupportedBody =
        "Showing the spot on the floor needs AR, which this iPhone doesn't have. Move the speaker by hand as the suggestion says, then measure again."
}
