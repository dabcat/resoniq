import ResoniqShare
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
    /// The privacy line. A build that can share says the one way something can leave, and that it is the person's.
    static func privacy(canShare: Bool) -> String {
        (canShare ? "Nothing leaves your iPhone unless you turn on sharing below. " : "Nothing leaves your iPhone. ")
            + "I analyse a recording while you listen and keep only what I found in it, unless you ask me to keep "
            + "recordings below."
    }
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
        let recordings = counts.recordings > 0 ? ", with the recordings kept for them," : ""
        return "I will remove \(list(tests: counts.speakerTests, measurements: counts.seatMeasurements))\(recordings) "
            + "from this iPhone. Your rooms, sound systems and room scans stay. This cannot be undone."
    }

    /// What "Delete everything" removes, said exactly.
    static func deleteEverythingMessage(_ counts: StoreCounts) -> String {
        var parts = [count(counts.rooms, "room"), count(counts.systems, "sound system")]
        parts.append(count(counts.speakerTests, "speaker test"))
        parts.append(count(counts.seatMeasurements, "seat measurement"))
        parts.append(count(counts.roomScans, "room scan"))
        if counts.recordings > 0 { parts.append("the recordings of \(count(counts.recordings, "speaker test"))") }
        return "I will remove \(join(parts)) from this iPhone. "
            + "Then I start again with \u{201C}\(StoreText.defaultRoomName)\u{201D} and "
            + "\u{201C}\(StoreText.defaultSystemName)\u{201D}. This cannot be undone."
    }

    // Recordings
    static let recordingsLabel = "Recordings"
    static let keepRecordings = "Keep recordings"
    static func recordingsExplanation(canShare: Bool) -> String {
        "When this is on, I keep the raw sound of each speaker test you keep, in Resoniq's folder in the Files app, "
            + (canShare ? "and it stays on this iPhone unless you share it below." : "and it stays on this iPhone.")
    }
    static let recordingsSpace = "Space used"
    static let deleteRecordings = "Delete recordings"
    static let deleteRecordingsTitle = "Delete recordings?"
    static let deleteRecordingsConfirm = "Delete recordings"

    /// "9.6 MB", as the Files app counts; "0 MB" when nothing is kept (the formatter's own word is "Zero kB").
    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "0 MB" : bytes.formatted(.byteCount(style: .file))
    }

    /// What "Delete recordings" removes, said exactly.
    static func deleteRecordingsMessage(_ counts: StoreCounts) -> String {
        "I will remove the recordings of \(count(counts.recordings, "speaker test")) from this iPhone. "
            + "The results stay. This cannot be undone."
    }

    // Sharing (phase 10; no mockup: the rows of "Recordings", the same toggle, lines and outlined buttons)
    static let shareRecordings = "Share recordings for research"
    static let shareExplanation =
        "When this is on, I send the raw sound of each speaker test you keep to the people who make Resoniq, over "
        + "Wi-Fi, to make my measurements more reliable. Nothing else is sent, and nothing about who or where you are."
    static let shareTurnedKeepOn = "I turned on Keep recordings too: I can only share what I keep."
    static let sendExisting = "Send the recordings I already have"
    static let deleteShared = "Delete what I shared"
    static let deleteSharedTitle = "Delete what you shared?"
    static let deleteSharedConfirm = "Delete what I shared"
    static let deleteSharedMessage =
        "I will ask Resoniq's storage to delete every recording this iPhone sent. The recordings and results on this "
        + "iPhone stay."
    static let deleteSharedDone = "Everything this iPhone shared has been deleted."
    static let deleteSharedFailedTitle = "I could not reach Resoniq's storage"
    static let deleteSharedFailedMessage = "Nothing was deleted yet. Try again when this iPhone is online."

    /// "3 speaker tests kept while sharing was off. I send them only if you ask."
    static func notQueued(_ count: Int) -> String {
        "\(Self.count(count, "speaker test")) kept while sharing was off. I send them only if you ask."
    }

    /// The status line under the toggle: what went, what waits, and the last problem.
    static func shareStatus(_ status: ShareStatus, isOn: Bool) -> String {
        var line: String
        switch (status.sent, status.waiting) {
        case (0, 0):
            line = isOn ? "Nothing sent yet. I send each speaker test you keep from now on." : "Nothing is being sent."
        case (let sent, 0):
            line = "I have sent \(count(sent, "speaker test"))."
        case (0, let waiting):
            line = "\(count(waiting, "speaker test")) waiting to be sent."
        case (let sent, let waiting):
            line = "I have sent \(count(sent, "speaker test")); \(waiting) waiting."
        }
        if status.refused > 0 {
            line += status.refused == 1
                ? " One was too large to send." : " \(status.refused) were too large to send."
        }
        switch status.problem {
        case .unreachable?: line += " I send over Wi-Fi only, and will try again when Resoniq is open on Wi-Fi."
        case .serviceError?: line += " Resoniq's storage did not answer; I will try again later."
        case .overQuota?: line += " I stopped: the space for this iPhone's recordings is full. Delete what you shared to start again."
        case .tokenNotKept?: line += " I stopped: I could not keep this iPhone's key for Resoniq's storage, so I sent nothing. Turn sharing off and on to try again."
        case .rejected?: line += " I stopped: Resoniq's storage would not accept this iPhone. Turn sharing off and on to try again."
        case .refused?, nil: break
        }
        return line
    }

    // Consent (a sheet; no mockup)
    static let consentTitle = "Share recordings for research"
    static let consentCancel = "Cancel"
    static let consentConfirm = "Share"
    static let consentIntro =
        "If you turn this on, I send the raw sound of each speaker test you keep to the people who make Resoniq. "
        + "They use it to tune how I measure, so I tell a healthy speaker from a faulty one more reliably."
    static let consentSentLabel = "What I send"
    static let consentSent =
        "The recording of each run of the test sound, and of the room's quiet before it. With it: how I measured "
        + "(the test sound, the timings, what I found), the day, the model of your iPhone, its iOS version and "
        + "Resoniq's version."
    static let consentVoices =
        "A recording is of your room, so it can hold voices or anything else that could be heard while I listened."
    static let consentNotSentLabel = "What I don't send"
    static let consentNotSent =
        "The names you gave your rooms and sound systems, the names of your speakers or headphones, the time of day, "
        + "who you are, or where you are. Speaker tests kept before you turn this on stay here unless you ask me to "
        + "send them."
    static let consentWhereLabel = "Where it goes"
    static let consentWhere =
        "To storage kept by the people who make Resoniq, used only to tune the measurements. I send over Wi-Fi only, "
        + "never over mobile data, and never while you wait for a result."
    static let consentStopLabel = "Stopping and deleting"
    static let consentStop =
        "Turn this off in Settings at any time and I send nothing more. \u{201C}Delete what I shared\u{201D} in Settings "
        + "deletes everything this iPhone sent."
    static let consentKeep = "Sharing needs Keep recordings, so I will turn that on too."

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
