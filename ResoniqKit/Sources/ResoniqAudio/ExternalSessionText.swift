import Foundation

// The words of the listening sessions, when another device plays the test sound and the phone only listens. As in
// `SessionText.swift`: about the session alone, English, in one place, in the design system's voice (first person,
// calm, plain words; say what will happen and what to do).

/// What the screens say about the test sound files and the listening sessions.
public enum ExternalSessionText {
    // MARK: The files

    /// The name to save a file under.
    public static func fileName(for kind: TestSoundFile.Kind) -> String {
        switch kind {
        case .speakerTest(.left): "Resoniq test sound - left speaker.wav"
        case .speakerTest(.right): "Resoniq test sound - right speaker.wav"
        case .speakerTest(.both): "Resoniq test sound - both speakers.wav"
        case .seat(let channels): channels.count > 1 ? "Resoniq seat sound - left then right.wav" : "Resoniq seat sound - one speaker.wav"
        }
    }

    /// A short name for a file in a sentence: "the left speaker file".
    public static func fileTitle(for kind: TestSoundFile.Kind) -> String {
        switch kind {
        case .speakerTest(.left): "the left speaker file"
        case .speakerTest(.right): "the right speaker file"
        case .speakerTest(.both): "the both speakers file"
        case .seat(let channels): channels.count > 1 ? "the seat file for two speakers" : "the seat file for one speaker"
        }
    }

    /// One line on what a file is for, with its length in whole seconds.
    public static func fileSummary(for kind: TestSoundFile.Kind, duration: Double) -> String {
        let length = "About \(Int(duration.rounded())) seconds."
        return switch kind {
        case .speakerTest(.left): "Three sweeps on the left speaker, for testing it. \(length)"
        case .speakerTest(.right): "Three sweeps on the right speaker, for testing it. \(length)"
        case .speakerTest(.both): "Three sweeps on both speakers at once, for a single speaker or a mono system. \(length)"
        case .seat(let channels):
            channels.count > 1
                ? "One sweep on the left speaker, then one on the right, played once at each spot. \(length)"
                : "One sweep on both channels, played once at each spot. \(length)"
        }
    }

    /// What every file starts with and why, for the screen that hands the files over.
    public static let fileNote = "Each file starts with a few seconds of silence and a short steady tone, then the sweeps. "
        + "Play the WAV file itself, not a converted copy, at the volume you'd normally listen at."

    // MARK: A speaker test

    /// The headline of the listening screen.
    public static func headline(for state: ExternalMeasurementSession.State, runCount: Int) -> String {
        switch state {
        case .idle, .measuringNoiseFloor: "Stay quiet while I listen to the room."
        case .waitingForSound: "Press play now."
        case .hearing(let run): "Listening to run \(run) of \(runCount)."
        case .checking: "Checking that run."
        case .needsAnotherPlay: "Play the file once more."
        case .finished: "All \(runCount) runs are in."
        case .failed: ""
        }
    }

    /// The line under the headline while waiting for the sound. After `ExternalListening.nothingHeardHint` of silence
    /// it says what to check.
    public static func waitingLine(isSilenceLong: Bool, file: TestSoundFile.Kind) -> String {
        isSilenceLong
            ? "I can't hear the test sound yet. Check that \"\(fileName(for: file))\" is playing, that the volume is up and that your amplifier is on the right input."
            : "Play \"\(fileName(for: file))\" on your system. I'll find the tones by myself, whenever they start."
    }

    /// While the tone or a sweep is heard.
    public static let hearingLine = "Stay quiet while it plays."
    /// While the clock tone is heard, before the first sweep.
    public static let toneLine = "I can hear your player. The sweeps start in a moment."

    /// Why the file must be played again, with what is in hand ("I have 2 of 3 runs."). `file` is the file the
    /// session listens for.
    public static func anotherPlayText(_ problem: ExternalPlayProblem?, have: Int, needed: Int, file: TestSoundFile.Kind) -> String {
        let count = have > 0 ? "I have \(have) of \(needed). " : ""
        return count + reason(problem, file: file)
    }

    static func reason(_ problem: ExternalPlayProblem?, file: TestSoundFile.Kind) -> String {
        let again = "play the file again from the start."
        switch problem {
        case .run(.unusable(let verdict)):
            switch verdict {
            case .clipped: return "One was too loud and the microphone clipped it. Turn the volume down a little, then \(again)"
            case .tooQuiet: return "One was too quiet to read. Turn the volume up a little, then \(again)"
            case .tooNoisy: return "The room was too noisy to read one of them. When it's quiet, \(again)"
            case .corrupt: return "One didn't come through whole. Please \(again)"
            case .silent, .valid: return "I couldn't hear one of them properly. Please \(again)"
            }
        case .run(.didNotArrive), .missedSweeps:
            return "I missed part of it. Please \(again) and let it run to the end."
        case .run(.interruptedRepeatedly):
            return "Noise kept getting in the way. When it's quiet, \(again)"
        case .wrongFile(let heard):
            return "That sounds like \(fileTitle(for: heard)). Please play \"\(fileName(for: file))\" instead."
        case .clockUnknown:
            return "I missed the short tone at the start, which tells me how fast your player runs. Please play the file again from the very start."
        case nil:
            return "Please \(again)"
        }
    }

    // MARK: A seat measurement

    /// The headline of Three spots while listening; the waits for the phone are `SeatSessionText`'s.
    public static func seatHeadline(for state: ExternalSeatMeasurementSession.State, wait: SeatWaitPhase?, channels: [SpeakerChannel]) -> String {
        switch state {
        case .idle, .measuringNoiseFloor: "Stay quiet while I listen to the room."
        case .waitingForStillness(let spot):
            SeatSessionText.instruction(for: .waitingForStillness(spot: spot), wait: wait, channels: channels)
        case .waitingForSound: "Press play now."
        case .hearing(_, let channel):
            channel.map { "Hold still. The \(SeatSessionText.speakerWord($0, of: channels)) is playing." } ?? "Hold still. The tones are playing."
        case .checking: "Hold still. Checking that one."
        case .needsAnotherPlay: "Play the file again at this spot."
        case .spotCaptured(let spot): "Got the \(SeatSessionText.spotName(spot)) spot."
        case .finished: "All three spots are in."
        case .failed: ""
        }
    }

    /// The line under the headline while waiting for the sound at a spot.
    public static func seatWaitingLine(isSilenceLong: Bool, file: TestSoundFile.Kind) -> String {
        isSilenceLong
            ? waitingLine(isSilenceLong: true, file: file)
            : "Hold the phone still and play \"\(fileName(for: file))\". I'll find the tones by myself."
    }

    /// Why the seat file must be played again at this spot.
    public static func seatAnotherPlayText(_ problem: ExternalPlayProblem?, file: TestSoundFile.Kind) -> String {
        reason(problem, file: file)
    }

    // MARK: When it ends without a result

    /// Empty for `cancelled`, which shows no message.
    public static func failureHeadline(_ failure: ExternalMeasurementFailure) -> String {
        switch failure {
        case .nothingHeard: "I never heard the test sound."
        case .playerClockOff: "Your player changes the test sound."
        case .listeningTimeUp: "I couldn't get enough clean recordings."
        case .measurement(let failure):
            switch failure {
            case .permissionDenied: "I can't hear without the microphone."
            case .interrupted: "Something else took the sound."
            case .routeChanged: "The microphone changed while I was listening."
            case .audioUnavailable: "I couldn't start listening."
            case .tooNoisy: "The room stayed too noisy."
            case .phoneNeverStill: "The phone never settled."
            case .recordingUnusable: "I couldn't get a clean recording."
            case .speakersNotConnected: "The sound is coming from the iPhone itself."
            case .cancelled: ""
            }
        }
    }

    public static func failureBody(_ failure: ExternalMeasurementFailure, file: TestSoundFile.Kind) -> String {
        switch failure {
        case .nothingHeard:
            return "I listened for a minute and heard nothing of the test sound. Check that \"\(fileName(for: file))\" is playing "
                + "on the system your speakers are connected to, that the volume is up and that the amplifier is on the right input, then try again."
        case .playerClockOff(let ratio):
            let percent = String(format: "%.1f", abs(ratio - 1) * 100)
            return "It plays the file \(percent) % \(ratio > 1 ? "fast" : "slow"), so every tone comes out at the wrong pitch and I can't measure it. "
                + "Play the WAV file itself on another player, without converting it, and try again."
        case .listeningTimeUp(let problem):
            return "I listened for five minutes without enough usable recordings, so I stopped. "
                + (problem.map { reason($0, file: file) + " " } ?? "")
                + "Try again when you're ready."
        case .measurement(let failure):
            switch failure {
            case .permissionDenied:
                return "I listen to the test sound to measure your speakers, so I need the microphone. Sound stays on this iPhone. You can allow it in Settings."
            case .interrupted:
                return "A call, an alarm or another app used the audio, so I stopped listening. Nothing was kept."
            case .routeChanged:
                return "The microphone switched partway, so I stopped. Nothing was kept."
            case .audioUnavailable:
                return "This iPhone wouldn't let me use the microphone just now. Close anything else that records sound, then try again."
            case .tooNoisy:
                return "The room never got quiet enough for me to measure, so I stopped. Try again when it is quieter."
            case .phoneNeverStill:
                return SeatSessionText.failureBody(.phoneNeverStill)
            case .recordingUnusable, .speakersNotConnected, .cancelled:
                return ""
            }
        }
    }
}
