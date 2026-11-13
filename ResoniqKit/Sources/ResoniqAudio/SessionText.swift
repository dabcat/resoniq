import Foundation

// The words that say what is happening in a measurement, chosen from the session's own states and readings. They
// are about the session alone (a state, a note, a failure, a level), so they live here rather than in the
// diagnostics module, which says what the recordings mean. English, in one place so it can be localised; the
// voice is the design system's: first person, calm, plain words.

/// The live readings under "Playing now" and on the Paused screens, for both sessions.
public enum ReadingText {
    /// The "Playing now" figure and its unit: "90" "Hz" under 1 kHz (whole hertz), "1.02" "kHz" under 10 kHz,
    /// "14.5" "kHz" above. A decimal point, whatever the locale, as everywhere else in the Kit's text.
    public static func frequencyReading(_ hertz: Double) -> (value: String, unit: String) {
        if hertz < 1_000 { return (String(Int(hertz.rounded())), "Hz") }
        let kilohertz = hertz / 1_000
        return (String(format: kilohertz < 10 ? "%.2f" : "%.1f", kilohertz), "kHz")
    }

    /// "34 dB": the approximate level (`SoundLevel.approximateDecibels`), whole decibels.
    public static func decibels(_ level: SoundLevel) -> String {
        "\(Int(level.approximateDecibels.rounded())) dB"
    }

    /// "Quiet · 34 dB" or "Noisy · 52 dB": the session's quiet-enough decision (`isRoomQuiet`) and the level.
    public static func room(_ level: SoundLevel, isQuiet: Bool) -> String {
        "\(isQuiet ? "Quiet" : "Noisy") · \(decibels(level))"
    }

    /// What VoiceOver reads for the room reading: "Room: quiet, about 34 decibels."
    public static func spokenRoom(_ level: SoundLevel, isQuiet: Bool) -> String {
        "Room: \(isQuiet ? "quiet" : "noisy"), about \(Int(level.approximateDecibels.rounded())) decibels."
    }

    /// "Steady", "Moving".
    public static func phone(isSteady: Bool) -> String { isSteady ? "Steady" : "Moving" }

    /// What a result says when the phone moved while a run played (`RunRecording.phoneMoved`): the run is kept, not
    /// failed, so the line says so and asks for a little care. Nil when no run moved. `runs` are 1-based.
    ///
    /// - "The phone moved while run 2 played. I kept that run, so read its details with a little care."
    /// - "The phone moved while runs 1 and 3 played. I kept them, so read the details with a little care."
    public static func phoneMovedNote(runs: [Int]) -> String? {
        let moved = Array(Set(runs)).sorted()
        switch moved.count {
        case 0:
            return nil
        case 1:
            return "The phone moved while run \(moved[0]) played. I kept that run, so read its details with a little care."
        default:
            let numbers = moved.map(String.init)
            let list = numbers.dropLast().joined(separator: ", ") + " and " + numbers[numbers.count - 1]
            return "The phone moved while runs \(list) played. I kept them, so read the details with a little care."
        }
    }

    /// What the line above rests on, for its evidence tag: the phone's own motion sensor.
    public static let phoneMovedBasis = "the phone's motion sensor"

    /// The approximate level at the right end of the room-noise bar, dB. Chosen so the mockup's 52 dB sits at 78 %
    /// of the bar and its quiet-enough mark at 55 %, a mark near 37 dB, just above a quiet living room.
    public static let roomNoiseScaleDecibels: Float = 70

    /// How far along the room-noise bar `level` sits, 0 to 1: its approximate level over `roomNoiseScaleDecibels`,
    /// held at the ends.
    public static func barFraction(_ level: SoundLevel) -> Double {
        min(max(Double(level.approximateDecibels / roomNoiseScaleDecibels), 0), 1)
    }
}

/// What the Three spots screens say is happening in a seat measurement, from its state.
public enum SeatSessionText {
    /// "seat", "left", "right".
    public static func spotName(_ spot: SeatSpot) -> String {
        switch spot {
        case .seat: "seat"
        case .left: "left"
        case .right: "right"
        }
    }

    /// "left speaker", "right speaker"; "speaker" when one speaker plays.
    public static func speakerWord(_ channel: SpeakerChannel, of channels: [SpeakerChannel]) -> String {
        guard channels.count > 1 else { return "speaker" }
        return channel == .right ? "right speaker" : "left speaker"
    }

    /// "30 cm", from `SeatSpot.spacing`.
    static var spacing: String { "\(Int((SeatSpot.spacing * 100).rounded())) cm" }

    /// "Now move the phone 30 cm to your left.": where the next spot is.
    public static func moveInstruction(to spot: SeatSpot) -> String {
        switch spot {
        case .seat: seatInstruction
        case .left: "Now move the phone \(spacing) to your left."
        case .right: "Now move the phone \(spacing) to your right."
        }
    }

    static let seatInstruction = "Hold the phone still at your head."
    static let holdStill = "Now hold the phone still."

    /// The headline of Three spots: what to do now. While a spot is waited for, one sentence per `SeatWaitPhase`
    /// (the progress's `wait`), so it does not flip back to "Now move…" as the phone settles: at the seat always
    /// "Hold the phone still at your head."; at the other spots "Now move the phone 30 cm to your left." until the
    /// move is seen, then "Now hold the phone still." Nil `wait` (no reading yet) is waiting for the move.
    public static func instruction(for state: SeatMeasurementSession.State, wait: SeatWaitPhase?, channels: [SpeakerChannel]) -> String {
        switch state {
        case .idle, .measuringNoiseFloor:
            "Stay quiet while I listen to the room."
        case .waitingForStillness(let spot):
            spot == .seat || (wait ?? .waitingForMove) == .waitingForMove ? moveInstruction(to: spot) : holdStill
        case .playing(_, let channel, _):
            channels.count > 1
                ? "Hold still. The \(speakerWord(channel, of: channels)) is playing."
                : "Hold still. The tones are playing."
        case .checking:
            "Hold still. Checking that one."
        case .paused(_, let channel, _):
            "It got noisy, so I stopped the \(speakerWord(channel, of: channels))."
        case .spotCaptured(let spot):
            "Got the \(spotName(spot)) spot."
        case .finished:
            "All three spots are in."
        case .failed:
            ""
        }
    }

    /// The line under the headline while the phone is waited for, and while the tones play.
    public static let waitingLine = "I'll start by myself once the phone is still."
    public static let playingLine = "Stay quiet while the tones play."

    /// The Paused screen.
    public static let pausedHeadline = "It got noisy, so I stopped."
    /// "A measurement taken now would be wrong. I'll pick up at 1 kHz once the room is quiet again."
    public static func pausedSentence(resumeFrequency: String?) -> String {
        "A measurement taken now would be wrong. I'll pick up at \(resumeFrequency ?? "where I stopped") once the room is quiet again."
    }

    // MARK: A spot repeated

    public static func noticeTitle(_ note: RunNote) -> String {
        switch note {
        case .repeating: "Measuring this spot again"
        case .restarted: "Starting this spot over"
        }
    }

    public static func noticeText(_ note: RunNote) -> String {
        switch note {
        case .repeating(.unusable(let verdict)):
            switch verdict {
            case .clipped:
                "That one was too loud and the microphone clipped it, so I'm playing it again. Turn the volume down a little if you can."
            case .tooQuiet:
                "That one was too quiet, so I'm playing it again. Turn the volume up a little if you can."
            case .tooNoisy:
                "The room was too noisy to read that one, so I'm playing it again. Please keep the room quiet."
            case .corrupt:
                "That one didn't come through whole, so I'm playing it again."
            case .silent, .valid:
                "I heard nothing on that one, so I'm playing it again."
            }
        case .repeating(.didNotArrive):
            "I didn't hear the sound arrive, so I'm playing it again."
        case .repeating(.interruptedRepeatedly):
            "Noise kept stopping it, so I'm starting it again."
        case .restarted(.noiseTooEarly):
            "The noise came before I'd heard enough to pick up where I stopped, so I'm starting this one over."
        case .restarted(.timelineUnreliable):
            "I lost track of the timing, so I'm starting this one over."
        }
    }

    // MARK: When it ends without a result

    /// Empty for `cancelled`, which shows no message.
    public static func failureHeadline(_ failure: MeasurementFailure) -> String {
        switch failure {
        case .permissionDenied: "I can't hear without the microphone."
        case .interrupted: "Something else took the sound."
        case .routeChanged: "The speakers changed while I was measuring."
        case .recordingUnusable: "I couldn't get a clean recording."
        case .audioUnavailable: "I couldn't start the sound."
        case .tooNoisy: "The room stayed too noisy."
        case .speakersNotConnected: "The sound is coming from the iPhone itself."
        case .cancelled: ""
        }
    }

    public static func failureBody(_ failure: MeasurementFailure) -> String {
        switch failure {
        case .permissionDenied:
            "I play test tones and listen to them to see how your room sounds from your seat, so I need the microphone. "
                + "Sound stays on this iPhone. You can allow it in Settings."
        case .interrupted:
            "A call, an alarm or another app used the audio, so I stopped. Nothing from this measurement was kept."
        case .routeChanged:
            "The speakers or the microphone switched partway, so I couldn't trust the timing. Nothing from this measurement was kept."
        case .audioUnavailable:
            "This iPhone wouldn't let me use the speakers and microphone just now. Close anything else that plays or records sound, then try again."
        case .recordingUnusable(let problem):
            "I tried that spot twice. " + unusableReason(problem)
        case .tooNoisy:
            "The room never got quiet enough for me to measure, so I stopped. Try again when it is quieter, and keep the room quiet while the tones play."
        case .speakersNotConnected(let route):
            "I can only measure your speakers, and right now the sound is coming out of "
                + (route.name.isEmpty ? "the iPhone's own speaker" : "the iPhone (\(route.name))") + ". "
                + "Connect your speakers with a cable, Bluetooth or AirPlay, choose them as the output, then try again."
        case .cancelled:
            ""
        }
    }

    /// What the "Inconclusive" tag on an ended measurement rests on; nil for the failures that carry no tag.
    public static func inconclusiveBasis(_ failure: MeasurementFailure) -> String? {
        switch failure {
        case .recordingUnusable: "a spot failed twice"
        case .tooNoisy: "the room stayed too noisy"
        default: nil
        }
    }

    private static func unusableReason(_ problem: RunProblem) -> String {
        switch problem {
        case .unusable(let verdict):
            switch verdict {
            case .clipped:
                "Both recordings were too loud and the microphone clipped them. Turn the volume down a little and try again."
            case .tooQuiet:
                "Both recordings were too quiet to read. Turn the volume up and try again."
            case .tooNoisy:
                "The room was too noisy for me to hear the speakers over it. Try again when it is quieter."
            case .corrupt:
                "Both recordings came back incomplete, so I can't read them. Check the connection to your speakers and try again."
            case .silent, .valid:
                "The microphone didn't pick up anything. Check that nothing covers it and that the speakers are on."
            }
        case .didNotArrive:
            "I never heard the test sound arrive. Check that the speakers are on and playing from this iPhone; a wireless route can add a long delay."
        case .interruptedRepeatedly:
            "Noise kept stopping the tones before they got anywhere. Try again when the room is quieter."
        }
    }
}
