import Foundation

/// Every user-facing string the seat result and the before-and-after comparison produce, in English, in one place so
/// it can be localised. The sibling of `DiagnosisText`, in the same voice: first person, calm, plain words in
/// headlines, numbers in details; a suspected cause is never stated as confirmed.
public enum SeatText {
    // MARK: Numbers

    /// "41 Hz", "120 Hz", "1 kHz", "2.5 kHz": whole hertz under 1 kHz (a room mode's frequency matters to the hertz),
    /// tenths of a kilohertz above.
    public static func frequency(_ frequency: Float) -> String {
        if frequency.rounded() < 1000 { return "\(Int(frequency.rounded())) Hz" }
        let tenths = Int((frequency / 100).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10) kHz" : "\(tenths / 10).\(tenths % 10) kHz"
    }

    /// The minus sign the design uses (U+2212).
    static let minus = "\u{2212}"

    /// "+9 dB", "−11 dB", "0 dB".
    public static func signedDecibels(_ value: Float) -> String {
        let whole = Int(value.rounded())
        return whole > 0 ? "+\(whole) dB" : (whole < 0 ? "\(minus)\(-whole) dB" : "0 dB")
    }

    /// "+9.2 dB", "−11.4 dB".
    public static func signedDecibelsTenths(_ value: Float) -> String {
        let tenths = Int((value * 10).rounded())
        let text = "\(abs(tenths) / 10).\(abs(tenths) % 10) dB"
        return tenths > 0 ? "+\(text)" : (tenths < 0 ? "\(minus)\(text)" : text)
    }

    /// "1.2 dB".
    static func decibelsTenths(_ value: Float) -> String {
        let tenths = Int((abs(value) * 10).rounded())
        return "\(tenths / 10).\(tenths % 10) dB"
    }

    /// The smallest difference the seat result writes, dB: one tenth, the resolution of its figures.
    public static let displayResolutionDecibels: Float = 0.1

    /// A difference as "within" or "±" figures write it: "1.2 dB". **Rule**: a difference that would round under the
    /// display resolution is written as the resolution, "0.1 dB", never "0.0 dB": two measured curves are never
    /// known to be identical, only closer than the figure can show, and "within 0.1 dB" stays true.
    static func differenceTenths(_ value: Float) -> String {
        decibelsTenths(max(abs(value), displayResolutionDecibels))
    }

    /// "9 dB".
    static func decibels(_ value: Float) -> String { "\(Int(abs(value).rounded())) dB" }

    /// "41 Hz +9 dB".
    static func extremeLabel(frequency: Float, deviation: Float) -> String {
        "\(self.frequency(frequency)) \(signedDecibels(deviation))"
    }

    /// "0.4 %" under 10 %, "12 %" above.
    static func percent(_ value: Float) -> String {
        value < 9.95 ? String(format: "%.1f %%", value) : "\(Int(value.rounded())) %"
    }

    // MARK: Progress and notes

    /// "1 of 3 in".
    public static func progress(valid: Int, required: Int) -> String { "\(min(valid, required)) of \(required) in" }

    private static func number(_ value: Int) -> String {
        let words = ["No", "One", "Two", "Three"]
        return words.indices.contains(value) ? words[value] : String(value)
    }

    /// The sentence VoiceOver reads for the "Building the average" panel: how many spots are in and what is drawn.
    /// `drawn` is how many spot curves are drawn so far.
    public static func buildingLabel(captured: Int, drawn: Int, of total: Int) -> String {
        guard captured > 0 else { return "The average of the three spots will build here. No spot is in yet." }
        let inCount = "\(number(captured)) of \(number(total).lowercased()) spots \(captured == 1 ? "is" : "are") in."
        guard drawn > 0 else { return "\(inCount) Their curves are drawn once I've read the recordings." }
        return "\(inCount) Each spot's line is drawn faintly and their average is drawn over them."
    }

    /// While the spots are put together into the result.
    public static let analysingHeadline = "Putting the three spots together."
    public static let analysingBody = "I average them so one odd spot can't fool us. This takes a moment."
    public static let analysingKicker = "Almost there"
    public static let analysingWaiting = "Reading your seat"

    static let footnote =
        "Taken with the iPhone's own microphone, which isn't calibrated. Trust the shapes and the differences more than the absolute decibels."

    // MARK: Verdict

    static let inconclusiveVerdict = "I need three clean spots to say how your seat sounds."
    static let evenVerdict = "From your seat, it all sounds even."
    static let leftRightVerdict = "From your seat, left and right don't sound the same."

    /// "the treble", "voices", "voices and treble" (as subjects: "the treble is", "voices are").
    static func restSubject(voices: Bool, treble: Bool) -> (noun: String, verb: String) {
        switch (voices, treble) {
        case (true, true): ("voices and treble", "are")
        case (true, false): ("voices", "are")
        default: ("the treble", "is")
        }
    }

    static let notAssessedVerdict = "The room was too loud against the speakers for me to judge your seat."

    /// The verdict. "Even", "balanced" and "the bass is even" are said only of a range that was assessed throughout
    /// (`bassChecked`, `restChecked`); otherwise the verdict says the room was too noisy to check it.
    static func verdict(
        bassUneven: Bool, voices: Bool, treble: Bool, leftRightDiffer: Bool,
        bassChecked: Bool = true, restChecked: Bool = true
    ) -> String {
        let restUneven = voices || treble
        let rest = restSubject(voices: voices, treble: treble)
        let differ = leftRightDiffer ? " Left and right don't sound the same." : ""
        switch (bassUneven, restUneven) {
        case (false, false):
            if bassChecked && restChecked { return leftRightDiffer ? leftRightVerdict : evenVerdict }
            let missing = !bassChecked && !restChecked ? "all of it" : (!bassChecked ? "the bass" : "the voices and treble")
            return "From your seat, what I could hear sounds even. The room was too noisy to check \(missing)." + differ
        case (true, false):
            let tail = restChecked ? (leftRightDiffer ? "" : " The rest is balanced.") : " The room was too noisy to check the voices and treble."
            return "From your seat, the bass is uneven." + tail + differ
        case (false, true):
            let tail = bassChecked ? (leftRightDiffer ? "" : " The bass is even.") : " The room was too noisy to check the bass."
            return "From your seat, \(rest.noun) \(rest.verb) uneven." + tail + differ
        case (true, true):
            return "From your seat, the bass and \(voices && treble ? "the rest" : rest.noun) are uneven." + differ
        }
    }

    static let bassUnchecked = "I couldn't check the bass over the room's noise"
    static let restUnchecked = "I couldn't check the voices and treble over the room's noise"

    /// "Around 30–180 Hz the room's noise was too close to the speakers' level."
    static func uncheckedDetail(_ range: FrequencyRange) -> String {
        "Around \(DiagnosisText.range(range)) the room's noise was too close to the speakers' level, so I can't say how it sounds there."
    }

    // MARK: Findings

    static let measuredTag = "Measured"

    private static func count(_ value: Int) -> String {
        switch value {
        case 2: "Two"
        case 3: "Three"
        default: "Several"
        }
    }

    /// "One bass note booms, one nearly vanishes", "One bass note booms", "Two bass notes are quiet".
    static func bassHeadline(peaks: Int, dips: Int, deepDip: Bool) -> String {
        let peakPart: String? = switch peaks {
        case 0: nil
        case 1: "One bass note booms"
        default: "\(count(peaks)) bass notes boom"
        }
        guard dips > 0 else { return peakPart ?? "" }
        let verb = dips == 1 ? (deepDip ? "nearly vanishes" : "is quiet") : (deepDip ? "nearly vanish" : "are quiet")
        if let peakPart {
            let subject = dips == 1 ? "one" : count(dips).lowercased()
            return "\(peakPart), \(subject) \(verb)"
        }
        return dips == 1 ? "One bass note \(verb)" : "\(count(dips)) bass notes \(verb)"
    }

    /// "41 Hz is 9 dB louder than the middle. 61 Hz is 11 dB quieter."
    static func extremesDetail(_ extremes: [SeatExtreme]) -> String {
        extremes.enumerated().map { index, extreme in
            let direction = extreme.deviation > 0 ? "louder" : "quieter"
            let tail = index == 0 ? " than the middle" : ""
            return "\(frequency(extreme.frequency)) is \(decibels(extreme.deviation)) \(direction)\(tail)."
        }.joined(separator: " ")
    }

    static func restEven(leftMatches: Bool) -> String {
        leftMatches ? "Voices and treble are even, left matches right" : "Voices and treble are even"
    }

    static let restEvenDetail = "Above the bass, everything stays within 3 dB of the middle."

    static func restUneven(voices: Bool, treble: Bool) -> String {
        let rest = restSubject(voices: voices, treble: treble)
        let noun = rest.noun.prefix(1).uppercased() + rest.noun.dropFirst()
        return "\(noun) \(rest.verb) uneven"
    }

    /// "Measured · within 1.2 dB".
    static func matchTagLine(_ difference: Float) -> String { "\(measuredTag) · within \(differenceTenths(difference))" }

    static let leftMatches = "Left matches right"

    static func leftMatchesDetail(_ difference: Float) -> String {
        "Above the bass, the two speakers stay within \(differenceTenths(difference)) of each other."
    }

    /// "Left and right differ in the treble".
    static func leftRightDiffer(treble: Bool) -> String {
        "Left and right differ in \(treble ? "the treble" : "the voices")"
    }

    /// "Measured · up to 4.9 dB apart".
    static func differTagLine(_ difference: Float) -> String { "\(measuredTag) · up to \(decibelsTenths(difference)) apart" }

    static func leftRightDetail(rightLouder: Bool, at frequency: Float) -> String {
        "Around \(self.frequency(frequency)) the \(rightLouder ? "right" : "left") speaker is louder. It could be the speakers, their settings or what is near them."
    }

    static let causeHeadline = "It's the room, not the speakers"

    /// "Inferred from room size. Moving speakers should help."
    static func causeTagLine(_ basis: SeatBasis) -> String {
        switch basis {
        case .roomSize: "Inferred from room size. Moving speakers should help."
        case .spotToSpot: "Inferred from how it changes between spots. Moving speakers should help."
        }
    }

    static func causeDetail(_ basis: SeatBasis, extremes: [SeatExtreme]) -> String {
        let list = extremes.map { frequency($0.frequency) }
        let names = list.count <= 1 ? (list.first ?? "") : list.dropLast().joined(separator: ", ") + " and " + list.last!
        switch basis {
        case .roomSize:
            return "\(names) \(list.count == 1 ? "is" : "are") where this room's size makes the bass resonate. That points to the room, though I can't be certain."
        case .spotToSpot:
            let most = extremes.map(\.spread).max() ?? 0
            return "Around \(names) the bass changed by up to \(decibels(most)) between spots a few steps apart. A speaker's own sound wouldn't, so it points to the room."
        }
    }

    // MARK: Spots that could not be used

    static func spotName(_ index: Int) -> String {
        switch index {
        case 0: "seat"
        case 1: "left"
        case 2: "right"
        default: "extra"
        }
    }

    static func invalidSpotHeadline(_ index: Int) -> String { "The \(spotName(index)) spot needs measuring again" }

    static func invalidSpotDetail(_ problem: RecordingCheck.Problem) -> String {
        switch problem {
        case .clipped: "The microphone clipped. Turning the volume down a little helps."
        case .tooQuiet: "I could barely hear the speakers. Turning the volume up helps."
        case .tooNoisy: "The room was too loud against the speakers."
        case .silent: "The microphone gave me silence."
        case .corrupt: "The recording came back damaged. Measuring again usually fixes it."
        case .incomplete: "The recording stopped before the whole test sound had reached me."
        }
    }

    static let inconclusiveTag = "Inconclusive"

    // MARK: Numbers table

    static let peakWord = "peak"
    static let dipWord = "dip"
    static let matchWord = "match"
    static let differWord = "differ"
    static let distortionWord = "distortion"
    static let decayWord = "decay"
    static let leftRightLabel = "L / R"

    /// "±1.2 dB".
    static func plusMinus(_ value: Float) -> String { "±\(differenceTenths(value))" }

    /// "< 80 Hz".
    static func below(_ frequency: Float) -> String { "< \(self.frequency(frequency))" }

    /// "≈ 0.6 s".
    static func approximately(seconds: Double) -> String { String(format: "≈ %.1f s", seconds) }

    // MARK: Comparison

    static let compareInconclusive = "I need a complete measurement from your seat to compare."
    static let unchangedVerdict = "Nothing changed that I can measure."
    static let worseVerdict = "It sounds worse from your seat than before."
    static let mixedVerdict = "It's better in one place and worse in another."

    static func noteName(_ kind: SeatExtreme.Kind, depth: Float, threshold: Float) -> String {
        kind == .peak ? "booming" : (abs(depth) >= threshold ? "missing" : "quiet")
    }

    /// "The missing bass note is back.", "The booming bass note is calmer now."
    static func fixedVerdict(_ kind: SeatExtreme.Kind) -> String {
        kind == .dip ? "The missing bass note is back." : "The booming bass note is calmer now."
    }

    /// For a note that improved but is still outside the even band, with what is left of it (`now`, dB):
    /// "It's a little better: the missing bass note is less quiet, now −7 dB."
    static func partlyVerdict(_ kind: SeatExtreme.Kind, now: Float) -> String {
        kind == .dip
            ? "It's a little better: the missing bass note is less quiet, now \(signedDecibels(now))."
            : "It's a little better: the booming bass note is less strong, now \(signedDecibels(now))."
    }

    /// A note that changed sign and now lies outside the even band: a new problem, not a fix.
    static func flippedVerdict(_ kind: SeatExtreme.Kind) -> String {
        kind == .dip ? "The missing bass note now booms instead." : "The booming bass note is now missing instead."
    }

    /// When only voices and treble improved.
    static let restEvenVerdict = "Voices and treble are even now."
    static let restBetterVerdict = "It's a little better: voices and treble are more even."

    /// "Missing note, 61 Hz", "Booming note, 41 Hz", "Quiet note, 70 Hz"; "New booming note, 120 Hz".
    static func rowLabel(_ kind: SeatExtreme.Kind, frequency: Float, depth: Float, threshold: Float, new: Bool = false) -> String {
        let name = noteName(kind, depth: depth, threshold: threshold)
        let capitalised = name.prefix(1).uppercased() + name.dropFirst()
        return new ? "New \(name) note, \(self.frequency(frequency))" : "\(capitalised) note, \(self.frequency(frequency))"
    }

    static let restRowLabel = "Voices and treble"
    static let restUnchangedEven = "Unchanged, still even"
    static let restChangedEven = "Changed a little, still even"
    static let restUnevenNow = "Uneven now"
    static let restEvenNow = "Even now"
    static let restBetter = "Better, still uneven"
    static let restWorse = "Worse than before"
    static let restUnchangedUneven = "Unchanged, still uneven"
    /// A change inside the repeatability that crossed the edge of the even band.
    static let restAboutSameEven = "About the same, just inside the even band"
    static let restAboutSameUneven = "About the same, just outside the even band"

    static let notePrefix = "All measured just now."

    /// "The 41 Hz boom is still a little strong; the next suggestion targets it." Without "still" for a problem the
    /// move made (`new`).
    static func remaining(_ extreme: SeatExtreme, threshold: Float, bass: Bool, new: Bool = false) -> String {
        let mild = abs(extreme.deviation) < threshold
        let name = extreme.kind == .peak ? "boom" : "dip"
        var state = extreme.kind == .peak ? (mild ? "still a little strong" : "still strong") : (mild ? "still a little deep" : "still deep")
        if new { state = String(state.dropFirst("still ".count)) }
        let tail = bass ? "; the next suggestion targets it." : ". Moving speakers won't change it much."
        return "The \(frequency(extreme.frequency)) \(name) is \(state)\(tail)"
    }

    static let nothingRemains = "Nothing is left outside the even band."
    static let putBack = "Putting the speaker back where it was is the safe choice."
}
