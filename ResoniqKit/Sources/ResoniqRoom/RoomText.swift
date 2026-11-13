import Foundation

/// Every user-facing string this module produces, in English, in one place so it can be localised.
///
/// The voice is the design system's: first person, calm, hedged ("should", "may", never "will"), no jargon in the
/// main sentence, units in the details. Numbers are formatted without the locale (a full stop for decimals), as in
/// the mockups; localisation replaces this type.
public enum RoomText {
    // MARK: Lengths, angles, frequencies

    /// A distance in metres with two decimals: "0.90 m", "4.20 m".
    public static func metres(_ metres: Double) -> String { "\(twoDecimals(metres)) m" }

    /// A move: whole centimetres under a metre ("35 cm"), metres with two decimals from there ("1.20 m").
    public static func move(_ metres: Double) -> String {
        let parts = moveParts(metres)
        return "\(parts.value) \(parts.unit)"
    }

    /// A move split into number and unit, for the AR readout's large number ("18" and "cm").
    public static func moveParts(_ metres: Double) -> (value: String, unit: String) {
        let centimetres = (max(0, metres) * 100).rounded()
        if centimetres < 100 { return ("\(Int(centimetres))", "cm") }
        return (twoDecimals(metres), "m")
    }

    /// The plan sides, shorter first: "4.20 × 5.60 m".
    public static func dimensions(_ dimensions: RoomDimensions) -> String {
        let sides = dimensions.sortedSides
        return "\(twoDecimals(sides.shorter)) × \(twoDecimals(sides.longer)) m"
    }

    /// "Living room · 4.20 × 5.60 m". The name is the person's.
    public static func roomTitle(name: String, dimensions: RoomDimensions) -> String {
        "\(name) · \(Self.dimensions(dimensions))"
    }

    /// "3 of 4 walls".
    public static func wallsCaptured(_ coverage: WallCoverage) -> String {
        "\(coverage.captured) of \(coverage.expected) walls"
    }

    /// Whole degrees of a turn's size: "12°".
    public static func degrees(_ radians: Double) -> String {
        "\(Int(PlanAngle.degrees(abs(radians)).rounded()))°"
    }

    /// "61 Hz" below 1 kHz (whole hertz), "1.2 kHz" above.
    public static func frequency(_ hertz: Double) -> String {
        if hertz < 999.5 { return "\(Int(hertz.rounded())) Hz" }
        return "\(String(format: "%.1f", hertz / 1000)) kHz"
    }

    /// A problem's label on the plan: "61 Hz −11 dB" for a dip, "45 Hz +6 dB" for a peak.
    public static func problemLabel(_ problem: AcousticProblem) -> String {
        let sign = problem.kind == .dip ? "−" : "+"
        return "\(frequency(problem.frequency)) \(sign)\(Int(abs(problem.deviation).rounded())) dB"
    }

    // MARK: Plan and layout

    public static let legendMeasured = "Measured here"
    public static let legendSuggested = "Suggested, not yet tested"
    public static let seatName = "Your seat"

    /// Under the Confirm layout plan after a scan. RoomPlan does not recognise loudspeakers, so this says the
    /// speakers and seat were guessed (the mockup's "I spotted the speakers" claims more than the scan can).
    public static let layoutGuessHint =
        "Drag a speaker or your seat to correct it. The scan can't see speakers, so I guessed where they and your seat are. Check each one."

    /// The short name on the plan: "Left", "Right", "Speaker", "Subwoofer".
    public static func shortName(_ role: SpeakerRole) -> String {
        switch role {
        case .left: "Left"
        case .right: "Right"
        case .single: "Speaker"
        case .subwoofer: "Subwoofer"
        }
    }

    /// The name heading a readout: "Right speaker".
    public static func title(_ role: SpeakerRole) -> String {
        switch role {
        case .left: "Left speaker"
        case .right: "Right speaker"
        case .single: "Speaker"
        case .subwoofer: "Subwoofer"
        }
    }

    static func inSentence(_ role: SpeakerRole) -> String {
        switch role {
        case .left: "the left speaker"
        case .right: "the right speaker"
        case .single: "the speaker"
        case .subwoofer: "the subwoofer"
        }
    }

    /// Why a hand-entered room was refused.
    public static func manualIssue(_ issue: ManualRoom.Issue) -> String {
        let side = "between \(oneDecimal(ManualRoom.minimumSide)) and \(oneDecimal(ManualRoom.maximumSide)) m"
        let height = "between \(oneDecimal(ManualRoom.minimumHeight)) and \(oneDecimal(ManualRoom.maximumHeight)) m"
        return switch issue {
        case .widthOutOfRange: "The width should be \(side). Is it in metres?"
        case .lengthOutOfRange: "The length should be \(side). Is it in metres?"
        case .heightOutOfRange: "The ceiling height should be \(height)."
        }
    }

    // MARK: Listening geometry

    /// One line on what is uneven, from the room's shape.
    public static func geometryIssue(_ issue: ListeningGeometry.Issue, in geometry: ListeningGeometry) -> String {
        switch issue {
        case .tooWide, .tooNarrow:
            "The speakers span \(degrees(geometry.subtendedAngle)) from your seat; about \(degrees(ListeningGeometry.idealAngle)) is the usual aim."
        case .closerTo(let role):
            "Your seat is \(move(abs(geometry.distanceDifference))) closer to \(inSentence(role))."
        case .notToedIn(let role):
            "\(title(role)) points \(degrees(role == .left ? geometry.leftToeInError : geometry.rightToeInError)) away from your seat."
        }
    }

    /// The pair seen from the seat, in a sentence.
    public static func geometrySummary(_ geometry: ListeningGeometry) -> String {
        geometry.isEven
            ? "The speakers and your seat make an even triangle."
            : "The triangle between the speakers and your seat is a little uneven."
    }

    public static let roomShapeBasis = "From the room's shape, not yet measured."

    // MARK: Suggestions

    static func direction(_ direction: MoveDirection) -> String {
        switch direction {
        case .forward: "forward"
        case .back: "back"
        case .left: "to the left"
        case .right: "to the right"
        }
    }

    static func slidePhrase(_ slide: Slide) -> String { "\(move(slide.distance)) \(direction(slide.direction))" }

    static func outcome(_ goal: SuggestionGoal) -> String {
        switch goal {
        case .problem(let problem):
            switch problem.kind {
            case .dip: "the missing \(noteName(problem)) should return"
            case .peak: "the boomy \(noteName(problem)) should calm down"
            }
        case .evenDistances: "both speakers should be the same distance from you"
        case .evenAngle: "the stereo image should spread more evenly"
        case .toeIn: "the stereo image should sharpen"
        }
    }

    static func noteName(_ problem: AcousticProblem) -> String {
        problem.frequency <= 250 ? "bass note" : "note"
    }

    /// The main sentence: "Pull the right speaker 35 cm forward and the missing bass note should return."
    static func headline(role: SpeakerRole, slides: [Slide], turn: Turn?, goal: SuggestionGoal) -> String {
        let who = inSentence(role)
        switch slides.count {
        case 0:
            let angle = degrees(turn?.angle ?? 0)
            return "Turn \(who) \(angle) toward your seat and \(outcome(goal))."
        case 1:
            let verb: String = switch slides[0].direction {
            case .forward: "Pull"
            case .back: "Push"
            case .left, .right: "Slide"
            }
            return "\(verb) \(who) \(slidePhrase(slides[0])) and \(outcome(goal))."
        default:
            let path = slides.map(slidePhrase).joined(separator: ", then ")
            return "Move \(who) \(path), and \(outcome(goal))."
        }
    }

    static func surface(_ surface: BoundarySurface) -> String {
        switch surface {
        case .wallBehind: "The wall behind it"
        case .sideWall: "The wall beside it"
        case .floor: "The floor"
        }
    }

    static func dimensionName(_ dimension: RoomDimension) -> String {
        switch dimension {
        case .width: "width"
        case .length: "length"
        case .height: "height"
        }
    }

    /// The short reason under the headline; units are fine here.
    static func reason(_ reason: SuggestionReason, slides: [Slide], geometry: ListeningGeometry?) -> String {
        let total = move(slides.reduce(0) { $0 + $1.distance })
        switch reason {
        case .boundary(let surface, let before, let after):
            return "\(Self.surface(surface)) may be cancelling \(frequency(before)). Moving \(total) should shift that dip to about \(frequency(after))."
        case .mode(let mode, let kind, _, _):
            let start = "The room's \(dimensionName(mode.dimension)) resonates near \(frequency(mode.frequency))"
            return switch kind {
            case .dip: "\(start), and the speaker sits where that note is weak. The new spot should drive it more."
            case .peak: "\(start), and the speaker sits where that note is strong. The new spot should drive it less."
            }
        case .geometry(let issue):
            guard let geometry else { return roomShapeBasis }
            return "\(roomShapeBasis) \(geometryIssue(issue, in: geometry))"
        }
    }

    /// The AR readout's total: "35 cm in total".
    public static func totalDistance(_ metres: Double) -> String { "\(move(metres)) in total" }

    /// The AR readout's turn line: "then turn 12° toward your seat".
    public static func thenTurn(_ turn: Turn) -> String { "then turn \(degrees(turn.angle)) toward your seat" }

    /// "step 1 of 2".
    public static func stepLabel(_ number: Int, of count: Int) -> String { "step \(number) of \(count)" }

    /// The AR header: "Right speaker · step 1 of 2".
    public static func stepTitle(role: SpeakerRole, step number: Int, of count: Int) -> String {
        "\(title(role)) · \(stepLabel(number, of: count))"
    }

    /// One step as an instruction: "Slide it 35 cm forward." or "Turn it 12° toward your seat."
    public static func stepInstruction(_ step: SuggestionStep) -> String {
        switch step {
        case .slide(let slide): "Slide it \(slidePhrase(slide))."
        case .turn(let turn): "Turn it \(degrees(turn.angle)) toward your seat."
        }
    }

    /// When no model term explains a measured problem.
    public static func unexplained(_ problem: AcousticProblem) -> String {
        "I can't tie the \(problem.kind == .dip ? "dip" : "peak") at \(frequency(problem.frequency)) to the room's shape, so I won't guess a move for it."
    }

    // MARK: AR guidance

    /// Under the AR readout: "Slide it toward you until it fills the blue outline."
    public static func slideInstruction(_ direction: ViewerDirection) -> String {
        "Slide it \(viewerWay(direction)) until it fills the blue outline."
    }

    /// The arc's label on the floor: "turn 12°".
    public static func turnLabel(_ radians: Double) -> String { "turn \(degrees(radians))" }

    /// What VoiceOver says of a slide: "18 centimetres to go, toward you", "1.20 metres to go, to your left",
    /// or "In place" without a direction.
    public static func spokenProgress(distance: Double, direction: ViewerDirection?) -> String {
        guard let direction else { return "In place" }
        let centimetres = Int((max(0, distance) * 100).rounded())
        let amount = centimetres < 100
            ? "\(centimetres) \(centimetres == 1 ? "centimetre" : "centimetres")"
            : "\(twoDecimals(distance)) metres"
        return "\(amount) to go, \(viewerWay(direction))"
    }

    static func viewerWay(_ direction: ViewerDirection) -> String {
        switch direction {
        case .towardYou: "toward you"
        case .awayFromYou: "away from you"
        case .left: "to your left"
        case .right: "to your right"
        }
    }

    public static let toGoLabel = "To go"
    public static let hapticHint = "Taps in your hand speed up as you get closer."
    public static let arrived = "That's the spot. Turn it toward your seat if the arc is still showing."

    // MARK: Numbers

    static func twoDecimals(_ value: Double) -> String { String(format: "%.2f", value) }
    static func oneDecimal(_ value: Double) -> String { String(format: "%.1f", value) }
}
