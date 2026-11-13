import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

/// Spots built by hand, for comparisons that need no recording: each spot's two recordings read `curve(f) +
/// offsets[spot](f)` dB, measured over the whole grid with plenty of signal over the noise.
func handSpots(_ curve: (Float) -> Float, offsets: [(Float) -> Float] = [{ _ in 0 }, { _ in 0 }, { _ in 0 }]) -> [SpotAnalysis] {
    offsets.map { offset in
        let response = ResponseGrid.frequencies.map { curve($0) + offset($0) }
        let recording = SpotRecording(
            check: .valid(signalToNoise: 40),
            measurement: SpotMeasurement(
                response: response,
                responseBand: FrequencyRange(lower: 20, upper: 20000),
                bandCentres: [31.62, 63.1, 125.9, 251.2, 501.2, 1000, 1995, 3981, 7943, 15850],
                bandSignalToNoise: [Float](repeating: 40, count: 10),
                distortionPercent: nil,
                bassDecay: nil
            )
        )
        return SpotAnalysis(left: recording, right: recording)
    }
}

/// A bell in dB: `gain` at `centre`, falling off over `width` octaves (a Gaussian in log frequency).
func bell(_ frequency: Float, centre: Float, gain: Float, width: Float = 0.12) -> Float {
    let x = log2(frequency / centre) / width
    return gain * exp(-x * x)
}

@Suite struct SeatComparisonTests {
    @Test func `the mockup's move: the missing note is back`() throws {
        let before = MockupSeatTests.report
        let after = SeatDiagnosis.diagnose(spots: SeatBench.improved, room: SeatBench.matchingHint)
        #expect(after.isConclusive)
        let targets = before.placementTargets.sorted { $0.kind == .dip && $1.kind == .peak }
        let comparison = SeatComparison.compare(before: before, after: after, targeting: targets)
        print("rows \(comparison.rows.map { "\($0.label) \($0.before ?? "") → \($0.after ?? "") \($0.status ?? "")" })")
        #expect(comparison.verdict == "The missing bass note is back.")
        #expect(comparison.outcome == .improved)
        #expect(comparison.rows.map(\.label) == ["Missing note, 61 Hz", "Booming note, 41 Hz", "Voices and treble"])
        #expect(comparison.rows[0].before == "−11 dB")
        #expect(comparison.rows[0].after == "−4 dB")
        #expect(comparison.rows[1].before == "+9 dB")
        #expect(comparison.rows[1].after == "+5 dB")
        #expect(comparison.rows[0].change == .improved)
        #expect(comparison.rows[1].change == .improved)
        #expect(comparison.rows[2].status == "Unchanged, still even")
        #expect(comparison.rows[2].change == .unchanged)
        #expect(comparison.rows.allSatisfy { $0.tag == .measured })
        #expect(comparison.note == "All measured just now. The 41 Hz boom is still a little strong; the next suggestion targets it.")
        #expect(comparison.nextTarget?.kind == .peak)

        // Independent check of the after values against the simulated room.
        let room = SeatBench.improvedRoom
        let dip = room.expectedExtreme(near: 61, peak: false)
        let peak = room.expectedExtreme(near: 41, peak: true)
        let dipAfter = try #require(comparison.rows[0].afterDecibels)
        let peakAfter = try #require(comparison.rows[1].afterDecibels)
        print("after: dip \(dipAfter) dB (expected \(dip.decibels)), peak \(peakAfter) dB (expected \(peak.decibels))")
        #expect(abs(Double(dipAfter) - dip.decibels) < levelTolerance)
        #expect(abs(Double(peakAfter) - peak.decibels) < levelTolerance)

        let data = try JSONEncoder().encode(comparison)
        #expect(try JSONDecoder().decode(ComparisonReport.self, from: data) == comparison)
    }

    static let dipBefore = handSpots { bell($0, centre: 61, gain: -11) }

    /// The repeatability at 61 Hz for two reports with no spot-to-spot spread: the floor.
    static let floor = SeatThresholds.standard.repeatabilityDecibels

    @Test func `a change inside the repeatability is unchanged, just outside it is not`() throws {
        let before = SeatDiagnosis.diagnose(spots: Self.dipBefore, room: nil)
        let target = try #require(before.extremes.first)
        let inside = SeatDiagnosis.diagnose(spots: handSpots { bell($0, centre: 61, gain: -11 + Self.floor * 0.7) }, room: nil)
        let outside = SeatDiagnosis.diagnose(spots: handSpots { bell($0, centre: 61, gain: -11 + Self.floor * 1.3) }, room: nil)

        let same = SeatComparison.compare(before: before, after: inside, targeting: [target])
        #expect(same.outcome == .unchanged)
        #expect(same.rows[0].change == .unchanged)
        #expect(same.verdict == "Nothing changed that I can measure.")

        let better = SeatComparison.compare(before: before, after: outside, targeting: [target])
        #expect(better.rows[0].change == .improved)
        #expect(better.outcome == .improved)
        #expect(better.verdict == "It's a little better: the missing bass note is less quiet.")
    }

    @Test func `the spread between spots widens the repeatability`() throws {
        // 10 dB of spread at 61 Hz in both reports: a change of about 2 dB is within a quarter of it.
        let spread: [(Float) -> Float] = [{ bell($0, centre: 61, gain: 5) }, { _ in 0 }, { bell($0, centre: 61, gain: -5) }]
        let before = SeatDiagnosis.diagnose(spots: handSpots({ bell($0, centre: 61, gain: -11) }, offsets: spread), room: nil)
        let after = SeatDiagnosis.diagnose(spots: handSpots({ bell($0, centre: 61, gain: -9) }, offsets: spread), room: nil)
        let target = try #require(before.extremes.first { $0.kind == .dip })
        let comparison = SeatComparison.compare(before: before, after: after, targeting: [target])
        #expect(comparison.rows[0].change == .unchanged)
    }

    @Test func `worse is called worse`() throws {
        let before = SeatDiagnosis.diagnose(spots: Self.dipBefore, room: nil)
        let after = SeatDiagnosis.diagnose(spots: handSpots { bell($0, centre: 61, gain: -16) }, room: nil)
        let comparison = SeatComparison.compare(before: before, after: after, targeting: before.extremes)
        #expect(comparison.outcome == .worse)
        #expect(comparison.rows[0].change == .worse)
        #expect(comparison.verdict == "It sounds worse from your seat than before.")
        #expect(comparison.note.contains("Putting the speaker back"))
    }

    @Test func `an untargeted region that got worse is reported`() throws {
        let before = SeatDiagnosis.diagnose(spots: Self.dipBefore, room: nil)
        let after = SeatDiagnosis.diagnose(
            spots: handSpots { bell($0, centre: 61, gain: -2) + bell($0, centre: 2500, gain: 6, width: 0.5) },
            room: nil
        )
        let comparison = SeatComparison.compare(before: before, after: after, targeting: before.extremes)
        let rest = try #require(comparison.rows.last)
        #expect(rest.label == "Voices and treble")
        #expect(rest.change == .worse)
        #expect(rest.status == "Uneven now")
        #expect(comparison.outcome == .mixed)
        #expect(comparison.verdict == "It's better in one place and worse in another.")
    }

    @Test func `a new bass problem the move made is reported`() throws {
        let before = SeatDiagnosis.diagnose(spots: Self.dipBefore, room: nil)
        let after = SeatDiagnosis.diagnose(spots: handSpots { bell($0, centre: 61, gain: -2) + bell($0, centre: 120, gain: 8) }, room: nil)
        let comparison = SeatComparison.compare(before: before, after: after, targeting: before.extremes)
        let new = try #require(comparison.rows.first { $0.label == "New booming note, 120 Hz" })
        #expect(new.change == .worse)
        #expect(comparison.outcome == .mixed)
    }

    @Test func `an inconclusive measurement improves nothing`() throws {
        let before = SeatDiagnosis.diagnose(spots: Self.dipBefore, room: nil)
        let after = SeatDiagnosis.diagnose(spots: Array(handSpots { _ in 0 }.prefix(2)), room: nil)
        let comparison = SeatComparison.compare(before: before, after: after, targeting: before.extremes)
        #expect(comparison.outcome == .unchanged)
        #expect(comparison.rows.isEmpty)
        #expect(comparison.verdict == "I need a complete measurement from your seat to compare.")
    }
}
