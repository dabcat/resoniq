/// Every string of the three intro screens, as in design/screens/V3Onb1 to V3Onb3, plus the accessibility
/// sentences.
enum IntroText {
    static let skip = "Skip intro"
    static let next = "Next"
    static let tryOnSpeaker = "Try it on a speaker"

    struct Page {
        let kicker: String
        let headline: String
        let body: String
    }

    static let pages = [
        Page(
            kicker: "Diagnose",
            headline: "Find out if a speaker is healthy.",
            body: "Useful before you buy a used pair, or when something at home starts to sound off."
        ),
        Page(
            kicker: "Measure",
            headline: "See how it really sounds where you sit.",
            body: "Sit down, hold the phone at ear height, and Resoniq tells you in plain words what the room does to your music."
        ),
        Page(
            kicker: "Optimize",
            headline: "Put every speaker in its best spot.",
            body: "Scan the room with the camera, measure, then follow outlines on the floor in AR. Measure again to prove it got better."
        ),
    ]

    // Page 1
    struct Step {
        let label: String
        let sentence: String
    }

    static let steps = [
        Step(label: "1 · Play", sentence: "A tone rises from the deepest bass to the highest treble."),
        Step(label: "2 · Listen", sentence: "Your iPhone hears how the speaker answers each note."),
        Step(label: "3 · Read", sentence: "A smooth shape is healthy. A rough patch shows where it rattles or buzzes."),
    ]
    static let portraitSummary =
        "A speaker's portrait drawing itself from the bass upward along a frequency ruler, with one rough orange patch low down."

    // Page 2
    static let curveTitle = "Loudness at your seat"
    /// The mockup labels the band inside the plot ("even band"); the curve component names it in the header.
    static let curveDetail = "Even band \u{00B1}3 dB"
    static let tooLoud = "too loud"
    static let nearlyGone = "nearly gone"
    static let threeSpots = "Measured at three spots around your head, then averaged."
    static let curveSummary =
        "A line showing loudness from bass to treble. It should stay inside a shaded even band; in the bass it swings far outside, too loud at one pitch and nearly gone at another."

    // Page 3
    static let moveHere = "move here"
    static let roomSummary =
        "A room from above. The right speaker slides forward into a blue outline and the orange problem area around the seat fades."

    // The controls
    static let pageIndicator = "Page"
    static func pageValue(_ page: Int) -> String { "\(page) of \(pages.count)" }
    static func counter(_ page: Int) -> String { "0\(page) / 0\(pages.count)" }
}
