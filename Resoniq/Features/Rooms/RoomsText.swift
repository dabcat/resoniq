import ResoniqStore

/// Every string of the rooms and systems sheet, in the design system's voice.
enum RoomsText {
    static let title = "Rooms and systems"
    static let done = "Done"
    static let edit = "Edit"
    static let stopEditing = "Stop editing"
    static let cancel = "Cancel"
    static let selected = "Selected"
    static let intro = "Pick the sound system you are listening to. Every tab shows it."

    static let addRoom = "Add a room"
    static let addSystem = "Add a system"
    static let rename = "Rename"
    static let delete = "Delete"
    static let add = "Add"
    static let save = "Save"

    static let newRoomTitle = "New room"
    static let newRoomMessage = "Name it anything you like. I add a first sound system to it."
    static let renameRoomTitle = "Rename room"
    static let renameSystemTitle = "Rename sound system"
    static let roomNameField = "Room name"
    static let systemNameField = "System name"

    static let newSystemTitle = "New sound system"
    static let kindHeader = "Kind"
    static let nameHeader = "Name"
    static let kindFootnote = "I never ask for a make or model."

    // Deleting
    static func deleteRoomTitle(_ name: String) -> String { "Delete \u{201C}\(name)\u{201D}?" }
    static func deleteSystemTitle(_ name: String) -> String { "Delete \u{201C}\(name)\u{201D}?" }
    static let deleteRoomConfirm = "Delete room"
    static let deleteSystemConfirm = "Delete system"

    static func deleteRoomMessage(_ counts: StoreCounts) -> String {
        var parts = [count(counts.systems, "sound system"), count(counts.speakerTests, "speaker test"),
                     count(counts.seatMeasurements, "seat measurement")]
        if counts.roomScans > 0 { parts.append("its room scan") }
        return "I will remove the room with \(join(parts)). This cannot be undone."
    }

    static func deleteSystemMessage(_ counts: StoreCounts) -> String {
        "I will remove the sound system with \(count(counts.speakerTests, "speaker test")) and "
            + "\(count(counts.seatMeasurements, "seat measurement")). This cannot be undone."
    }

    // The two things that cannot be deleted, and why
    static let lastRoomTitle = "I can't delete the last room"
    static let lastRoomMessage = "Resoniq always needs a room to listen in. Add another room first, or rename this one."
    static let lastSystemTitle = "I can't delete the last sound system"
    static let lastSystemMessage =
        "A room keeps at least one sound system, so there is always something to measure. "
        + "Add another system to this room first, or rename this one."
    static let ok = "OK"

    static let failureTitle = "I could not do that"
    static let failureMessage = "Nothing was changed. Please try again."

    // VoiceOver
    static func systemLabel(name: String, kind: String, room: String) -> String { "\(name), \(kind), in \(room)" }
    static func roomActions(_ name: String) -> String { "\(name) actions" }

    static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }

    private static func join(_ parts: [String]) -> String {
        guard let last = parts.last, parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }
}
