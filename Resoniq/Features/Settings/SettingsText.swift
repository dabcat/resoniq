import ResoniqStore

/// Every string of Settings, in the design system's voice: first person, calm, specific.
enum SettingsText {
    static let title = "Settings"
    static let done = "Done"

    // Your data
    static let dataLabel = "Your data"
    static let dataIntro = "This is what I keep on your iPhone."
    static let rooms = "Rooms"
    static let systems = "Sound systems"
    static let speakerTests = "Speaker tests"
    static let seatMeasurements = "Seat measurements"
    static let roomScans = "Room scans"
    static let privacy =
        "Nothing leaves your iPhone. I analyse a recording while you listen and don't keep it, only what I found in it."
    static let deleteResults = "Delete all results"
    static let deleteEverything = "Delete everything"
    static let noResults = "There are no results to delete yet."

    static let deleteResultsTitle = "Delete all results?"
    static let deleteEverythingTitle = "Delete everything?"
    static let deleteResultsConfirm = "Delete results"
    static let deleteEverythingConfirm = "Delete everything"
    static let cancel = "Cancel"
    static let failureTitle = "I could not finish that"
    static let failureMessage = "Nothing more was removed. Please try again."
    static let ok = "OK"

    /// What "Delete all results" removes, said exactly.
    static func deleteResultsMessage(_ counts: StoreCounts) -> String {
        "I will remove \(list(tests: counts.speakerTests, measurements: counts.seatMeasurements)) from this iPhone. "
            + "Your rooms, sound systems and room scans stay. This cannot be undone."
    }

    /// What "Delete everything" removes, said exactly.
    static func deleteEverythingMessage(_ counts: StoreCounts) -> String {
        var parts = [count(counts.rooms, "room"), count(counts.systems, "sound system")]
        parts.append(count(counts.speakerTests, "speaker test"))
        parts.append(count(counts.seatMeasurements, "seat measurement"))
        parts.append(count(counts.roomScans, "room scan"))
        return "I will remove \(join(parts)) from this iPhone. "
            + "Then I start again with \u{201C}\(StoreText.defaultRoomName)\u{201D} and "
            + "\u{201C}\(StoreText.defaultSystemName)\u{201D}. This cannot be undone."
    }

    // Measurement
    static let measurementLabel = "Measurement"
    static let testSound =
        "The test sound is a tone that rises from the deepest bass to the highest treble, at a level chosen to be "
        + "safe for your speakers. The volume is yours: set it so you hear the tone clearly but comfortably."
    static let microphone =
        "The microphone in an iPhone is not calibrated. So I trust the shape of a curve and the difference between "
        + "two measurements, more than any absolute decibel figure."

    // Intro
    static let introLabel = "Intro"
    static let showIntro = "Show the intro again"
    static let introScheduled = "I will show it again the next time you open Resoniq."

    // About
    static let aboutLabel = "About"
    static let appName = "Resoniq"
    static let licences = "Licences"
    static let licencesIntro = "Resoniq is set in two typefaces under the SIL Open Font License 1.1."

    static func version(_ version: String, build: String) -> String { "Version \(version) (\(build))" }

    // Helpers
    static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }

    private static func list(tests: Int, measurements: Int) -> String {
        join([count(tests, "speaker test"), count(measurements, "seat measurement")])
    }

    private static func join(_ parts: [String]) -> String {
        guard let last = parts.last, parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }
}
