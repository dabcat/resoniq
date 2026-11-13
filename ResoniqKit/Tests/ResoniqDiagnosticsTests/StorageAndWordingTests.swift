import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

// MARK: - Every report the fixtures produce

/// Every speaker report the shared fixtures make.
var allSpeakerReports: [SpeakerReport] {
    let healthy = HealthySpeakerTests.allCases.map { SpeakerDiagnosis.diagnose(runs: Bench.healthyRuns[$0]!, counterpart: nil) }
    let handmade: [[RunAnalysis]] = [
        (0..<3).map { _ in Handmade.midBuzz(measurable: true) },
        (0..<3).map { _ in Handmade.midBuzz(measurable: false) },
        (0..<3).map { _ in handRun(signalToNoise: { _ in 5 }) },
        (0..<3).map { _ in handRun(signalToNoise: { $0 < 200 ? 5 : 40 }) },
        (0..<3).map { _ in handRun(response: { bell($0, centre: 1000, gain: -5.5, width: 0.4) }) },
    ]
    return healthy + [
        DistortionTests.threeOfThree,
        SpeakerDiagnosis.diagnose(runs: [Bench.buzzingRuns[0], Bench.clippedRun, Bench.noisyRun], counterpart: nil),
        SpeakerDiagnosis.diagnose(runs: LeftRightTests.left, counterpart: LeftRightTests.right),
        SpeakerDiagnosis.diagnose(runs: LeftRightTests.right, counterpart: LeftRightTests.left),
        SpeakerDiagnosis.diagnose(runs: UnheardBandTests.noWoofer, counterpart: nil),
        SpeakerDiagnosis.diagnose(runs: DeepBassDistortionTests.runs, counterpart: nil),
        SweepTiedFindingTests.twoOfThree,
    ] + handmade.map { SpeakerDiagnosis.diagnose(runs: $0, counterpart: nil) }
}

/// Every seat report the shared fixtures make.
var allSeatReports: [SeatReport] {
    [
        MockupSeatTests.report,
        SeatDiagnosis.diagnose(spots: SeatBench.mockup, room: nil),
        SeatDiagnosis.diagnose(spots: SeatBench.mockup, room: SeatBench.mismatchedHint),
        SeatDiagnosis.diagnose(spots: SeatBench.improved, room: SeatBench.matchingHint),
        SeatDiagnosis.diagnose(spots: SeatCauseTests.fixedPeak, room: nil),
        SeatDiagnosis.diagnose(spots: Array(SeatBench.even(seed: 1).prefix(2)), room: nil),
        SeatDiagnosis.diagnose(spots: handSpots({ _ in 0 }, signalToNoise: { $0 < 200 ? 5 : 40 }), room: nil),
        SeatDiagnosis.diagnose(spots: handSpots({ _ in 0 }, signalToNoise: { _ in 5 }), room: nil),
        SeatDiagnosis.diagnose(spots: handSpots { bell($0, centre: 2500, gain: 6, width: 0.5) + bell($0, centre: 61, gain: -11) }, room: nil),
    ] + EvenSeatTests.seeds.map { SeatDiagnosis.diagnose(spots: SeatBench.even(seed: $0), room: nil) }
}

let forbiddenWords = ["is broken", "is faulty", "is damaged", "is defective", "confirmed", "definitely", "score", "%/100", "out of 10", "/10"]

func checkWording(_ text: String) {
    for word in forbiddenWords { #expect(!text.lowercased().contains(word), "\(text)") }
}

@Suite struct AllReportsWordingTests {
    @Test func `no speaker report states a defect as confirmed, and nothing is a score`() {
        for report in allSpeakerReports {
            for text in [report.verdict] + report.findings.flatMap({ [$0.headline, $0.detail, $0.sentence, $0.confidenceStatement] }) {
                checkWording(text)
            }
            for finding in report.findings where finding.kind.isDeviation {
                #expect(finding.confidence != .high)
                if finding.kind == .quietBand {
                    // The level difference is measured; its cause is left open.
                    #expect(finding.tag == .measured)
                    #expect(finding.detail.contains("It could be"))
                } else {
                    #expect(finding.tag == .inferred)
                    #expect(finding.confidenceStatement.hasPrefix("Inferred"))
                }
                // A suspected defect is hedged in its own headline or is a plain observation, never a bare verdict.
                if finding.kind == .distortion { #expect(finding.headline.hasPrefix("Possible")) }
            }
            if !report.isConclusive { #expect(!report.verdict.contains("healthy")) }
        }
    }

    @Test func `no seat report or comparison states a cause as confirmed, and nothing is a score`() {
        let reports = allSeatReports
        for report in reports {
            for text in [report.verdict, report.footnote] + report.findings.flatMap({ [$0.headline, $0.tagLine, $0.detail] }) {
                checkWording(text)
            }
            for finding in report.findings where finding.kind == .roomCause {
                #expect(finding.tag == .inferred)
                #expect(finding.basis != nil)
                #expect(finding.tagLine.hasPrefix("Inferred from"))
            }
            for row in report.numbers where row.kind == .decay {
                #expect(row.tag == .estimate && row.value.hasPrefix("≈"))
            }
            if !report.isConclusive { #expect(report.findings.allSatisfy { $0.kind == .invalidSpot }) }
        }
        let comparison = SeatComparison.compare(before: reports[0], after: reports[3], targeting: reports[0].placementTargets)
        for text in [comparison.verdict, comparison.note] + comparison.rows.flatMap({ [$0.label, $0.status ?? ""] }) {
            checkWording(text)
        }
        #expect(comparison.rows.allSatisfy { $0.tag == .measured })
    }
}

// MARK: - The stored form

/// Reports as JSON with sorted keys, so the stored form can be pinned.
func storedForm<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// Fixtures built by hand with every field set, small enough to pin.
enum StoredFixtures {
    static let speaker: SpeakerReport = {
        let finding = Finding(
            id: "distortion-80-110", kind: .distortion, frequencyRange: FrequencyRange(lower: 80, upper: 110), bands: [.woofer],
            tag: .inferred, basis: Finding.Basis(runsAgreeing: 2, runsCompared: 2), confidence: .low,
            headline: "Possible buzz at 80–110 Hz", detail: "Distortion rose to 20 % around 90 Hz.", sentence: "A possible buzz around 90 Hz.",
            tagLine: "Inferred · 2 of 2 runs", confidenceStatement: "Inferred, low confidence.", repeatability: "Same place every time",
            listenFrequency: 90, context: FrequencyRange(lower: 50, upper: 200),
            numbers: Finding.Numbers(unit: .percent, extreme: 20, extremeFrequency: 90, perRun: [20, nil, 20], threshold: 10),
            recordingProblem: nil
        )
        let measurement = RunMeasurement(
            response: [Float](repeating: -12, count: ResponseGrid.count),
            referenceLevel: -12,
            responseBand: FrequencyRange(lower: 20, upper: 20000),
            thdDecibels: [Float?](repeating: nil, count: ResponseGrid.count),
            thdMeasurable: [Bool](repeating: false, count: ResponseGrid.count),
            thdNoiseFloorDecibels: nil,
            delay: 0.05,
            bandCentres: [1000],
            bandSignalToNoise: [40]
        )
        return SpeakerReport(
            verdict: "Sounds healthy, except the woofer may be buzzing.",
            findings: [finding],
            profile: .notHeard,
            runs: [
                RunRecord(check: .valid(signalToNoise: 30), measurement: measurement),
                RunRecord(check: .clipped(clippedFraction: 0.5), measurement: nil),
                RunRecord(check: .incomplete(capturedBand: FrequencyRange(lower: 40, upper: 20000)), measurement: nil),
            ],
            consensusResponse: nil,
            isConclusive: true
        )
    }()

    static let extreme = SeatExtreme(kind: .dip, frequency: 61, deviation: -11.5, range: FrequencyRange(lower: 56, upper: 66), spread: 4)

    static let seat = SeatReport(
        verdict: "From your seat, the bass is uneven. The rest is balanced.",
        isConclusive: true,
        validSpotCount: 3,
        requiredSpotCount: 3,
        spots: [SpotCheck(left: .valid(signalToNoise: 30), right: .tooNoisy(signalToNoise: 12))],
        curve: [Float](repeating: 0, count: ResponseGrid.count),
        leftCurve: nil,
        rightCurve: nil,
        spotCurves: [nil],
        spread: nil,
        assessed: nil,
        evenBandDecibels: 3,
        extremes: [extreme],
        leftRightDifference: 1.5,
        findings: [
            SeatFinding(kind: .roomCause, tag: .inferred, basis: .roomSize, isDeviation: false, headline: "It's the room, not the speakers",
                        tagLine: "Inferred from room size. Moving speakers should help.", detail: "61 Hz is where this room's size makes the bass resonate.", strength: 0),
        ],
        numbers: [SeatNumberRow(kind: .decay, label: "< 80 Hz", value: "≈ 0.5 s", word: "decay", tag: .estimate)],
        distortionPercent: 0.5,
        bassDecay: SeatDecay(lower: 20, upper: 80, seconds: 0.5)
    )

    static let comparison = ComparisonReport(
        verdict: "The missing bass note is back.",
        rows: [ComparisonRow(label: "Missing note, 61 Hz", before: "−11 dB", after: "−4 dB", status: nil, change: .improved,
                             beforeDecibels: -11.5, afterDecibels: -4, frequency: 61)],
        note: "All measured just now.",
        outcome: .improved,
        nextTarget: extreme,
        isConclusive: true
    )
}

@Suite struct StoredFormTests {
    @Test func `a speaker report's stored form is pinned`() throws {
        try check(StoredFixtures.speaker, against: GoldenJSON.speaker)
    }

    @Test func `a seat report's stored form is pinned`() throws {
        try check(StoredFixtures.seat, against: GoldenJSON.seat)
    }

    @Test func `a comparison's stored form is pinned`() throws {
        try check(StoredFixtures.comparison, against: GoldenJSON.comparison)
    }

    /// The fixture encodes to the pinned form, and the pinned form, as an older app stored it, decodes to the fixture.
    func check<T: Codable & Equatable>(_ fixture: T, against golden: String) throws {
        let encoded = try storedForm(fixture)
        #expect(encoded == golden, "the stored form changed; if on purpose, bump the schema version and migrate. Now: \(encoded)")
        let decoded = try JSONDecoder().decode(T.self, from: Data(golden.utf8))
        #expect(decoded == fixture)
    }
}

@Suite struct PhoneMovedTests {
    @Test func `a report keeps the runs the phone moved in, with the sentence, and a reopened report still says it`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: Bench.healthyRuns(seed: 1), counterpart: nil, phoneMovedRuns: [3, 1, 3])
        #expect(report.phoneMovedRuns == [1, 3])
        #expect(report.phoneMovedNote == "The phone moved while runs 1 and 3 played. I kept them, so read the details with a little care.")
        let reopened = try JSONDecoder().decode(SpeakerReport.self, from: JSONEncoder().encode(report))
        #expect(reopened == report)
        #expect(reopened.phoneMovedNote == report.phoneMovedNote)
        // Nothing else changes.
        let still = SpeakerDiagnosis.diagnose(runs: Bench.healthyRuns(seed: 1), counterpart: nil)
        #expect(report.findings == still.findings && report.verdict == still.verdict)
    }

    @Test func `no run moved: nothing is kept or said`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: Bench.healthyRuns(seed: 1), counterpart: nil, phoneMovedRuns: [])
        #expect(report.phoneMovedRuns == nil && report.phoneMovedNote == nil)
        #expect(!String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("phoneMoved"))
    }

    @Test func `the sentence for one run, and for several`() {
        #expect(DiagnosisText.phoneMovedNote(runs: [2])
            == "The phone moved while run 2 played. I kept that run, so read its details with a little care.")
        #expect(DiagnosisText.phoneMovedNote(runs: [1, 2, 3])
            == "The phone moved while runs 1, 2 and 3 played. I kept them, so read the details with a little care.")
        #expect(DiagnosisText.phoneMovedNote(runs: []) == nil)
    }
}
