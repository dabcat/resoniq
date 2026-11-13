import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

// Expectations come from the simulated room's filter coefficients (`SimulatedRoom.expected…`), never from the code
// under test. Tolerances: a frequency to 2 %, a level to 1 dB (the room curve is smoothed to 1/12 octave in the bass,
// which lowers a mode's summit a little, and the 0.5 s room window resolves about 2 Hz).

let levelTolerance = 1.0
/// A deep, narrow dip reads shallower than its filter: the 0.5 s room window resolves about 2 Hz, and power smoothing
/// fills a notch more than it lowers a peak (the mockup room's 61 Hz dip reads 1.5 dB shallow).
let dipTolerance = 2.0

// MARK: - The mockup's room

@Suite struct MockupSeatTests {
    static let report = SeatDiagnosis.diagnose(spots: SeatBench.mockup, room: SeatBench.matchingHint)

    @Test func `every spot is valid`() {
        #expect(SeatBench.mockup.allSatisfy { $0.isValid }, "\(SeatBench.mockup.map(\.problems))")
        #expect(Self.report.isConclusive)
        #expect(Self.report.validSpotCount == 3)
    }

    @Test func `the verdict is the mockup's`() {
        #expect(Self.report.verdict == "From your seat, the bass is uneven. The rest is balanced.")
    }

    @Test func `the extremes are the boom at 41 Hz and the missing note at 61 Hz`() throws {
        let extremes = Self.report.extremes
        #expect(extremes.count == 2, "\(extremes.map(\.label))")
        let peak = try #require(extremes.first { $0.kind == .peak })
        let dip = try #require(extremes.first { $0.kind == .dip })
        let room = SeatBench.mockupRoom
        let expectedPeak = room.expectedExtreme(near: 41, peak: true)
        let expectedDip = room.expectedExtreme(near: 61, peak: false)
        print("peak \(peak.frequency) Hz \(peak.deviation) dB, expected \(expectedPeak); dip \(dip.frequency) Hz \(dip.deviation) dB, expected \(expectedDip)")
        #expect(abs(Double(peak.frequency) / expectedPeak.frequency - 1) < 0.02)
        #expect(abs(Double(dip.frequency) / expectedDip.frequency - 1) < 0.02)
        #expect(abs(Double(peak.deviation) - expectedPeak.decibels) < levelTolerance)
        #expect(abs(Double(dip.deviation) - expectedDip.decibels) < dipTolerance)
        #expect(peak.label == "41 Hz +9 dB")
        #expect(dip.label == "61 Hz −11 dB")
        #expect(peak.valueLabel == "+9.2 dB")
        #expect(dip.valueLabel == "−11.4 dB")
        // Interpolated, not snapped to the grid.
        #expect(!ResponseGrid.frequencies.contains(peak.frequency))
        #expect(Self.report.placementTargets.count == 2)
    }

    @Test func `three findings with the mockup's words, tags and bases`() throws {
        let shown = Self.report.displayedFindings
        #expect(shown.map(\.headline) == [
            "One bass note booms, one nearly vanishes",
            "Voices and treble are even, left matches right",
            "It's the room, not the speakers",
        ])
        #expect(shown.map(\.tag) == [.measured, .measured, .inferred])
        #expect(shown.map(\.tagLine) == [
            "Measured",
            "Measured · within 1.2 dB",
            "Inferred from room size. Moving speakers should help.",
        ])
        #expect(shown[2].basis == .roomSize)
    }

    @Test func `left matches right within the simulated tilt`() throws {
        let figure = try #require(Self.report.leftRightDifference)
        let expected = SeatBench.mockupRoom.expectedLeftRight()
        print("left/right \(figure) dB, expected \(expected)")
        #expect(abs(Double(figure) - expected) < 0.4)
    }

    @Test func `the numbers table`() throws {
        let rows = Self.report.numbers
        #expect(rows.map(\.label) == ["41 Hz", "61 Hz", "L / R", "1 kHz", "< 80 Hz"])
        #expect(rows.map(\.value).prefix(3) == ["+9.2 dB", "−11.4 dB", "±1.2 dB"])
        #expect(rows.map(\.word) == ["peak", "dip", "match", "distortion", "decay"])
        #expect(rows.map(\.tag) == [.measured, .measured, .measured, .measured, .estimate])
        // Distortion at 1 kHz from the speaker's nonlinearity alone: second harmonic a·A/2, third b·A²/4.
        let room = SeatBench.mockupRoom
        let amplitude = Double(SeatBench.sweep.amplitude) * room.gain
        let expectedTHD = 100 * hypot(room.quadratic * amplitude / 2, room.cubic * amplitude * amplitude / 4)
        let measured = try #require(Self.report.distortionPercent)
        print("THD at 1 kHz \(measured) %, expected \(expectedTHD) %")
        #expect(abs(Double(measured) / expectedTHD - 1) < 0.4)
        #expect(rows[3].value == "\(String(format: "%.1f", measured)) %")
        // Decay: the boom's poles ring longest; the reading is an estimate of the order of their ring time.
        let decay = try #require(Self.report.bassDecay)
        let ring = (0..<3).map { spot in
            Biquad.peaking(frequency: 41, q: 8, gain: room.modes[0].gains[spot], sampleRate: SimulatedRoom.sampleRate)
                .ringTime(sampleRate: SimulatedRoom.sampleRate)
        }.sorted()[1]
        print("bass decay \(decay.seconds) s over \(decay.lower)–\(decay.upper) Hz, the boom's poles ring \(ring) s")
        #expect(abs(decay.seconds / ring - 1) < 0.35)
        #expect(rows[4].value.hasPrefix("≈ "))
        #expect(rows[4].value.hasSuffix(" s"))
    }

    @Test func `the curves the screens draw`() throws {
        let report = Self.report
        let curve = try #require(report.curve)
        #expect(curve.count == ResponseGrid.count)
        #expect(report.leftCurve?.count == ResponseGrid.count)
        #expect(report.rightCurve?.count == ResponseGrid.count)
        #expect(report.spotCurves.compactMap { $0 }.count == 3)
        #expect(report.spread?.count == ResponseGrid.count)
        // 0 dB is the middle: the median from 200 Hz to 4 kHz.
        let middle = curve.indices.filter { ResponseGrid.frequencies[$0] >= 200 && ResponseGrid.frequencies[$0] <= 4000 }.map { curve[$0] }
        #expect(abs(median(middle)!) < 0.01)
        // Even above 100 Hz.
        #expect(curve.indices.filter { ResponseGrid.frequencies[$0] >= 100 && ResponseGrid.frequencies[$0] <= 10000 }.allSatisfy { abs(curve[$0]) < 3 })
        #expect(report.footnote.contains("isn't calibrated"))
        #expect(report.progress == "3 of 3 in")
    }

    @Test func `a report survives JSON`() throws {
        let data = try JSONEncoder().encode(Self.report)
        let decoded = try JSONDecoder().decode(SeatReport.self, from: data)
        #expect(decoded == Self.report)
        #expect(decoded.schemaVersion == SeatReport.currentSchemaVersion)
        let spots = try JSONDecoder().decode([SpotAnalysis].self, from: try JSONEncoder().encode(SeatBench.mockup))
        #expect(spots == SeatBench.mockup)
    }

    @Test func `without a room hint the cause rests on the spots`() throws {
        let report = SeatDiagnosis.diagnose(spots: SeatBench.mockup, room: nil)
        print("extremes without a hint: \(report.extremes.map { "\($0.label) spread \($0.spread) width \($0.range.octaves)" })")
        let cause = try #require(report.findings.first { $0.kind == .roomCause })
        #expect(cause.tag == .inferred)
        #expect(cause.basis == .spotToSpot)
        #expect(cause.tagLine == "Inferred from how it changes between spots. Moving speakers should help.")
    }

    @Test func `a room hint whose modes miss the extremes is not the basis`() {
        let report = SeatDiagnosis.diagnose(spots: SeatBench.mockup, room: SeatBench.mismatchedHint)
        #expect(!report.findings.contains { $0.tagLine.contains("room size") })
        #expect(!report.findings.contains { $0.basis == .roomSize })
    }
}

// MARK: - False alarms

@Suite struct EvenSeatTests {
    static let seeds: [UInt64] = [1, 2, 3]

    @Test(arguments: seeds)
    func `an even room gives no deviation findings`(seed: UInt64) {
        let spots = SeatBench.even(seed: seed)
        #expect(spots.allSatisfy { $0.isValid })
        let report = SeatDiagnosis.diagnose(spots: spots, room: SeatBench.matchingHint)
        let curve = report.curve ?? []
        let worst = curve.indices.filter { ResponseGrid.frequencies[$0] >= 30 && ResponseGrid.frequencies[$0] <= 10000 }.map { abs(curve[$0]) }.max() ?? 0
        print("even room, seed \(seed): worst deviation \(worst) dB, left/right \(report.leftRightDifference ?? -1) dB")
        #expect(report.isConclusive)
        #expect(report.extremes.isEmpty, "\(report.extremes.map(\.label))")
        #expect(!report.findings.contains { $0.isDeviation }, "\(report.findings.map(\.headline))")
        #expect(!report.findings.contains { $0.kind == .roomCause })
        #expect(report.verdict == "From your seat, it all sounds even.")
        #expect(report.findings.first?.headline == "Voices and treble are even, left matches right")
    }
}

// MARK: - The cause, and left against right

@Suite struct SeatCauseTests {
    /// A bass peak at 90 Hz that is the same at every spot: the speaker, or something the spots do not tell apart.
    static let fixedPeakRoom = SimulatedRoom(modes: [RoomMode(frequency: 90, q: 4, gains: [8, 8, 8])])
    static var fixedPeak: [SpotAnalysis] { SeatBench.spots(fixedPeakRoom, seed: 90, key: "fixed-peak") }

    @Test func `unevenness the same at every spot and near no mode is not blamed on the room`() throws {
        for hint in [nil, SeatBench.mismatchedHint] {
            let report = SeatDiagnosis.diagnose(spots: Self.fixedPeak, room: hint)
            let peak = try #require(report.extremes.first)
            print("fixed peak \(peak.label), spread \(peak.spread) dB")
            #expect(report.extremes.count == 1)
            #expect(report.findings.first?.headline == "One bass note booms")
            #expect(!report.findings.contains { $0.kind == .roomCause }, "\(report.findings.map(\.headline))")
            #expect(report.verdict == "From your seat, the bass is uneven. The rest is balanced.")
        }
    }

    /// The left speaker 2.5 dB duller and the right 2.5 dB brighter above 3 kHz: 5 dB apart in the treble, the seat's
    /// average still even.
    static let unmatchedRoom = SimulatedRoom(leftTilt: -2.5, rightTilt: 2.5)

    @Test func `left and right 5 dB apart in the treble is reported, and they are not said to match`() throws {
        let spots = SeatBench.spots(Self.unmatchedRoom, seed: 5, key: "unmatched")
        let report = SeatDiagnosis.diagnose(spots: spots, room: nil)
        let figure = try #require(report.leftRightDifference)
        let expected = Self.unmatchedRoom.expectedLeftRight()
        print("left/right \(figure) dB, expected \(expected)")
        #expect(abs(Double(figure) - expected) < 0.5)
        let finding = try #require(report.findings.first { $0.kind == .leftRight })
        #expect(finding.isDeviation)
        #expect(finding.headline == "Left and right differ in the treble")
        #expect(finding.tag == .measured)
        #expect(!report.findings.contains { $0.headline.contains("matches") })
        #expect(report.verdict == "From your seat, left and right don't sound the same.")
        let row = try #require(report.numbers.first { $0.label == "L / R" })
        #expect(row.word == "differ")
    }

    @Test func `a single speaker has no left and right`() {
        var room = SeatBench.evenRoom
        room.stereo = false
        let report = SeatDiagnosis.diagnose(spots: SeatBench.spots(room, seed: 6, key: "mono"), room: nil)
        #expect(report.isConclusive)
        #expect(report.leftRightDifference == nil)
        #expect(report.rightCurve == nil)
        #expect(report.findings.map(\.headline) == ["Voices and treble are even"])
        #expect(!report.numbers.contains { $0.label == "L / R" })
    }
}

// MARK: - Spots that cannot be used

@Suite struct SeatInvalidTests {
    @Test func `two valid spots are inconclusive`() {
        let report = SeatDiagnosis.diagnose(spots: Array(SeatBench.even(seed: 1).prefix(2)), room: nil)
        #expect(!report.isConclusive)
        #expect(report.verdict == "I need three clean spots to say how your seat sounds.")
        #expect(report.extremes.isEmpty)
        #expect(report.numbers.isEmpty)
        #expect(report.progress == "2 of 3 in")
        // The running average is still drawn.
        #expect(report.curve != nil)
    }

    @Test func `a clipped recording makes its spot invalid, with the reason`() throws {
        var loud = SeatBench.evenRoom
        loud.gain = 2
        loud.clipLevel = 0.3
        let floor = loud.noiseFloor()
        let sweep = SeatBench.shortSweep
        let clipped = loud.record(sweep, spot: 1, channel: .left, seed: 77)
        let fine = SeatBench.evenRoom.record(sweep, spot: 1, channel: .right, seed: 78)
        let spot = SpotAnalyzer.analyze(left: clipped, right: fine, sweep: sweep, noiseFloor: floor)
        #expect(!spot.isValid)
        #expect(spot.problems == [.clipped])
        #expect(spot.left.measurement == nil)
        #expect(spot.right?.isValid == true)

        let even = SeatBench.even(seed: 1)
        let report = SeatDiagnosis.diagnose(spots: [even[0], spot, even[2]], room: nil)
        #expect(!report.isConclusive)
        let finding = try #require(report.findings.first { $0.kind == .invalidSpot })
        #expect(finding.headline == "The left spot needs measuring again")
        #expect(finding.detail == "The microphone clipped. Turning the volume down a little helps.")
        #expect(finding.tag == .inconclusive)
    }
}

// MARK: - Decay

@Suite struct SeatDecayTests {
    /// Under the recording check's 20 dB gate, the simulated room always leaves the decay enough dynamic range, even
    /// with all its noise in the bass. So the gate is relaxed to 12 dB here, and a rumble 14 dB under the recording
    /// (low-passed at 40 Hz) is let through: the decay estimate must refuse it on its own.
    @Test func `no decay figure when bass noise leaves too little dynamic range`() {
        var rumble = SeatBench.mockupRoom
        rumble.noiseRMS = 0.03
        rumble.noiseLowPass = 40
        var relaxed = QualityThresholds.standard
        relaxed.minimumSignalToNoiseDecibels = 12
        let spots = SeatBench.spots(rumble, seed: 8, key: "rumble", quality: relaxed)
        let report = SeatDiagnosis.diagnose(spots: spots, room: nil)
        print("rumble: checks \(spots.map(\.problems)), decay \(String(describing: report.bassDecay))")
        #expect(spots.allSatisfy { $0.isValid })
        #expect(report.bassDecay == nil)
        #expect(!report.numbers.contains { $0.word == "decay" })
    }
}

// MARK: - Only what was assessed

@Suite struct SeatAssessedTests {
    @Test func `bass drowned by the room's noise is not called even`() throws {
        // The 31.5, 63 and 125 Hz octave bands 5 dB over the noise: the bass from 30 to about 180 Hz is unassessed.
        let spots = handSpots({ _ in 0 }, signalToNoise: { $0 < 200 ? 5 : 40 })
        let report = SeatDiagnosis.diagnose(spots: spots, room: nil)
        print("drowned bass: \(report.verdict) | \(report.findings.map { "\($0.headline) [\($0.tagLine)]" })")
        #expect(report.isConclusive)
        #expect(report.verdict == "From your seat, what I could hear sounds even. The room was too noisy to check the bass.")
        let bass = try #require(report.findings.first { $0.kind == .bass })
        #expect(bass.tag == .inconclusive)
        #expect(bass.headline == "I couldn't check the bass over the room's noise")
        #expect(!bass.isDeviation)
    }

    @Test func `nothing assessed at the seat is not conclusive`() {
        let report = SeatDiagnosis.diagnose(spots: handSpots({ _ in 0 }, signalToNoise: { _ in 5 }), room: nil)
        print("nothing assessed: \(report.verdict) conclusive \(report.isConclusive)")
        #expect(!report.isConclusive)
        #expect(report.verdict == "The room was too loud against the speakers for me to judge your seat.")
        #expect(report.extremes.isEmpty && report.numbers.isEmpty)
    }
}
