import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

/// What a screen may draw of a seat report, the running average while spots come in, and how a left/right match
/// below the display's resolution is written.
@Suite struct SeatDrawingTests {
    static let grid = ResponseGrid.frequencies

    @Test func `a healthy room has no extreme at the band edges and nothing is drawn outside the judged band`() throws {
        let report = SeatDiagnosis.diagnose(spots: SeatBench.even(seed: 1), room: nil)
        #expect(report.extremes.isEmpty, "\(report.extremes.map(\.label))")
        let range = try #require(report.drawableRange)
        #expect(Self.grid[range.lowerBound] >= SeatThresholds.standard.lowerFrequency)
        #expect(Self.grid[range.upperBound] <= SeatThresholds.standard.upperFrequency)
        let drawn = try #require(report.drawableCurve)
        #expect(drawn.count == ResponseGrid.count)
        #expect(drawn.first! == nil && drawn.last! == nil)
        #expect(drawn[ResponseGrid.nearestIndex(to: 1000)] != nil)
        for index in drawn.indices { #expect((drawn[index] != nil) == range.contains(index)) }
        // What the room's own roll-off below 30 Hz and the top octave would have drawn outside the even band is gone:
        // the held curve stays inside it.
        let held = SeatReport.heldAtEdges(drawn)
        #expect(held.allSatisfy { abs($0) <= report.evenBandDecibels }, "\(held.map { abs($0) }.max() ?? 0)")
        #expect(held.first == drawn[range.lowerBound] && held.last == drawn[range.upperBound])
        // Every curve of the report is cut the same way.
        #expect(try #require(report.drawableLeftCurve)[0] == nil)
        #expect(try #require(report.drawableRightCurve)[ResponseGrid.count - 1] == nil)
        #expect(report.drawableSpotCurves.allSatisfy { $0.map { $0[0] == nil } ?? false })
    }

    @Test func `points that were not assessed inside the band are not drawn either`() throws {
        // No signal over the noise below 200 Hz.
        let report = SeatDiagnosis.diagnose(spots: handSpots({ _ in 0 }, signalToNoise: { $0 < 200 ? 5 : 40 }), room: nil)
        let range = try #require(report.drawableRange)
        #expect(Self.grid[range.lowerBound] > 150)
        #expect(try #require(report.drawableCurve)[ResponseGrid.nearestIndex(to: 60)] == nil)
    }

    @Test func `the running average grows spot by spot with its progress line`() throws {
        let spots = SeatBench.mockup
        let none = SeatDiagnosis.building(spots: [])
        #expect(none.spotCurves.isEmpty && none.average == nil)
        #expect(none.progress == "0 of 3 in")
        let one = SeatDiagnosis.building(spots: Array(spots.prefix(1)))
        #expect(one.spotCurves.count == 1)
        #expect(one.progress == "1 of 3 in")
        let average = try #require(one.average)
        #expect(average.first! == nil && average.last! == nil)
        let two = SeatDiagnosis.building(spots: Array(spots.prefix(2)))
        #expect(two.spotCurves.count == 2 && two.progress == "2 of 3 in")
        let three = SeatDiagnosis.building(spots: spots)
        #expect(three.progress == "3 of 3 in")
        // The average is the report's own seat curve, cut to what may be drawn.
        let report = SeatDiagnosis.diagnose(spots: spots, room: nil)
        #expect(three.average == report.drawableCurve)
        #expect(three.spotCurves == report.drawableSpotCurves.compactMap { $0 })
        #expect(SeatReport.heldAtEdges(three.average!).count == ResponseGrid.count)
    }

    @Test func `a spot that failed adds no curve and does not count as in`() {
        var spots = Array(SeatBench.mockup.prefix(2))
        let clipped = SpotRecording(check: .clipped(clippedFraction: 0.1), measurement: nil)
        spots[1] = SpotAnalysis(left: clipped, right: spots[1].right)
        let building = SeatDiagnosis.building(spots: spots)
        #expect(building.spotCurves.count == 1)
        #expect(building.progress == "1 of 3 in")
    }

    @Test func `left and right identical read within 0.1 dB, never 0.0`() throws {
        #expect(SeatText.matchTagLine(0) == "Measured · within 0.1 dB")
        #expect(SeatText.matchTagLine(0.04) == "Measured · within 0.1 dB")
        #expect(SeatText.matchTagLine(1.24) == "Measured · within 1.2 dB")
        #expect(SeatText.leftMatchesDetail(0) == "Above the bass, the two speakers stay within 0.1 dB of each other.")
        #expect(SeatText.plusMinus(0) == "±0.1 dB")
        let report = SeatDiagnosis.diagnose(spots: handSpots { _ in 0 }, room: nil)
        let rest = try #require(report.findings.first { $0.kind == .rest })
        #expect(rest.tagLine == "Measured · within 0.1 dB")
        #expect(!(rest.tagLine + rest.detail).contains("0.0 dB"))
        #expect(report.numbers.first { $0.kind == .leftRight }?.value == "±0.1 dB")
    }

    @Test func `the problem's place is the seat`() {
        let report = MockupSeatTests.report
        #expect(!report.placementTargets.isEmpty)
        #expect(report.placementTargets.allSatisfy { report.location(of: $0) == .seat })
    }
}
