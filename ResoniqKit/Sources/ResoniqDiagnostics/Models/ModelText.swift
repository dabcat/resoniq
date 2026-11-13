import Foundation

/// Every user-facing string the model-based helpers produce, in the voice of `DiagnosisText`: first person, calm,
/// hedged ("It sounds like", "may"), never a verdict on a model's say-so, and always with how it is known
/// ("sound classifier, 82 %").
public enum ModelText {
    // MARK: Interference

    /// The sentence that names what was heard: "It sounds like someone talking."
    static func interference(_ kind: InterferenceKind) -> String {
        switch kind {
        case .speech: "It sounds like someone talking."
        case .music: "It sounds like music or a TV."
        case .televisionOrRadio: "It sounds like a TV or radio."
        case .traffic: "It sounds like traffic outside."
        case .appliance: "It sounds like a machine running, such as a vacuum cleaner."
        case .animal: "It sounds like a dog or another animal."
        case .doorOrFootsteps: "It sounds like a door or footsteps."
        case .windOrRain: "It sounds like wind or rain."
        case .babyOrChildren: "It sounds like a baby or children."
        case .phoneOrAlarm: "It sounds like a phone or an alarm."
        case .unknown: "I couldn't tell what the sound was."
        }
    }

    // MARK: Bases

    /// "82 %": whole per cent, never 0 or 100 (a classifier's confidence is neither).
    public static func percent(_ confidence: Float) -> String {
        let value = min(max(Int((confidence * 100).rounded()), 1), 99)
        return "\(value) %"
    }

    /// "sound classifier, 82 %".
    static func soundClassifierBasis(_ confidence: Float) -> String { "sound classifier, \(percent(confidence))" }

    /// "defect classifier, 74 %".
    static func defectClassifierBasis(_ confidence: Float) -> String { "defect classifier, \(percent(confidence))" }

    /// "anomaly check, 3.1 × usual": how far the recording stood from healthy ones, as a multiple of the usual
    /// difference.
    static func anomalyBasis(_ ratio: Float) -> String {
        "anomaly check, \(String(format: "%.1f", Double(ratio))) × usual"
    }

    /// "Inferred · sound classifier, 82 %".
    static func tagLine(_ basis: String) -> String { "\(DiagnosisText.tagName(.inferred)) · \(basis)" }

    // MARK: Defect classifier

    /// The sound in a sentence: "a rattle".
    static func sound(_ defect: DefectClass) -> String {
        switch defect {
        case .normal: "nothing unusual"
        case .mechanicalRattling: "a rattle"
        case .voiceCoilRubbing: "a rubbing sound"
        case .buzzing: "a buzz"
        case .crackling: "crackling"
        case .potentialDriverMalfunction: "a driver not working as it should"
        case .environmentalInterference: "another sound in the room"
        case .unknownAnomaly: "something unusual"
        }
    }

    /// The short title: "Possible rattle".
    static func defectHeadline(_ defect: DefectClass) -> String {
        switch defect {
        case .normal: "Nothing unusual"
        case .mechanicalRattling: "Possible rattle"
        case .voiceCoilRubbing: "Possible rubbing"
        case .buzzing: "Possible buzz"
        case .crackling: "Possible crackling"
        case .potentialDriverMalfunction: "A driver may not be working right"
        case .environmentalInterference: "Possibly another sound in the room"
        case .unknownAnomaly: "Something sounded unusual"
        }
    }

    /// "I may have heard a rattle."
    static func defectSentence(_ defect: DefectClass) -> String { "I may have heard \(sound(defect))." }

    static let hint = "It's a hint, not a measurement."

    /// "A defect classifier heard something like a rattle. It's a hint, not a measurement."
    static func defectDetail(_ defect: DefectClass) -> String {
        "A defect classifier heard something like \(sound(defect)). \(hint)"
    }

    /// What support from the classifier adds to an existing finding: "A defect classifier also heard a buzz (74 %)."
    static func defectSupport(_ defect: DefectClass, confidence: Float) -> String {
        "A defect classifier also heard \(sound(defect)) (\(percent(confidence)))."
    }

    // MARK: Anomaly

    static let anomalyHeadline = "Something sounded unusual"
    static let anomalySentence = "Something about this speaker sounded unusual."
    static let anomalyDetail = "Its recording stood out from healthy speakers. \(hint)"
}
