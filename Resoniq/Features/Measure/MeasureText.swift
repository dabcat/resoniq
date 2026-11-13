import Foundation
import ResoniqAudio
import ResoniqDiagnostics
import ResoniqDSP

/// The labels of the measuring flow (pill titles, the diagram's places, the Paused caps label), and thin forwarding
/// to the Kit for every sentence that says what is happening in the measurement: `ResoniqAudio.SeatSessionText`
/// (the session's moments, notes and failures), `ResoniqDiagnostics.SeatText` (progress, the building average, the
/// analysis) and `InputLevel` (the level reading).
enum MeasureText {
    // MARK: Spots

    /// "Seat", "Left", "Right": the names on the pills.
    static func pillTitle(_ spot: SeatSpot) -> String {
        switch spot {
        case .seat: "Seat"
        case .left: "Left"
        case .right: "Right"
        }
    }

    /// Where a spot sits in the top view, from the left: left, seat (the middle), right. The Kit measures the seat
    /// first, then left, then right.
    static func position(of spot: SeatSpot) -> Int {
        switch spot {
        case .left: 0
        case .seat: 1
        case .right: 2
        }
    }

    /// "middle", "left", "right".
    private static func place(_ spot: SeatSpot) -> String {
        switch spot {
        case .seat: "middle"
        case .left: "left"
        case .right: "right"
        }
    }

    /// "seat", "left", "right".
    static func spotName(_ spot: SeatSpot) -> String { SeatSessionText.spotName(spot) }

    // MARK: The sentence for this moment (the Kit's)

    /// What the headline of Three spots says: one sentence per state, and per phase of the wait for a spot.
    static func instruction(for state: SeatMeasurementSession.State, wait: SeatWaitPhase?, channels: [SpeakerChannel]) -> String {
        SeatSessionText.instruction(for: state, wait: wait, channels: channels)
    }

    /// "left speaker", "right speaker", "speaker".
    static func speakerWord(_ channel: SpeakerChannel, of channels: [SpeakerChannel]) -> String {
        SeatSessionText.speakerWord(channel, of: channels)
    }

    /// The caps label on the Paused screen: "Left spot · right speaker".
    static func pausedTitle(spot: SeatSpot, channel: SpeakerChannel, of channels: [SpeakerChannel]) -> String {
        let name = spotName(spot).prefix(1).uppercased() + spotName(spot).dropFirst()
        return channels.count > 1 ? "\(name) spot · \(speakerWord(channel, of: channels))" : "\(name) spot"
    }

    /// The line under the headline when the phone is waited for, and while the tones play.
    static let waitingLine = SeatSessionText.waitingLine
    static let playingLine = SeatSessionText.playingLine

    // MARK: Progress

    /// "1 of 3 in": the same words as `SeatReport.progress`, from the session's own counts.
    static func progress(captured: Int, of total: Int) -> String { SeatText.progress(valid: captured, required: total) }

    /// One sentence for the diagram of Three spots, from the spots' states.
    static func diagramLabel(captured: [SeatSpot], active: SeatSpot?) -> String {
        var parts = ["Three spots in a row."]
        if !captured.isEmpty {
            let names = captured.map(place).joined(separator: " and ")
            parts.append("The \(names) \(captured.count == 1 ? "one is" : "ones are") done.")
        }
        if let active {
            parts.append(captured.isEmpty
                ? "The phone is at the middle one, the first to measure."
                : "The phone slides to the \(place(active)) one.")
        } else {
            parts.append("All three are done.")
        }
        return parts.joined(separator: " ")
    }

    /// One sentence for the curve panel: how many spots are in and what is drawn.
    static func curveLabel(captured: Int, drawn: Int, of total: Int) -> String {
        SeatText.buildingLabel(captured: captured, drawn: drawn, of: total)
    }

    /// The sentence for the Sit and aim diagram.
    static let guideDiagramLabel =
        "Seen from above: both speakers play toward a sofa. Three measuring spots sit in a row at head height, the middle one first"

    // MARK: Levels

    /// "Good", "Too loud", "Too quiet": the Kit's `InputLevel`, in Three spots' short words.
    static func level(isClipping: Bool, frequency: Double?, peakDecibels: Float) -> String {
        InputLevel(isClipping: isClipping, frequency: frequency, peakDecibels: peakDecibels).shortLabel
    }

    // MARK: A spot repeated (the Kit's)

    static func noticeTitle(_ note: RunNote) -> String { SeatSessionText.noticeTitle(note) }

    static func noticeText(_ note: RunNote) -> String { SeatSessionText.noticeText(note) }

    // MARK: When it ends without a result (the Kit's)

    static func failureHeadline(_ failure: SeatFlow.Failure) -> String {
        SeatSessionText.failureHeadline(failure.measurementFailure)
    }

    static func failureBody(_ failure: SeatFlow.Failure) -> String {
        let body = SeatSessionText.failureBody(failure.measurementFailure)
        // Why the app plays the sound itself, for the person who hit this and did not know why it matters.
        if case .speakersNotConnected = failure { return body + " " + ExternalSessionText.whyTheAppPlays }
        return body
    }

    /// What the evidence tag on an ended measurement rests on, for the failures that are "Inconclusive".
    static func inconclusiveBasis(_ failure: SeatFlow.Failure) -> String? {
        SeatSessionText.inconclusiveBasis(failure.measurementFailure)
    }

    // MARK: Analysing, paused (the Kit's)

    static let analysingHeadline = SeatText.analysingHeadline
    static let analysingBody = SeatText.analysingBody
    static let analysingKicker = SeatText.analysingKicker
    static let analysingWaiting = SeatText.analysingWaiting

    static let pausedHeadline = SeatSessionText.pausedHeadline
    static func pausedSentence(resumeFrequency: String?) -> String {
        SeatSessionText.pausedSentence(resumeFrequency: resumeFrequency)
    }
}

extension SeatFlow.Failure {
    /// The session's failure this one shows, for the Kit's words.
    var measurementFailure: MeasurementFailure {
        switch self {
        case .permissionDenied: .permissionDenied
        case .interrupted: .interrupted
        case .routeChanged: .routeChanged
        case .unusable(let problem): .recordingUnusable(problem)
        case .audioUnavailable: .audioUnavailable("")
        case .tooNoisy: .tooNoisy
        case .speakersNotConnected(let route): .speakersNotConnected(route)
        case .phoneNeverStill: .phoneNeverStill
        }
    }
}
