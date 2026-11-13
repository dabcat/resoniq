import Foundation

/// The static words of the Optimize screens that the Kit does not own: buttons, headings that say what a screen is
/// for, and the labels of the form. Every sentence about the room, a suggestion or a result comes from the Kit
/// (`RoomText`, `SeatText`, the reports); the voice is the design system's: first person, calm, hedged.
nonisolated enum OptimizeText {
    // MARK: Tracker

    static let stepScanned = "Scanned"
    static let stepMeasured = "Measured"
    static let stepMove = "Move"
    static let stepMoved = "Moved"
    static let stepVerify = "Verify"
    static let stepVerified = "Verified"

    // MARK: Home

    static let rescan = "Rescan"
    static let editLayout = "Edit layout"
    static let scanMyRoom = "Scan my room"
    static let enterByHand = "Enter the room by hand"
    static let measureFromSeat = "Measure from my seat"
    static let measureAgain = "Measure again"
    static let measureAgainFromSeat = "Measure again from my seat"
    static let guideInAR = "Guide me in AR"
    static let moveMyself = "I'll move it myself, then re-measure"
    static let showVerification = "See before and after"

    /// No room yet: what scanning gives.
    static let noRoomHeadline = "Scan the room, and I can show where the walls, the sofa and your seat are, then suggest where a speaker should go."
    /// A room, not measured.
    static let notMeasuredHeadline = "Measure from your seat to see what the room is doing to the bass."
    /// The speaker was moved and nothing has been measured since.
    static let movedHeadline = "Measure again from the same seat to see whether the move helped."

    static let measuredAtSeat = "Measured at three spots at your seat."
    static func problemArea(_ label: String) -> String { "A problem area at your seat: \(label)." }

    // MARK: Confirm layout

    static let layoutQuestion = "Is this where everything really is?"
    static let planSegment = "Plan"
    static let threeDSegment = "3D"
    static let viewLabel = "View"
    static let addSubwoofer = "Add subwoofer"
    static let addSeat = "Add a seat"
    static let fixWall = "Fix a wall"
    static let confirmLayout = "Looks right, measure the room"
    static let dragHint = "Drag a speaker or your seat to correct it."
    static let threeDHint = "Drag to turn the room around. Switch to Plan to move things."
    static let removeSubwoofer = "Remove this subwoofer"
    static let removeSeat = "Remove this seat"
    static let fixWallMessage = "The walls came from the scan. To fix one, scan the room again."
    static let scanAgain = "Scan again"
    static let cancel = "Cancel"
    static let back = "Back"
    static let threeDSummary = "The room from above and a little to the side, with the walls, furniture, speakers and your seat as boxes. Drag to turn it."
    static let threeDHeightsNote = "Heights are for orientation only."

    // MARK: Manual room

    static let manualCaption = "Room size"
    static let manualHeadline = "How big is the room?"
    static let manualHint = "Measure along the walls, in metres. I'll guess where the speakers and your seat are, and you can correct me next."
    static let width = "Width"
    static let length = "Length"
    static let height = "Ceiling height"
    static let metresUnit = "m"
    static let useThisRoom = "Use this room"
    static let manualPreviewSummary = "Plan of the room from above."
    static let close = "Close"

    // MARK: Before and after

    static let before = "Before"
    static let keepThisSetup = "Keep this setup"
    static let nextSuggestion = "Next suggestion"
    static let putBack = "Put the speaker back where it was"
    static let gotWorse = ", got worse"
    static let curveIntro = "Loudness at your seat, before and after the move, at the same spots."
    static let afterWordsLocale = Locale(identifier: "en_US")

    /// "After, same three spots".
    static func after(spots: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = afterWordsLocale
        formatter.numberStyle = .spellOut
        let words = formatter.string(from: NSNumber(value: spots)) ?? "\(spots)"
        return "After, same \(words) spots"
    }
}
