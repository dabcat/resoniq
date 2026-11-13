import Foundation
import ResoniqAudio
import ResoniqStore

/// The words of the option "play the test sound from another device" that no Kit session owns: the files screen, the
/// entry links to it and the names a screen puts on a file. Every sentence about what is heard or measured while
/// listening is `ExternalSessionText`'s (ResoniqAudio); the files' own names and summaries are `TestSoundFile`'s.
///
/// In the design system's voice: first person, calm, specific. Said once here so the screens stay the same.
enum TestSoundText {
    // MARK: The files screen

    /// The kicker in the header.
    static let kicker = "Test sound"

    static let headline = "Play the test sound from another device."

    static let intro = "If your system can't take sound from this iPhone, I can write the test sound to a file for you to play on whatever "
        + "your speakers are connected to. I only listen. I know exactly what the file contains, so I can still measure your speakers."

    /// One line on which files the screen shows, for where it was opened from.
    static func contextLine(_ context: TestSoundContext) -> String {
        switch context {
        case .speaker(let choices):
            choices.count > 1
                ? "A speaker test takes one file for each speaker. Play the one for the speaker you're testing."
                : "A speaker test takes one file. It plays on both channels at once."
        case .seat:
            "At each of your three spots you play this one file once."
        case .everything:
            "Each file is for one job. When I ask for a test sound, I'll say which one."
        }
    }

    static let filesLabel = "The files"
    static let stepsLabel = "How it goes"

    static let steps = [
        "Get the file onto whatever plays your music: a laptop, a streamer, a USB stick.",
        "Play it through your system at your usual volume, as a WAV file, not converted.",
        "Come back here and I'll listen.",
    ]

    /// The two things this option cannot do, one sentence each.
    static let notes = [
        "I can't pause someone else's player, so if the room gets noisy during a run, you'll play the file again.",
        "A subwoofer on its own can't be tested this way.",
    ]

    static let primary = "I have the file"
    static let notNow = "Not now"
    static let done = "Done"

    static let share = "Share"
    static let shareAll = "Share all files"

    /// "Share the left speaker file", for VoiceOver.
    static func shareLabel(_ kind: TestSoundFile.Kind) -> String {
        "Share \(ExternalSessionText.fileTitle(for: kind))"
    }

    static let shareAllLabel = "Share all the files listed here"

    static let preparing = "Getting the files ready."
    static let writeFailed = "I couldn't write the files. Free up some space on this iPhone, then try again."
    static let tryAgain = "Try again"

    /// What a file is called on the screen, above its name: "Left speaker".
    static func title(_ kind: TestSoundFile.Kind) -> String {
        switch kind {
        case .speakerTest(.left): "Left speaker"
        case .speakerTest(.right): "Right speaker"
        case .speakerTest(.both): "Both speakers"
        case .seat(let channels): channels.count > 1 ? "Seat, two speakers" : "Seat, one speaker"
        }
    }

    // MARK: Listening

    /// The detail under the readout while nothing of the file has been heard.
    static let notHeardYet = "Not heard yet"
    /// The detail under the readout while the clock tone plays.
    static let startingTone = "Starting tone"
    /// The readout's label, where a normal test says "Playing now".
    static let hearingNow = "Hearing now"
    /// Under Three spots' headline while the phone is still or has just captured a spot.
    static let seatStillLine = "I'll tell you when to press play, once the phone is still."
    static let nextSpotLine = "Move the phone to the next spot, then press play again."
    /// The labels of the calm notices on the listening screens.
    static let hearingNoticeTitle = "What I hear"
    static let againNoticeTitle = "Play it again"
    static let stopListening = "Stop listening"
    static let stopMeasuring = "Stop measuring"

    // MARK: Entry links

    /// Under Aim's caption and Sit and aim's primary button.
    static let entryLink = "My speakers can't play from this iPhone"
    /// Beside "Try again" on the screen that says the sound would come from the iPhone.
    static let entryButton = "Play the test sound from another device"
    /// Settings, Measurement.
    static let settingsRow = "Test sound files"
    static let settingsNote = "The files to play from another device, when your system can't take sound from this iPhone."
}
