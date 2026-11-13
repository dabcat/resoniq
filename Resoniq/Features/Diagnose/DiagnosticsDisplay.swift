import Foundation
import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqStore
import SwiftUI

// The one place that maps Kit types onto component inputs. Every number comes from the Kit; the only numbers
// written here are the scales that turn a measured value into a position on screen, named in `DisplayScale`.

/// How measured values are laid out in a run trace.
nonisolated enum DisplayScale {
    /// Decibels from the middle of a trace's lane to its top or bottom.
    static let traceDecibelsEachWay: Double = 12
    /// Where a trace with no distortion sits in its lane, and how far the distortion reaches up from there.
    static let distortionBaseline: Double = 0.1
    static let distortionReach: Double = 0.8
    /// A distortion trace is full height at this many times the finding's threshold.
    static let distortionFullScaleThresholds: Double = 2
}

// MARK: - Evidence

extension ResoniqEvidenceKind {
    nonisolated init(_ tag: EvidenceTag) {
        switch tag {
        case .measured: self = .measured
        case .inferred: self = .inferred
        case .inconclusive: self = .inconclusive
        case .estimate: self = .estimate
        }
    }
}

extension Finding {
    var evidenceKind: ResoniqEvidenceKind { ResoniqEvidenceKind(tag) }

    /// What the tag rests on, from the Kit's tag line ("Inferred · 3 of 3 runs" gives "3 of 3 runs"); nil when the
    /// tag stands alone.
    var tagBasis: String? {
        let parts = tagLine.components(separatedBy: " · ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil
    }

    /// Where the finding's text sits beside the portrait, from 0 (20 Hz, the bottom) to 1 (20 kHz, the top); nil
    /// for a finding about a recording, which has no frequency.
    var heightFraction: Double? {
        frequencyRange.map { FrequencyRuler.fraction(forFrequency: Double($0.centre)) }
    }

    /// What a finding's row beside the portrait offers.
    enum NoteAction: Equatable {
        /// "Hear it yourself": the Finding screen with a tone to play.
        case hear
        /// "See the runs": the Finding screen with the runs and numbers, nothing to hear.
        case showRuns
        /// The row says what it says (headline, detail) and leads nowhere: there is nothing to show or play.
        case informational
    }

    /// Decided here for each kind, so a new kind cannot slip into the wrong behaviour.
    ///
    /// - A finding about the speaker's sound that has a frequency to play: hear it.
    /// - A quiet band: its runs and numbers are worth showing, but a tone through a driver that makes little sound
    ///   has nothing to teach the ear, so there is no hold-to-hear even though the Kit gives a frequency.
    /// - An even statement, an unusable run, a band that could not be checked and distortion that could not be told
    ///   from the noise are inconclusive or plain statements: informational. The last has numbers, but a screen
    ///   built to check a defect by ear would suggest a defect was found.
    var noteAction: NoteAction {
        switch kind {
        case .responseDip, .responsePeak, .distortion, .topEndDip, .leftRightDifference, .rattle:
            listenFrequency == nil ? .informational : .hear
        case .quietBand:
            context == nil || numbers == nil ? .informational : .showRuns
        case .even, .invalidRecording, .notAssessed, .distortionUnclear:
            .informational
        }
    }

    /// Whether the Finding screen has a tone to play for it.
    var hasSomethingToHear: Bool { noteAction == .hear }
}

// MARK: - Portrait

extension ClosedRange where Bound == Double {
    /// A frequency range as the fractions of the portrait's height it covers.
    nonisolated init(_ range: FrequencyRange) {
        self = FrequencyRuler.fraction(forFrequency: Double(range.lower))...FrequencyRuler.fraction(forFrequency: Double(range.upper))
    }
}

extension PortraitProfile {
    /// The widths the portrait draws; empty before anything was heard, which draws the dashed outline.
    var portraitWidths: [Double] { heardUpTo == nil ? [] : widths.map(Double.init) }

    /// The bands to redraw as a deviation.
    var portraitDeviations: [ClosedRange<Double>] { deviations.map { ClosedRange($0) } }

    var portraitStatus: SpeakerPortrait.Status { heardUpTo == nil ? .notHeard : .finished }
}

// MARK: - Run traces

/// What the Finding screen's run comparison draws, ready for `RunOverlay`.
struct RunComparison {
    /// One trace per usable run, each 0...1 across the context. A nil is a stretch the Kit did not measure: a gap,
    /// never a value.
    var traces: [[Double?]]
    /// The finding's frequencies as fractions of the width.
    var marked: ClosedRange<Double>
    /// Whether any trace has a gap, so the screen can say what a gap is.
    var hasGaps: Bool { traces.contains { $0.contains { $0 == nil } } }
    /// The axis under the traces: "80 Hz", "100–160 Hz", "300 Hz".
    var lowerLabel: String
    var rangeLabel: String
    var upperLabel: String
    var accessibilityLabel: String

    /// The runs around `finding`, read from the report's measurements; nil when the finding has no frequency
    /// to compare.
    init?(finding: Finding, report: SpeakerReport) {
        guard let context = finding.context, let range = finding.frequencyRange else { return nil }
        let grid = ResponseGrid.frequencies
        let first = ResponseGrid.nearestIndex(to: context.lower)
        let last = ResponseGrid.nearestIndex(to: context.upper)
        guard last > first else { return nil }
        let measurements = report.runs.compactMap(\.measurement)
        guard !measurements.isEmpty else { return nil }

        let low = log(Double(grid[first]))
        let high = log(Double(grid[last]))
        func fraction(of frequency: Float) -> Double {
            min(max((log(Double(frequency)) - low) / (high - low), 0), 1)
        }

        let distortionThreshold = finding.numbers.flatMap { $0.unit == .percent ? Double($0.threshold) : nil }
        traces = measurements.map { measurement in
            (first...last).map { index in
                if let distortionThreshold {
                    // Only a measurement is drawn: where distortion was not read, or was not clear of the noise,
                    // the trace has a gap, not a zero.
                    guard case .measured(let percent) = measurement.distortion(atIndex: index) else { return nil }
                    let scaled = min(Double(percent) / (distortionThreshold * DisplayScale.distortionFullScaleThresholds), 1)
                    return DisplayScale.distortionBaseline + DisplayScale.distortionReach * scaled
                }
                // A response held at the edge of what was measured is not a measurement either.
                guard measurement.isResponseMeasured(atIndex: index) else { return nil }
                return 0.5 + Double(measurement.normalizedResponse[index]) / (2 * DisplayScale.traceDecibelsEachWay)
            }
        }
        marked = fraction(of: range.lower)...fraction(of: range.upper)
        lowerLabel = DiagnosisText.frequency(context.lower)
        rangeLabel = DiagnosisText.range(range)
        upperLabel = DiagnosisText.frequency(context.upper)

        func spoken(_ frequency: Float) -> String {
            FrequencyRuler.spokenFrequency(Double(DiagnosisText.rounded(frequency)))
        }
        let repeatability = finding.repeatability.map { "\($0), " } ?? ""
        let gaps = traces.contains { $0.contains { $0 == nil } } ? " \(Words.gaps)" : ""
        accessibilityLabel =
            "\(measurements.count) test runs one above the other. \(repeatability)between \(spoken(range.lower)) and \(spoken(range.upper)).\(gaps)"
    }
}

extension RunComparison {
    enum Words {
        /// What a break in a trace means.
        static let gaps = "Gaps are where I couldn't measure."
    }
}

// MARK: - Speakers

extension SpeakerPosition {
    /// The channel a test tone for this speaker plays on; a single speaker gets both.
    var toneChannel: SpeakerChannel {
        switch self {
        case .left: .left
        case .right: .right
        case .single: .both
        }
    }

    /// "Left speaker", "Right speaker", "Speaker".
    var speakerPhrase: String {
        switch self {
        case .left: "Left speaker"
        case .right: "Right speaker"
        case .single: "Speaker"
        }
    }

    /// "the left speaker", "the right speaker", "the speaker": inside a sentence.
    var speakerInSentence: String {
        switch self {
        case .left: "the left speaker"
        case .right: "the right speaker"
        case .single: "the speaker"
        }
    }
}

// MARK: - Diagnose home

/// What the Diagnose home shows about one speaker.
struct SpeakerSummary: Equatable {
    var position: SpeakerPosition
    /// "Left", "Right", "Soundbar".
    var name: String
    /// The portrait to draw; `PortraitProfile.notHeard` when there is none.
    var profile: PortraitProfile
    /// The line under the name: "Possible buzz at 100–160 Hz", "Not heard yet".
    var status: String
    /// The status is a suspected defect, so it is drawn in the deviation colour and semibold.
    var isDeviation: Bool
    /// Whether there is a stored result to open.
    var hasResult: Bool
    /// One sentence for VoiceOver that states what the portrait shows.
    var portraitLabel: String

    static func notHeard(_ position: SpeakerPosition, name: String) -> SpeakerSummary {
        SpeakerSummary(
            position: position,
            name: name,
            profile: .notHeard,
            status: HomeText.notHeard,
            isDeviation: false,
            hasResult: false,
            portraitLabel: "\(name) portrait, not heard yet."
        )
    }

    /// The summary of a stored report, or "not heard" when there is none.
    init(position: SpeakerPosition, name: String, report: SpeakerReport?) {
        guard let report else {
            self = .notHeard(position, name: name)
            return
        }
        let suspected = report.suspectedDefects
        self.position = position
        self.name = name
        self.profile = report.profile
        self.hasResult = true
        self.isDeviation = !suspected.isEmpty
        if !report.isConclusive {
            self.status = HomeText.inconclusive
        } else if suspected.isEmpty {
            self.status = HomeText.healthy
        } else if suspected.count == 1 {
            self.status = suspected[0].headline
        } else {
            self.status = HomeText.severalFindings
        }
        self.portraitLabel = "\(name) portrait. \(report.verdict)"
    }

    init(
        position: SpeakerPosition, name: String, profile: PortraitProfile, status: String,
        isDeviation: Bool, hasResult: Bool, portraitLabel: String
    ) {
        self.position = position
        self.name = name
        self.profile = profile
        self.status = status
        self.isDeviation = isDeviation
        self.hasResult = hasResult
        self.portraitLabel = portraitLabel
    }
}

/// Words on the Diagnose home that are not a finding of the Kit's.
enum HomeText {
    static let notHeard = "Not heard yet"
    static let healthy = "Sounds healthy"
    static let inconclusive = "Couldn't tell yet"
    static let severalFindings = "Several things to look at"
    static let quickCheck = "Checking speakers somewhere else? Quick check"
}

/// The home screen's content for one sound system, decided once, here.
struct HomePlan: Equatable {
    var speakers: [SpeakerSummary]
    var primaryTitle: String
    /// The speaker the primary button tests.
    var next: SpeakerPosition

    /// A stored test of one speaker: when it was made and what it found (nil when it cannot be read).
    struct Latest {
        var date: Date
        var report: SpeakerReport?
    }

    /// The speakers a kind of system shows: one portrait for a soundbar or a single speaker, two otherwise.
    /// A subwoofer or surround speakers have no portrait of their own yet.
    static func positions(for kind: SoundSystemKind) -> [SpeakerPosition] {
        switch kind {
        case .soundbar, .singleSpeaker: [.single]
        case .stereoPair, .stereoWithSubwoofer, .surround: [.left, .right]
        }
    }

    /// The most useful next test is the speaker that has not been heard, the left one first; when both have been
    /// heard, the one whose test is older. A rule this simple can be said in one line and never surprises.
    static func make(kind: SoundSystemKind, latest: [SpeakerPosition: Latest]) -> HomePlan {
        let positions = positions(for: kind)
        let name: (SpeakerPosition) -> String = { position in
            position == .single ? (kind == .soundbar ? "Soundbar" : "Speaker") : position.displayName
        }
        let speakers = positions.map { SpeakerSummary(position: $0, name: name($0), report: latest[$0]?.report) }
        let next = positions.first { latest[$0] == nil }
            ?? positions.min { (latest[$0]?.date ?? .distantPast) < (latest[$1]?.date ?? .distantPast) }
            ?? .single
        let heard = latest[next] != nil
        let title: String
        switch next {
        case .single:
            let subject = kind == .soundbar ? "the soundbar" : "your speaker"
            title = heard ? "Listen to \(subject) again" : "Listen to \(subject)"
        case .left, .right:
            title = heard ? "Listen to \(next.speakerInSentence) again" : "Listen to \(next.speakerInSentence)"
        }
        return HomePlan(speakers: speakers, primaryTitle: title, next: next)
    }
}
