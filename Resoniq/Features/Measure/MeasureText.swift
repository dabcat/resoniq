import Foundation
import ResoniqAudio
import ResoniqDiagnostics
import ResoniqDSP

/// The words of the measuring flow that the Kit does not provide yet: what to do at each moment, why a spot is being
/// measured again, why a measurement ended. Display only: each sentence is chosen from a value the Kit has already
/// decided (a state, a failure, a recording problem). They are written in the design system's voice and are
/// candidates to move into `ResoniqDiagnostics.SeatText`; each group says so.
enum MeasureText {
    // MARK: Spots

    /// "Seat", "Left", "Right": the names on the pills.
    static func pillTitle(_ spot: SeatSpot) -> String {
        switch spot {
        case .seat: "Seat"
        case .left: "Left"
        case .right: "Right"
        }
    }

    /// Where a spot sits in the top view, from the left: left, seat (the middle), right. The Kit measures the seat
    /// first, then left, then right.
    static func position(of spot: SeatSpot) -> Int {
        switch spot {
        case .left: 0
        case .seat: 1
        case .right: 2
        }
    }

    /// "middle", "left", "right".
    private static func place(_ spot: SeatSpot) -> String {
        switch spot {
        case .seat: "middle"
        case .left: "left"
        case .right: "right"
        }
    }

    /// "seat", "left", "right".
    static func spotName(_ spot: SeatSpot) -> String {
        switch spot {
        case .seat: "seat"
        case .left: "left"
        case .right: "right"
        }
    }

    // MARK: The sentence for this moment (Kit candidates)

    /// What the headline of Three spots says. `isSteady` is the phone's own motion while waiting for a spot.
    static func instruction(for state: SeatMeasurementSession.State, isSteady: Bool, channels: [SpeakerChannel]) -> String {
        switch state {
        case .idle, .measuringNoiseFloor:
            "Stay quiet while I listen to the room."
        case .waitingForStillness(let spot):
            isSteady ? moveSentence(to: spot) : "Now hold the phone still."
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

    /// "Hold the phone still at your head." for the seat, "Now move the phone 30 cm to your left." for the others.
    private static func moveSentence(to spot: SeatSpot) -> String {
        switch spot {
        case .seat: "Hold the phone still at your head."
        case .left: "Now move the phone 30 cm to your left."
        case .right: "Now move the phone 30 cm to your right."
        }
    }

    /// "left speaker", "right speaker", "speaker".
    static func speakerWord(_ channel: SpeakerChannel, of channels: [SpeakerChannel]) -> String {
        guard channels.count > 1 else { return "speaker" }
        return channel == .right ? "right speaker" : "left speaker"
    }

    /// The caps label on the Paused screen: "Left spot · right speaker".
    static func pausedTitle(spot: SeatSpot, channel: SpeakerChannel, of channels: [SpeakerChannel]) -> String {
        let name = spotName(spot).prefix(1).uppercased() + spotName(spot).dropFirst()
        return channels.count > 1 ? "\(name) spot · \(speakerWord(channel, of: channels))" : "\(name) spot"
    }

    /// The line under the headline when the phone is waited for, and while the tones play.
    static let waitingLine = "I'll start by myself once the phone is still."
    static let playingLine = "Stay quiet while the tones play."

    // MARK: Progress

    /// "1 of 3 in": the same words as `SeatReport.progress`, from the session's own counts.
    static func progress(captured: Int, of total: Int) -> String { "\(min(captured, total)) of \(total) in" }

    private static func number(_ value: Int) -> String {
        let words = ["No", "One", "Two", "Three"]
        return words.indices.contains(value) ? words[value] : String(value)
    }

    /// One sentence for the diagram of Three spots, from the spots' states.
    static func diagramLabel(captured: [SeatSpot], active: SeatSpot?) -> String {
        var parts = ["Three spots in a row."]
        if !captured.isEmpty {
            let names = captured.map(place).joined(separator: " and ")
            parts.append("The \(names) \(captured.count == 1 ? "one is" : "ones are") done.")
        }
        if let active {
            parts.append(captured.isEmpty
                ? "The phone is at the middle one, the first to measure."
                : "The phone slides to the \(place(active)) one.")
        } else {
            parts.append("All three are done.")
        }
        return parts.joined(separator: " ")
    }

    /// One sentence for the curve panel: how many spots are in and what is drawn.
    static func curveLabel(captured: Int, drawn: Int, of total: Int) -> String {
        guard captured > 0 else { return "The average of the three spots will build here. No spot is in yet." }
        let inCount = "\(number(captured)) of \(number(total).lowercased()) spots \(captured == 1 ? "is" : "are") in."
        guard drawn > 0 else { return "\(inCount) Their curves are drawn once I've read the recordings." }
        return "\(inCount) Each spot's line is drawn faintly and their average is drawn over them."
    }

    /// The sentence for the Sit and aim diagram.
    static let guideDiagramLabel =
        "Seen from above: both speakers play toward a sofa. Three measuring spots sit in a row at head height, the middle one first"

    // MARK: Levels

    /// "Good", "Too loud", "Too quiet": clipping is the Kit's `isClipping`; "too quiet" is judged only above the
    /// woofer's range, against the Kit's own minimum peak for a recording, as Diagnose does.
    static func level(isClipping: Bool, frequency: Double?, peakDecibels: Float) -> String {
        if isClipping { return "Too loud" }
        if let frequency, Float(frequency) > DriverBand.wooferUpperFrequency,
           peakDecibels < QualityThresholds.standard.minimumPeakDecibels {
            return "Too quiet"
        }
        return "Good"
    }

    // MARK: A spot repeated (Kit candidates)

    static func noticeTitle(_ note: RunNote) -> String {
        switch note {
        case .repeating: "Measuring this spot again"
        case .restarted: "Starting this spot over"
        }
    }

    static func noticeText(_ note: RunNote) -> String {
        switch note {
        case .repeating(.unusable(let verdict)):
            switch RecordingCheck(verdict).problem {
            case .clipped:
                "That one was too loud and the microphone clipped it, so I'm playing it again. Turn the volume down a little if you can."
            case .tooQuiet:
                "That one was too quiet, so I'm playing it again. Turn the volume up a little if you can."
            case .tooNoisy:
                "The room was too noisy to read that one, so I'm playing it again. Please keep the room quiet."
            case .corrupt, .incomplete:
                "That one didn't come through whole, so I'm playing it again."
            case .silent, nil:
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

    // MARK: When it ends without a result (Kit candidates)

    static func failureHeadline(_ failure: SeatFlow.Failure) -> String {
        switch failure {
        case .permissionDenied: "I can't hear without the microphone."
        case .interrupted: "Something else took the sound."
        case .routeChanged: "The speakers changed while I was measuring."
        case .unusable: "I couldn't get a clean recording."
        case .audioUnavailable: "I couldn't start the sound."
        case .tooNoisy: "The room stayed too noisy."
        case .speakersNotConnected: "The sound is coming from the iPhone itself."
        }
    }

    static func failureBody(_ failure: SeatFlow.Failure) -> String {
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
        case .unusable(let problem):
            "I tried that spot twice. " + unusableReason(problem)
        case .tooNoisy:
            "The room never got quiet enough for me to measure, so I stopped. Try again when it is quieter, and keep the room quiet while the tones play."
        case .speakersNotConnected(let route):
            speakersNotConnectedBody(route)
        }
    }

    /// What the evidence tag on an ended measurement rests on, for the failures that are "Inconclusive".
    static func inconclusiveBasis(_ failure: SeatFlow.Failure) -> String? {
        switch failure {
        case .unusable: "a spot failed twice"
        case .tooNoisy: "the room stayed too noisy"
        default: nil
        }
    }

    private static func speakersNotConnectedBody(_ route: AudioOutputRoute) -> String {
        let source = route.name.isEmpty ? "the iPhone's own speaker" : "the iPhone (\(route.name))"
        return "I can only measure your speakers, and right now the sound is coming out of \(source). "
            + "Connect your speakers with a cable, Bluetooth or AirPlay, choose them as the output, then try again."
    }

    private static func unusableReason(_ problem: RunProblem) -> String {
        switch problem {
        case .unusable(let verdict):
            switch RecordingCheck(verdict).problem {
            case .clipped:
                "Both recordings were too loud and the microphone clipped them. Turn the volume down a little and try again."
            case .tooQuiet:
                "Both recordings were too quiet to read. Turn the volume up and try again."
            case .tooNoisy:
                "The room was too noisy for me to hear the speakers over it. Try again when it is quieter."
            case .corrupt, .incomplete:
                "Both recordings came back incomplete, so I can't read them. Check the connection to your speakers and try again."
            case .silent, nil:
                "The microphone didn't pick up anything. Check that nothing covers it and that the speakers are on."
            }
        case .didNotArrive:
            "I never heard the test sound arrive. Check that the speakers are on and playing from this iPhone; a wireless route can add a long delay."
        case .interruptedRepeatedly:
            "Noise kept stopping the tones before they got anywhere. Try again when the room is quieter."
        }
    }

    // MARK: Analysing, paused

    static let analysingHeadline = "Putting the three spots together."
    static let analysingBody = "I average them so one odd spot can't fool us. This takes a moment."
    static let analysingKicker = "Almost there"
    static let analysingWaiting = "Reading your seat"

    static let pausedHeadline = "It got noisy, so I stopped."
    static func pausedSentence(resumeFrequency: String?) -> String {
        "A measurement taken now would be wrong. I'll pick up at \(resumeFrequency ?? "where I stopped") once the room is quiet again."
    }
}
