import Foundation

/// Every user-facing string the diagnosis produces, in English, in one place so it can be localised.
///
/// The voice is the design system's: first person, calm, hedged honestly ("may be buzzing", never "is broken"),
/// no jargon in headlines, units in details. Verdicts and sentences end with a full stop; the short titles beside the
/// portrait do not, as in the mockups.
public enum DiagnosisText {
    // MARK: Names

    static func tagName(_ tag: EvidenceTag) -> String {
        switch tag {
        case .measured: "Measured"
        case .inferred: "Inferred"
        case .inconclusive: "Inconclusive"
        case .estimate: "Estimate"
        }
    }

    static func bandName(_ band: DriverBand) -> String {
        switch band {
        case .woofer: "Woofer"
        case .middle: "Middle driver"
        case .tweeter: "Tweeter"
        }
    }

    /// The short name used in lists: "Tweeter and mid are even".
    static func shortBandName(_ band: DriverBand) -> String {
        switch band {
        case .woofer: "woofer"
        case .middle: "mid"
        case .tweeter: "tweeter"
        }
    }

    /// The name inside a sentence: "the woofer may be buzzing".
    static func bandInSentence(_ band: DriverBand) -> String {
        switch band {
        case .woofer: "the woofer"
        case .middle: "the middle driver"
        case .tweeter: "the tweeter"
        }
    }

    // MARK: Numbers

    /// A frequency rounded the way it is written: to 5 Hz below 50 Hz, to 10 Hz below 1 kHz, to 0.1 kHz below
    /// 10 kHz, to 1 kHz above.
    public static func rounded(_ frequency: Float) -> Float {
        let step: Float = frequency < 47.5 ? 5 : (frequency < 995 ? 10 : (frequency < 9950 ? 100 : 1000))
        return (frequency / step).rounded() * step
    }

    /// "90 Hz", "1.2 kHz", "14 kHz".
    public static func frequency(_ frequency: Float) -> String {
        let value = rounded(frequency)
        return value < 1000 ? "\(hertz(value)) Hz" : "\(kilohertz(value)) kHz"
    }

    /// "70–110 Hz", "800 Hz–1.2 kHz", "1.2–3 kHz"; one frequency when both ends round to it.
    public static func range(_ range: FrequencyRange) -> String {
        let lower = rounded(range.lower)
        let upper = rounded(range.upper)
        if lower == upper { return frequency(lower) }
        switch (lower < 1000, upper < 1000) {
        case (true, true): return "\(hertz(lower))–\(hertz(upper)) Hz"
        case (false, false): return "\(kilohertz(lower))–\(kilohertz(upper)) kHz"
        default: return "\(frequency(lower))–\(frequency(upper))"
        }
    }

    private static func hertz(_ value: Float) -> String { String(Int(value.rounded())) }

    private static func kilohertz(_ value: Float) -> String {
        let tenths = Int((value / 100).rounded())
        return tenths % 10 == 0 ? String(tenths / 10) : "\(tenths / 10).\(tenths % 10)"
    }

    private static func decibels(_ value: Float) -> String { String(Int(abs(value).rounded())) }

    private static func percent(_ value: Float) -> String { String(Int(value.rounded())) }

    private static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        value == 1 ? "\(value) \(singular)" : "\(value) \(plural)"
    }

    // MARK: Basis and confidence

    /// "3 of 3 runs".
    static func basis(agreeing: Int, compared: Int) -> String {
        "\(agreeing) of \(count(compared, "run", "runs"))"
    }

    static func tagLine(tag: EvidenceTag, basis: Finding.Basis) -> String {
        tag == .inferred ? "\(tagName(tag)) · \(basis.text)" : tagName(tag)
    }

    static func repeatability(_ basis: Finding.Basis) -> String {
        basis.runsAgreeing == basis.runsCompared
            ? "Same place every time"
            : "Same place in \(basis.text)"
    }

    static func confidenceStatement(kind: Finding.Kind, confidence: Finding.Confidence, basis: Finding.Basis) -> String {
        switch confidence {
        case .medium, .high:
            let label = confidence == .high ? "high" : "medium"
            switch kind {
            case .distortion:
                return "Inferred, \(label) confidence. It repeats every run, but from one microphone position I can't rule out something near the speaker vibrating."
            case .leftRightDifference:
                return "Inferred, \(label) confidence. It repeats every run, but the two speakers stand in different places, so the room may account for some of it."
            default:
                return "Inferred, \(label) confidence. It repeats every run, but from one microphone position I can't tell the speaker from the room around it."
            }
        case .low:
            if basis.runsAgreeing == basis.runsCompared {
                return "Inferred, low confidence. It showed in both runs I could use, but that is too few to be sure."
            }
            return "Inferred, low confidence. It showed in \(basis.text), so it may have been a sound in the room rather than the speaker."
        }
    }

    // MARK: Findings

    struct Words {
        var headline: String
        var detail: String
        var sentence: String
    }

    /// Hedged in every line, never only in the verdict: a buzz is a suspected defect.
    static func distortion(range: FrequencyRange, extreme: Float, at frequency: Float) -> Words {
        Words(
            headline: "Possible buzz at \(self.range(range))",
            detail: "Distortion rose to \(percent(extreme)) % around \(self.frequency(frequency)).",
            sentence: "A possible buzz around \(self.frequency(range.centre))."
        )
    }

    /// A driver far quieter than the rest. The difference is measured; what causes it is not known, and the words say
    /// so.
    static func quietBand(_ band: DriverBand, range: FrequencyRange, difference: Float) -> Words {
        Words(
            headline: "I could barely hear \(bandInSentence(band))",
            detail: "Around \(self.range(range)) it was about \(decibels(difference)) dB quieter than the rest of the speaker. It could be the driver, its connection, or where the phone was.",
            sentence: "I could barely hear \(bandInSentence(band))."
        )
    }

    static func quietBandConfidence(basis: Finding.Basis) -> String {
        "Measured: I read the difference in level straight from \(basis.runsCompared == 1 ? "the recording" : "the recordings of \(count(basis.runsCompared, "run", "runs"))"). What causes it I can't tell from here."
    }

    /// A driver whose band was too close to the room's noise to judge.
    static func notAssessed(_ band: DriverBand, range: FrequencyRange) -> Words {
        Words(
            headline: "Couldn't check \(bandInSentence(band))",
            detail: "Around \(self.range(range)) the room's noise was too close to the speaker's level, so I can't say how it sounds there.",
            sentence: "I couldn't check \(bandInSentence(band))."
        )
    }

    static let notAssessedConfidence = "Inconclusive. The room was too loud there to tell the speaker from the noise. A quieter moment would settle it."

    static func dip(range: FrequencyRange, depth: Float) -> Words {
        Words(
            headline: "Dip at \(self.range(range))",
            detail: "About \(decibels(depth)) dB quieter than the notes around it.",
            sentence: "A dip around \(frequency(range.centre))."
        )
    }

    static func peak(range: FrequencyRange, height: Float) -> Words {
        Words(
            headline: "Peak at \(self.range(range))",
            detail: "About \(decibels(height)) dB louder than the notes around it.",
            sentence: "A peak around \(frequency(range.centre))."
        )
    }

    static func topEndDip(range: FrequencyRange) -> Words {
        Words(
            headline: "Very top notes dip",
            detail: "Above \(frequency(range.lower)). Could be the phone's angle.",
            sentence: "The very top notes dip above \(frequency(range.lower))."
        )
    }

    static let topEndConfidence =
        "Inconclusive. A phone microphone that isn't pointing straight at the speaker hears less of the very top, so I can't tell the speaker from the phone's angle."

    static func leftRight(range: FrequencyRange, difference: Float) -> Words {
        let direction = difference < 0 ? "quieter" : "louder"
        return Words(
            headline: "Unlike the other speaker at \(self.range(range))",
            detail: "About \(decibels(difference)) dB \(direction) than the other speaker there.",
            sentence: "Around \(frequency(range.centre)) it doesn't match the other speaker."
        )
    }

    static func distortionUnclear(range: FrequencyRange, read: Float) -> Words {
        Words(
            headline: "Too noisy to tell at \(self.range(range))",
            detail: "Distortion read about \(percent(read)) % there, but the room's noise reads nearly as high.",
            sentence: "It was too noisy to tell about distortion around \(frequency(range.centre))."
        )
    }

    static let distortionUnclearConfidence =
        "Inconclusive. The room's noise alone reads almost as much distortion as I found there, so I can't tell a buzz from the noise. A quieter room would settle it."

    /// "from 80 Hz to 9.3 kHz".
    private static func span(_ range: FrequencyRange) -> String {
        "from \(frequency(range.lower)) to \(frequency(range.upper))"
    }

    /// "tweeter, mid and woofer".
    static func bandList(_ bands: [DriverBand]) -> String {
        let names = bands.map(shortBandName)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// `bands` top of the portrait first. `response` is the stretch the response was found within the even band
    /// over; `range` is where every run ruled a buzz out (distortion under `percent`), nil when nowhere;
    /// `uncheckedBelow`, when set, is the frequency under which distortion in the stated bands was not checked. The
    /// detail names exactly these.
    static func even(
        bands: [DriverBand],
        response: [FrequencyRange],
        distortionBelow threshold: Float,
        over range: FrequencyRange?,
        uncheckedBelow: Float?
    ) -> Words {
        let list = bandList(bands)
        let capitalised = list.prefix(1).uppercased() + list.dropFirst()
        let verb = bands.count == 1 ? "is" : "are"
        // Only harmonic distortion is measured from a sweep, so rattle is never mentioned.
        var detail = "It stays within \(decibels(EvenBand.decibels)) dB \(response.map(span).joined(separator: " and "))."
        if let range {
            detail += " Distortion stayed under \(percent(threshold)) % \(span(range))."
            if let uncheckedBelow { detail += " I couldn't check for distortion below \(frequency(uncheckedBelow))." }
        } else {
            detail += " I couldn't measure distortion over the room's noise."
        }
        return Words(
            headline: "\(capitalised) \(verb) even",
            detail: detail,
            sentence: "The \(list) \(verb) even."
        )
    }

    static func evenConfidence(basis: Finding.Basis) -> String {
        "Measured. I read it straight from \(basis.runsCompared == 1 ? "the recording" : "the recordings of \(count(basis.runsCompared, "run", "runs"))")."
    }

    static func invalid(_ problem: RecordingCheck.Problem, runs: Int) -> Words {
        let subject = runs == 1 ? "One run was" : "\(runs) runs were"
        let left = runs == 1 ? "that run" : "those runs"
        switch problem {
        case .clipped:
            return Words(
                headline: "\(subject) too loud to use",
                detail: "The microphone clipped, so I left \(left) out. Turning the volume down a little helps.",
                sentence: "The microphone clipped, so I left \(left) out."
            )
        case .tooQuiet:
            return Words(
                headline: "\(subject) too quiet to use",
                detail: "I could barely hear the speaker, so I left \(left) out. Turning the volume up or moving closer helps.",
                sentence: "I could barely hear the speaker, so I left \(left) out."
            )
        case .tooNoisy:
            return Words(
                headline: "\(subject) too noisy to use",
                detail: "The room was too loud against the speaker, so I left \(left) out.",
                sentence: "It got too noisy, so I left \(left) out."
            )
        case .silent:
            return Words(
                headline: runs == 1 ? "One run recorded nothing" : "\(runs) runs recorded nothing",
                detail: "The microphone gave me silence, so I left \(left) out.",
                sentence: "The microphone gave me silence, so I left \(left) out."
            )
        case .corrupt:
            return Words(
                headline: runs == 1 ? "One run came back damaged" : "\(runs) runs came back damaged",
                detail: "The recording held samples that weren't sound, so I left \(left) out. Playing it again usually fixes it.",
                sentence: "The recording came back damaged, so I left \(left) out."
            )
        case .incomplete:
            return Words(
                headline: runs == 1 ? "One run was cut short" : "\(runs) runs were cut short",
                detail: "The recording stopped before the whole test sound had reached me, so I left \(left) out. A wireless speaker can add a long delay.",
                sentence: "The recording was cut short, so I left \(left) out."
            )
        }
    }

    static let invalidConfidence = "Inconclusive. I don't draw anything from a recording I couldn't use."

    // MARK: Verdict

    static let inconclusiveVerdict = "I couldn't get clean enough recordings to judge this speaker."
    static let healthyVerdict = "Sounds healthy."

    /// The clause a suspected defect adds to the verdict: "the woofer may be buzzing".
    static func clause(for finding: Finding) -> String {
        let band = finding.band.map(bandInSentence) ?? "it"
        let around = finding.frequencyRange.map { frequency($0.centre) } ?? ""
        switch finding.kind {
        case .distortion: return "\(band) may be buzzing"
        case .responseDip: return "\(band) may be weak around \(around)"
        case .responsePeak: return "\(band) may be too loud around \(around)"
        case .leftRightDifference: return "it may not match the other speaker around \(around)"
        case .quietBand: return "I could barely hear \(band)"
        case .topEndDip, .even, .invalidRecording, .distortionUnclear, .notAssessed: return ""
        }
    }

    static let notAssessedVerdict = "The room was too loud against the speaker for me to judge it."

    /// The verdict over what was assessed. `unchecked` are the drivers that could not be assessed, top first, and
    /// `checked` the rest: "healthy" is said only of the checked ones.
    static func verdict(suspected: [Finding], unchecked: [DriverBand] = [], checked: [DriverBand] = DriverBand.allCases.reversed()) -> String {
        let base: String = switch suspected.count {
        case 0: healthyVerdict
        case 1: "Sounds healthy, except \(clause(for: suspected[0]))."
        case 2: "Sounds healthy, except \(clause(for: suspected[0])) and \(clause(for: suspected[1]))."
        default: "I found \(suspected.count) things worth a closer look."
        }
        guard !unchecked.isEmpty else { return base }
        let missing = "I couldn't check the \(bandList(unchecked))"
        guard suspected.isEmpty, !checked.isEmpty else { return "\(base) \(missing)." }
        return "The \(bandList(checked)) \(checked.count == 1 ? "sounds" : "sound") healthy; \(missing)."
    }
}
