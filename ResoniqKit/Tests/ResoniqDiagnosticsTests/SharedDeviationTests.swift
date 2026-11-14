import Foundation
import Testing
@testable import ResoniqDiagnostics
@testable import ResoniqDSP

/// What both speakers of a pair show at the same place is more likely the room or the phone's position than a fault
/// in one of them: it stays a finding, but not a suspected defect.
@Suite struct SharedDeviationTests {
    /// A flat response at −12 dB with dips (`gain` under zero) or peaks, each half an octave wide.
    static func runs(_ features: [(frequency: Float, gain: Float)]) -> [RunAnalysis] {
        (0..<3).map { _ in
            Handmade.run(response: { frequency in
                -12 + features.reduce(Float(0)) { sum, feature in
                    abs(log2(frequency / feature.frequency)) <= 0.25 ? sum + feature.gain : sum
                }
            })
        }
    }

    static let dipped = runs([(1000, -9)])
    static let flat = runs([])

    @Test func `a dip both speakers have is reported, but not as a suspected defect`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: Self.dipped, counterpart: Self.dipped)
        let dip = try #require(report.findings.first { $0.kind == .responseDip })
        #expect(dip.sharedWithOtherSpeaker == true)
        #expect(!dip.isSuspectedDefect)
        #expect(dip.tag == .inferred)
        #expect(dip.detail.hasSuffix("The other speaker has the same dip there, so the room or where the phone was is the likelier cause."))
        #expect(dip.confidenceStatement.hasPrefix("Inferred."))
        #expect(report.suspectedDefects.isEmpty)
        #expect(report.profile.deviations.isEmpty)
        // The driver that holds it is neither called healthy nor faulted.
        #expect(report.verdict == "I found no fault. Both speakers are uneven in the same place, which points to the room or the phone's position.")
        #expect(!report.findings.contains { $0.kind == .even && $0.bands.contains(dip.bands[0]) })
    }

    @Test func `a peak both speakers have says peak`() throws {
        let peaked = Self.runs([(400, 9)])
        let report = SpeakerDiagnosis.diagnose(runs: peaked, counterpart: peaked)
        let peak = try #require(report.findings.first { $0.kind == .responsePeak })
        #expect(peak.sharedWithOtherSpeaker == true)
        #expect(peak.detail.contains("The other speaker has the same peak there"))
    }

    @Test func `a dip only this speaker has stays a suspected defect`() throws {
        for counterpart in [Self.flat, nil] {
            let report = SpeakerDiagnosis.diagnose(runs: Self.dipped, counterpart: counterpart)
            let dip = try #require(report.findings.first { $0.kind == .responseDip })
            #expect(dip.sharedWithOtherSpeaker == nil)
            #expect(dip.isSuspectedDefect)
            #expect(report.suspectedDefects.map(\.kind) == [.responseDip])
            #expect(!report.verdict.contains("Both speakers"))
        }
    }

    @Test func `a dip far deeper here than on the other speaker is still this speaker's`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: Self.runs([(1000, -20)]), counterpart: Self.runs([(1000, -8)]))
        let dip = try #require(report.findings.first { $0.kind == .responseDip })
        #expect(dip.isSuspectedDefect)
    }

    @Test func `a dip somewhere else on the other speaker is not the same dip`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: Self.dipped, counterpart: Self.runs([(4000, -9)]))
        let dip = try #require(report.findings.first { $0.kind == .responseDip })
        #expect(dip.isSuspectedDefect)
    }

    @Test func `a peak most of an octave away on the other speaker is not the same peak`() throws {
        // Seen on two real speakers: a peak at 350–490 Hz on one and at 765–1075 Hz on the other. Their edges are
        // under two thirds of an octave apart, their middles more than an octave.
        let report = SpeakerDiagnosis.diagnose(runs: Self.runs([(414, 9)]), counterpart: Self.runs([(907, 9)]))
        let peak = try #require(report.findings.first { $0.kind == .responsePeak })
        #expect(peak.sharedWithOtherSpeaker == nil)
        #expect(peak.isSuspectedDefect)
    }

    @Test func `a peak a quarter of an octave off on the other speaker is the same peak`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: Self.runs([(400, 9)]), counterpart: Self.runs([(475, 9)]))
        let peak = try #require(report.findings.first { $0.kind == .responsePeak })
        #expect(peak.sharedWithOtherSpeaker == true)
    }

    @Test func `what is shared and what is not are told apart in one report`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: Self.runs([(400, 9), (3000, -9)]), counterpart: Self.runs([(400, 9)]))
        #expect(report.suspectedDefects.map(\.kind) == [.responseDip])
        #expect(report.findings.filter { $0.sharedWithOtherSpeaker == true }.map(\.kind) == [.responsePeak])
        #expect(report.verdict.contains("may be weak around 3 kHz"), "\(report.verdict)")
        #expect(report.verdict.hasSuffix("Both speakers are uneven in the same place, which points to the room or the phone's position."))
    }

    @Test func `the speaker tested first is read again once the other has been tested`() throws {
        let uneven = Self.runs([(100, 9), (400, 9), (3000, -9)])
        var first = SpeakerDiagnosis.diagnose(runs: uneven, counterpart: nil, phoneMovedRuns: [2], source: .anotherDevice)
        #expect(first.suspectedDefects.count == 3)
        let second = SpeakerDiagnosis.diagnose(runs: uneven, counterpart: uneven)
        first = SpeakerDiagnosis.compared(first, with: second)
        #expect(first.suspectedDefects.isEmpty)
        #expect(first.findings.filter { $0.sharedWithOtherSpeaker == true }.count == 3)
        #expect(first.verdict == second.verdict)
        #expect(first.verdict == "I found no fault. Both speakers are uneven in the same 3 places, which points to the room or the phone's position.")
        // What the report knew about how it was made stays.
        #expect(first.phoneMovedRuns == [2])
        #expect(first.source == .anotherDevice)
    }

    @Test func `reading a report again changes nothing when the speakers share nothing`() {
        let alone = SpeakerDiagnosis.diagnose(runs: Self.dipped, counterpart: nil)
        let other = SpeakerDiagnosis.diagnose(runs: LeftRightTests.right, counterpart: nil)
        // No left/right difference is added to the speaker tested first.
        #expect(SpeakerDiagnosis.compared(alone, with: other) == alone)
        let inconclusive = SpeakerDiagnosis.diagnose(runs: [Bench.clippedRun], counterpart: nil)
        #expect(SpeakerDiagnosis.compared(alone, with: inconclusive) == alone)
        #expect(SpeakerDiagnosis.compared(inconclusive, with: alone) == inconclusive)
    }

    @Test func `a finding stored before this still decodes, as not shared`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: Self.dipped, counterpart: nil)
        let data = try JSONEncoder().encode(report)
        #expect(!String(decoding: data, as: UTF8.self).contains("sharedWithOtherSpeaker"))
        #expect(try JSONDecoder().decode(SpeakerReport.self, from: data) == report)
    }
}

@Suite struct UnevenVerdictTests {
    @Test func `three dips and peaks alone are an uneven response, not three alarms`() {
        let report = SpeakerDiagnosis.diagnose(runs: SharedDeviationTests.runs([(100, 9), (400, 9), (3000, -9)]), counterpart: nil)
        #expect(report.suspectedDefects.count == 3)
        #expect(report.verdict.hasPrefix("It's uneven in 3 places. From one spot I can't tell the speaker from the room."), "\(report.verdict)")
    }

    @Test func `a buzz among three keeps the plainer line`() {
        let runs = (0..<3).map { _ in
            Handmade.run(
                response: { abs(log2($0 / 400)) <= 0.25 ? -3 : (abs(log2($0 / 5000)) <= 0.25 ? -21 : -12) },
                thd: { (1000...2000).contains($0) ? Handmade.Reading(percent: 15, measurable: true, floorPercent: 0.05) : Handmade.clean }
            )
        }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(report.suspectedDefects.count == 3, "\(report.findings.map(\.headline))")
        #expect(report.verdict.hasPrefix("I found 3 things worth a closer look."), "\(report.verdict)")
    }
}
