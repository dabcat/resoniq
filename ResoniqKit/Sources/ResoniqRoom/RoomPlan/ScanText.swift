import Foundation

/// One instruction on the Scan screen: the sentence, the line under it, and the arrow's direction if it has one.
public struct ScanGuidance: Sendable, Equatable {
    public var headline: String
    public var detail: String
    public var direction: ScanDirection?

    public init(headline: String, detail: String, direction: ScanDirection? = nil) {
        self.headline = headline
        self.detail = detail
        self.direction = direction
    }
}

/// Every user-facing string of the Scan screen (V3OScan and its states without a mockup), in the design system's
/// voice: first person, calm, specific, and saying what happens before asking for anything.
public enum ScanText {
    // MARK: Scanning

    /// The mockup's line under the instruction.
    public static let walkSlowly = "Walk slowly. Walls, doors and big furniture are picked up on their own."

    /// RoomPlan's instruction as a sentence. `.normal` follows the walls: a first one to find, more to catch, or
    /// all of them.
    public static func guidance(for instruction: ScanInstruction, coverage: WallCoverage) -> ScanGuidance {
        switch instruction {
        case .moveCloser:
            ScanGuidance(
                headline: "Move a little closer to the wall.",
                detail: "From nearer I can see where it starts and ends.", direction: .forward)
        case .moveAway:
            ScanGuidance(
                headline: "Step back from the wall.",
                detail: "Too close and I can't see the whole of it.", direction: .back)
        case .slowDown:
            ScanGuidance(headline: "Slow down a little.", detail: "Moving slowly keeps the walls sharp.")
        case .turnOnLight:
            ScanGuidance(headline: "Turn on a light.", detail: "It's too dark for me to follow the room.")
        case .lowTexture:
            ScanGuidance(
                headline: "Point at a corner or some furniture.",
                detail: "Plain, bare surfaces are hard for me to follow.")
        case .normal:
            if coverage.captured == 0 {
                ScanGuidance(headline: "Point the phone at a wall.", detail: walkSlowly)
            } else if coverage.isClosed {
                ScanGuidance(
                    headline: "That's every wall.",
                    detail: "Finish when you're ready, or keep going to pick up more furniture.")
            } else {
                ScanGuidance(headline: "Keep turning to catch the next wall.", detail: walkSlowly)
            }
        }
    }

    /// The count over the camera: "3 of 4 walls", "No walls yet".
    public static func wallCount(_ coverage: WallCoverage) -> String {
        coverage.captured == 0 ? "No walls yet" : RoomText.wallsCaptured(coverage)
    }

    /// The inset's VoiceOver summary.
    public static func insetSummary(_ coverage: WallCoverage) -> String {
        if coverage.captured == 0 { return "Floor plan: no walls captured yet." }
        if coverage.isClosed { return "Floor plan: all \(coverage.captured) walls captured." }
        return "Floor plan: \(coverage.captured) of \(coverage.expected) walls captured."
    }

    public static let insetCaption = "Floor plan"

    /// A label over the camera: the wall's length, or what the thing is. Nil for a thing the model does not name.
    public static func label(for kind: ScanMarker.Kind) -> String? {
        switch kind {
        case .wall(let length): RoomText.metres(length)
        case .opening(.door): "Door"
        case .opening(.window): "Window"
        case .furniture(let category):
            switch category {
            case .sofa: "Sofa"
            case .chair: "Chair"
            case .table: "Table"
            case .storage: "Storage"
            case .television: "TV"
            case .bed: "Bed"
            case .other: nil
            }
        }
    }

    // MARK: Buttons

    public static let finish = "Finish scan"
    public static let manualEntryLink = "No LiDAR? Enter the room by hand"
    public static let manualEntry = "Enter the room by hand"
    public static let close = "Cancel scan"
    public static let allowCamera = "Allow camera"
    public static let openSettings = "Open Settings"
    public static let tryAgain = "Scan again"
    public static let notNow = "Not now"

    // MARK: States without a mockup

    public static let screenTitle = "Scan the room"

    public static let permissionHeadline = "I'll use the camera to map your room."
    public static let permissionBody =
        "Walk around with the phone and I'll find the walls, doors and big furniture. The scan stays on this iPhone."

    public static let deniedHeadline = "The camera is off for Resoniq."
    public static let deniedBody =
        "To scan the room, turn on Camera for Resoniq in Settings. Or enter the room's size by hand."

    public static let unsupportedHeadline = "This iPhone can't scan rooms."
    public static let unsupportedBody =
        "Scanning needs a LiDAR sensor. Enter your room's size by hand and I'll work from that."

    public static let processingCaption = "Almost there"
    public static let processingHeadline = "Putting the room together."
    public static let processingBody = "I'm straightening the walls and placing the furniture. This takes a moment."
    public static let processingStatus = "Building the plan"

    public static let preparing = "Starting the camera"

    public static let failedCaption = "Scan stopped"

    public static func failureHeadline(_ failure: ScanFailure) -> String {
        switch failure {
        case .worldTrackingFailure: "I lost track of the room."
        case .sceneTooLarge: "This space is too big for one scan."
        case .deviceTooHot: "Your iPhone is too warm to scan."
        case .deviceNotSupported: unsupportedHeadline
        case .noWalls: "I didn't find any walls."
        case .invalidConfiguration, .internalError, .unknown: "The scan stopped unexpectedly."
        }
    }

    public static func failureBody(_ failure: ScanFailure) -> String {
        switch failure {
        case .worldTrackingFailure: "Move more slowly and keep the room well lit, then scan again."
        case .sceneTooLarge: "Scan one room at a time. In an open-plan space, scan the part where you listen."
        case .deviceTooHot: "Let it cool down for a few minutes, then scan again."
        case .deviceNotSupported: unsupportedBody
        case .noWalls: "Walk along the edge of the room with the camera on the walls, then finish the scan."
        case .invalidConfiguration, .internalError, .unknown:
            "Try again. If it keeps happening, you can enter the room by hand."
        }
    }
}
