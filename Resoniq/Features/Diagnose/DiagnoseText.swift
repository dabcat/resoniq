import Foundation
import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqDSP
import ResoniqStore

/// The words and figures the Diagnose flow shows that the Kit does not format yet.
///
/// Everything here is display only: it turns a value the Kit has already decided into text. Anything that decides
/// something (a threshold, a conversion) is read from the Kit. These small formatters should move into
/// `ResoniqDiagnostics.DiagnosisText` / `ResoniqAudio`; each is marked.
enum DiagnoseText {
    // MARK: Names

    /// "Left speaker", "Right speaker", "Speaker".
    static func speakerName(_ position: SpeakerPosition) -> String {
        switch position {
        case .left: "Left speaker"
        case .right: "Right speaker"
        case .single: "Speaker"
        }
    }

    /// "Left speaker · run 2 of 3".
    static func runTitle(_ position: SpeakerPosition, run: Int, runCount: Int) -> String {
        "\(speakerName(position)) · run \(run) of \(runCount)"
    }

    // MARK: Readings

    /// The "Playing now" figure and its unit: "1.02" "kHz", "14.5" "kHz", "90" "Hz". (Kit candidate.)
    static func frequencyReading(_ hertz: Double) -> (value: String, unit: String) {
        if hertz < 1_000 { return (String(Int(hertz.rounded())), "Hz") }
        let kilohertz = hertz / 1_000
        let digits = kilohertz < 10 ? 2 : 1
        return (kilohertz.formatted(.number.precision(.fractionLength(digits))), "kHz")
    }

    /// "Quiet · 34 dB" or "Noisy · 52 dB". The figure is the Kit's approximate level; the word is the Kit's
    /// quiet-enough decision (`MeasurementProgress.isRoomQuiet`).
    static func room(_ level: SoundLevel, isQuiet: Bool) -> String {
        "\(isQuiet ? "Quiet" : "Noisy") · \(decibels(level))"
    }

    /// "34 dB".
    static func decibels(_ level: SoundLevel) -> String {
        "\(Int(level.approximateDecibels.rounded())) dB"
    }

    /// How far along the room-noise bar a level sits, 0...1. The bar runs from 0 to `roomNoiseScaleDecibels`.
    /// (Kit candidate.)
    static func barFraction(_ level: SoundLevel) -> Double {
        min(max(Double(level.approximateDecibels / roomNoiseScaleDecibels), 0), 1)
    }

    /// The approximate decibels at the right end of the room-noise bar. Chosen so the mockup's 52 dB sits at 78 %
    /// and its mark at 55 %, that is a mark near 37 dB, just above a quiet living room.
    static let roomNoiseScaleDecibels: Float = 70

    /// The input level in words. Clipping is the Kit's `isClipping`. "Too quiet" is judged only above the woofer's
    /// range, where a speaker is not rolling off, against the Kit's own minimum peak for a recording.
    static func level(_ progress: MeasurementProgress) -> String {
        if progress.isClipping { return "Too loud, clipping" }
        if let frequency = progress.frequency,
           Float(frequency) > DriverBand.wooferUpperFrequency,
           progress.inputPeakDecibels < QualityThresholds.standard.minimumPeakDecibels {
            return "Too quiet"
        }
        return "Good, no clipping"
    }

    static func phone(isSteady: Bool) -> String { isSteady ? "Steady" : "Moving" }

    /// The sentence VoiceOver reads for the room reading: "Room: quiet, about 34 decibels."
    static func spokenRoom(_ level: SoundLevel, isQuiet: Bool) -> String {
        "Room: \(isQuiet ? "quiet" : "noisy"), about \(Int(level.approximateDecibels.rounded())) decibels."
    }

    // MARK: Portrait

    static func portraitLabel(_ status: SpeakerPortrait.Status, hertz: Double?) -> String {
        let spoken = hertz.map(FrequencyRuler.spokenFrequency)
        switch status {
        case .notHeard:
            return "The speaker's portrait, not drawn yet. I'm listening to the room first."
        case .drawing(let progress):
            if progress >= 1 { return "The speaker's portrait, drawn all the way up for this run." }
            return "The speaker's portrait being drawn from the lowest notes upward; it has reached \(spoken ?? "the top")."
        case .paused:
            return "The speaker's portrait, partly drawn and dimmed while the test is paused at \(spoken ?? "this point")."
        case .finished:
            return "The speaker's portrait, finished."
        }
    }

    // MARK: Runs repeated

    /// What to call the notice above the guidance.
    static func noticeTitle(_ note: RunNote) -> String {
        switch note {
        case .repeating: "Playing this run again"
        case .restarted: "Starting this run over"
        }
    }

    /// Why a run is being played again, in a sentence, with what to do about it where there is something.
    static func noticeText(_ note: RunNote) -> String {
        switch note {
        case .repeating(.unusable(let verdict)):
            switch RecordingCheck(verdict).problem {
            case .clipped:
                "That run was too loud and the microphone clipped it, so I'm playing it again. Turn the volume down a little if you can."
            case .tooQuiet:
                "That run was too quiet, so I'm playing it again. Hold the phone a little closer or turn the volume up."
            case .tooNoisy:
                "That run was too noisy to read, so I'm playing it again. Please keep the room quiet."
            case .silent, nil:
                "I heard nothing on that run, so I'm playing it again."
            }
        case .repeating(.didNotArrive):
            "I didn't hear the sound arrive, so I'm playing that run again."
        case .repeating(.interruptedRepeatedly):
            "Noise kept stopping that run, so I'm starting it again."
        case .restarted(.noiseTooEarly):
            "The noise came before I'd heard enough to pick up where I stopped, so I'm starting this run over."
        case .restarted(.timelineUnreliable):
            "I lost track of the timing, so I'm starting this run over."
        }
    }

    // MARK: Failures

    static func failureHeadline(_ failure: DiagnoseFlow.Failure) -> String {
        switch failure {
        case .permissionDenied: "I can't hear without the microphone."
        case .interrupted: "Something else took the sound."
        case .routeChanged: "The speakers changed while I was listening."
        case .unusable: "I couldn't get a clean recording."
        case .audioUnavailable: "I couldn't start the sound."
        }
    }

    static func failureBody(_ failure: DiagnoseFlow.Failure) -> String {
        switch failure {
        case .permissionDenied:
            "I play a test sound and listen to it to see how your speaker behaves, so I need the microphone. "
                + "Sound stays on this iPhone. You can allow it in Settings."
        case .interrupted:
            "A call, an alarm or another app used the audio, so I stopped. Nothing from this test was kept."
        case .routeChanged:
            "The speaker or the microphone switched during the test, so I couldn't trust the timing. Nothing from this test was kept."
        case .audioUnavailable:
            "This iPhone wouldn't let me use the speaker and microphone just now. Close anything else that plays or records sound, then try again."
        case .unusable(let problem):
            "I tried that run twice. " + unusableReason(problem)
        }
    }

    /// What the evidence tag on a failed test rests on.
    static let inconclusiveBasis = "a run failed twice"

    private static func unusableReason(_ problem: RunProblem) -> String {
        switch problem {
        case .unusable(let verdict):
            switch RecordingCheck(verdict).problem {
            case .clipped:
                "Both recordings were too loud and the microphone clipped them. Turn the volume down a little and hold the phone a bit farther from the speaker."
            case .tooQuiet:
                "Both recordings were too quiet to read. Turn the volume up or hold the phone closer to the speaker."
            case .tooNoisy:
                "The room was too noisy for me to hear the speaker over it. Try again when it is quieter."
            case .silent, nil:
                "The microphone didn't pick up anything. Check that nothing covers it and that the speaker is on."
            }
        case .didNotArrive:
            "I never heard the test sound arrive. Check that the speaker is on and playing from this iPhone; a wireless route can add a long delay."
        case .interruptedRepeatedly:
            "Noise kept stopping the sweep before it got anywhere. Try again when the room is quieter."
        }
    }
}
