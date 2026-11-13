import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

/// Spots built by hand, for comparisons that need no recording: each spot's two recordings read `curve(f) +
/// offsets[spot](f)` dB, measured over the whole grid with plenty of signal over the noise.
func handSpots(_ curve: (Float) -> Float, offsets: [(Float) -> Float] = [{ _ in 0 }, { _ in 0 }, { _ in 0 }], signalToNoise: (Float) -> Float = { _ in 40 }) -> [SpotAnalysis] {
    offsets.map { offset in
        let response = ResponseGrid.frequencies.map { curve($0) + offset($0) }
        let recording = SpotRecording(
            check: .valid(signalToNoise: 40),
            measurement: SpotMeasurement(
                response: response,
                responseBand: FrequencyRange(lower: 20, upper: 20000),
                bandCentres: [31.62, 63.1, 125.9, 251.2, 501.2, 1000, 1995, 3981, 7943, 15850],
                bandSignalToNoise: [31.62, 63.1, 125.9, 251.2, 501.2, 1000, 1995, 3981, 7943, 15850].map(signalToNoise),
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
    @Test func `the mockup's move: the missing note is less quiet, the boom smaller`() throws {
        let before = MockupSeatTests.report
        let after = SeatDiagnosis.diagnose(spots: SeatBench.improved, room: SeatBench.matchingHint)
        #expect(after.isConclusive)
        let targets = before.placementTargets.sorted { $0.kind == .dip && $1.kind == .peak }
        let comparison = SeatComparison.compare(before: before, after: after, targeting: targets)
        print("rows \(comparison.rows.map { "\($0.label) \($0.before ?? "") → \($0.after ?? "") \($0.status ?? "")" })")
        #expect(comparison.verdict == "It's a little better: the missing bass note is less quiet, now −4 dB.")
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

    @Test func `two measurements from different days are not called a move`() {
        #expect(SeatComparison.occasionsNote.hasPrefix("These are two measurements, not a before and after of a move."))
        // `ComparisonReport.note` is about a move measured straight after: it must not stand under a dated pair.
        #expect(!SeatComparison.occasionsNote.contains("just now"))
    }

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
        #expect(better.verdict.hasPrefix("It's a little better: the missing bass note is less quiet, now "))
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

    // MARK: The review's cases

    /// A seat report from hand-built spots, with no room hint.
    static func seat(_ curve: @escaping (Float) -> Float) -> SeatReport {
        SeatDiagnosis.diagnose(spots: handSpots(curve), room: nil)
    }

    /// The targeted 61 Hz dip, unchanged, under a narrow 2 kHz bump of `bump` dB.
    static func dipAndBump(_ bump: Float, dip: Float = -11) -> SeatReport {
        seat { bell($0, centre: 61, gain: dip) + bell($0, centre: 2000, gain: bump, width: 0.25) }
    }

    @Test func `voices and treble crossing the even band by a hair is unchanged, both ways`() throws {
        let uneven = Self.dipAndBump(3.4)
        let even = Self.dipAndBump(3.0)
        // The case needs the bump just outside the even band before and just inside it after.
        let bump = try #require(uneven.extremes.first { $0.frequency > 1000 })
        print("bump before \(bump.deviation) dB; after: \(even.extremes.map(\.label))")
        #expect(!even.extremes.contains { $0.frequency > 1000 })
        let target = try #require(uneven.extremes.first { $0.kind == .dip })

        let forward = SeatComparison.compare(before: uneven, after: even, targeting: [target])
        print("forward: \(forward.verdict) | \(forward.rows.map { "\($0.label) \($0.status ?? "") \($0.change)" })")
        #expect(forward.outcome == .unchanged)
        #expect(forward.verdict == "Nothing changed that I can measure.")
        #expect(forward.rows.last?.change == .unchanged)

        let back = try #require(even.extremes.first { $0.kind == .dip })
        let reverse = SeatComparison.compare(before: even, after: uneven, targeting: [back])
        print("reverse: \(reverse.verdict) | \(reverse.note)")
        #expect(reverse.outcome == .unchanged)
        #expect(reverse.verdict == "Nothing changed that I can measure.")
        #expect(!reverse.note.contains("Putting the speaker back"))
    }

    @Test func `with nothing targeted, the verdict names what changed: a booming note`() {
        let before = Self.seat { bell($0, centre: 41, gain: 9) }
        let after = Self.seat { bell($0, centre: 41, gain: 5) }
        let comparison = SeatComparison.compare(before: before, after: after, targeting: [])
        print("untargeted peak: \(comparison.verdict) | \(comparison.rows.map { "\($0.label) \($0.before ?? "") → \($0.after ?? "")" })")
        #expect(comparison.outcome == .improved)
        #expect(comparison.verdict == "It's a little better: the booming bass note is less strong, now +5 dB.")
        #expect(!comparison.verdict.contains("missing"))
    }

    @Test func `a dip still outside the even band is less quiet, not back`() throws {
        let before = Self.seat { bell($0, centre: 61, gain: -11) }
        let after = Self.seat { bell($0, centre: 61, gain: -7.3) }
        let comparison = SeatComparison.compare(before: before, after: after, targeting: before.extremes)
        print("partly: \(comparison.verdict) | \(comparison.note)")
        #expect(comparison.rows[0].change == .improved)
        #expect(comparison.verdict == "It's a little better: the missing bass note is less quiet, now −7 dB.")
        #expect(comparison.note.contains("still a little deep"))
    }

    @Test func `a dip inside the even band is back`() {
        let before = Self.seat { bell($0, centre: 61, gain: -11) }
        let after = Self.seat { bell($0, centre: 61, gain: -2) }
        let comparison = SeatComparison.compare(before: before, after: after, targeting: before.extremes)
        #expect(comparison.verdict == "The missing bass note is back.")
        #expect(comparison.note == "All measured just now. Nothing is left outside the even band.")
    }

    @Test func `a dip that became a peak is a new problem, not a fix`() throws {
        let before = Self.seat { bell($0, centre: 61, gain: -11) }
        let after = Self.seat { bell($0, centre: 61, gain: 9) }
        let comparison = SeatComparison.compare(before: before, after: after, targeting: before.extremes)
        print("flipped: \(comparison.verdict) | \(comparison.rows.map { "\($0.label) \($0.before ?? "") → \($0.after ?? "") \($0.change)" }) | \(comparison.note)")
        #expect(!comparison.verdict.contains("back"))
        #expect(comparison.rows[0].after == "+9 dB")
        #expect(comparison.rows[0].change == .worse)
        #expect(comparison.outcome == .worse)
        #expect(comparison.verdict == "The missing bass note now booms instead.")
        // One row for the note, not a second "new" one.
        #expect(comparison.rows.filter { $0.frequency.map { abs(log2($0 / 61)) < 0.2 } ?? false }.count == 1)
    }

    /// Verdict, rows and note never contradict each other, over a grid of before-and-after cases.
    @Test func `verdict, rows and note agree over a grid of cases`() throws {
        let floor = Self.floor
        let dips: [Float] = [-11, -6]
        let afters: [Float] = [-14, -11, -10, -8, -5, -3.5, -2, 0, 2.5, 4, 9]
        let bumps: [Float] = [0, 2.9, 3.3, 6]
        let befores = dips.flatMap { dip in bumps.map { (dip, $0, Self.dipAndBump($0, dip: dip)) } }
        let laters = afters.flatMap { dip in bumps.map { (dip, $0, Self.dipAndBump($0, dip: dip)) } }
        var cases = 0
        for (dipBefore, bumpBefore, before) in befores {
            for (dipAfter, bumpAfter, after) in laters {
                for targets in [before.placementTargets, []] {
                    cases += 1
                    let c = SeatComparison.compare(before: before, after: after, targeting: targets)
                    let label = "\(dipBefore)/\(bumpBefore) → \(dipAfter)/\(bumpAfter), \(targets.count) targets: \(c.verdict) | "
                        + c.rows.map { "\($0.label) \($0.before ?? "") → \($0.after ?? "") \($0.status ?? "") \($0.change)" }.joined(separator: "; ")
                        + " | \(c.note)"
                    let improved = c.rows.filter { $0.change == .improved }
                    let worse = c.rows.filter { $0.change == .worse }
                    // Every change is beyond the repeatability, or a sign change across the even band.
                    for row in c.rows where row.change != .unchanged {
                        let then = try #require(row.beforeDecibels), now = try #require(row.afterDecibels)
                        let flipped = row.frequency != nil && then * now < 0 && abs(now) > 3
                        #expect(flipped || abs(abs(now) - abs(then)) > floor, "\(label)")
                    }
                    // "Back" only from a row that is now inside the even band.
                    if c.verdict.contains(" back") {
                        #expect(improved.contains { $0.frequency != nil && abs($0.afterDecibels!) <= 3 }, "\(label)")
                    }
                    // "Better" only when something measurably improved.
                    if ["better", " back", "calmer", "even now"].contains(where: { c.verdict.contains($0) }) {
                        #expect(!improved.isEmpty, "\(label)")
                    }
                    // A figure in the verdict is one of the improved rows' after values.
                    if let range = c.verdict.range(of: "now "), c.verdict.hasSuffix("dB.") {
                        let figure = String(c.verdict[range.upperBound...].dropLast())
                        #expect(improved.contains { $0.after == figure }, "\(label)")
                    }
                    // "Worse" only when something measurably got worse.
                    if c.verdict.contains("worse") || c.verdict.contains("instead") || c.note.contains("Putting the speaker back") {
                        #expect(!worse.isEmpty, "\(label)")
                    }
                    if c.outcome == .unchanged {
                        #expect(improved.isEmpty && worse.isEmpty && c.verdict == "Nothing changed that I can measure.", "\(label)")
                    }
                    if c.note.contains("Putting the speaker back") { #expect(c.outcome == .worse, "\(label)") }
                }
            }
        }
        #expect(cases == befores.count * laters.count * 2)
    }
}
