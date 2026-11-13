import Foundation
import Testing
@testable import ResoniqDiagnostics
@testable import ResoniqDSP

extension SimulatedRoom {
    /// What the phone records at `spot` when another device plays `sweep` on a clock `ratio` times the phone's, cut as
    /// the listening session cuts it: `leadIn` seconds before the sweep, `tail` after.
    func recordPlayedElsewhere(_ sweep: LogSweep, ratio: Double, spot: Int, channel: Channel, seed: UInt64,
                               leadIn: Double = 0.05, tail: Double = 2.4) -> [Float] {
        let lead = Int(leadIn * sweep.sampleRate)
        let played = Int(Double(sweep.sampleCount) / ratio) + 2
        let length = lead + played + Int(tail * sweep.sampleRate)
        // The player reads its file at its own clock: sample m of the phone's is the file's m · ratio.
        let source = Interpolation.resample(sweep.samples(), from: -Double(lead) * ratio, step: ratio, count: length)
        var signal = source.map { Double($0) * gain }
        signal = signal.map { $0 + quadratic * $0 * $0 + cubic * $0 * $0 * $0 }
        for filter in filters(spot: spot, channel: channel) { signal = filter.process(signal) }
        let lag = Int((reflectionDelays[spot] * sweep.sampleRate).rounded())
        if reflection != 0 {
            let direct = signal
            for index in lag..<signal.count { signal[index] += reflection * direct[index - lag] }
        }
        if noiseRMS > 0 { signal = zip(signal, noise(count: length, seed: seed)).map(+) }
        return signal.map(Float.init)
    }
}

@Suite struct SoundSourceTests {
    static let sweep = LogSweep.measurement(sampleRate: 48000)

    @Test func `a speaker report keeps how the sound was played, and says it`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: [], counterpart: nil, source: .anotherDevice)
        #expect(report.source == .anotherDevice)
        #expect(report.sourceNote == "Measured from a test sound played on another device.")
        let stored = try storedForm(report)
        #expect(stored.contains(#""source":"anotherDevice""#))
        #expect(try JSONDecoder().decode(SpeakerReport.self, from: Data(stored.utf8)) == report)

        let normal = SpeakerDiagnosis.diagnose(runs: [], counterpart: nil)
        #expect(normal.source == nil && normal.sourceNote == nil)
        #expect(try !storedForm(normal).contains("source"))
    }

    @Test func `reports stored before the source decode as played by the phone`() throws {
        let speaker = try JSONDecoder().decode(SpeakerReport.self, from: Data(GoldenJSON.speaker.utf8))
        #expect(speaker.source == nil)
        let seat = try JSONDecoder().decode(SeatReport.self, from: Data(GoldenJSON.seat.utf8))
        #expect(seat.source == nil)
    }

    @Test func `hold-to-hear says why it cannot play in this mode`() {
        #expect(DiagnosisText.holdToHearUnavailable(frequency: "120 Hz")
            == "I can't play the tone myself in this mode, because the sound comes from your own player. To hear it, play the test sound file again and listen as it passes 120 Hz.")
        #expect(DiagnosisText.holdToHearUnavailable(frequency: nil).hasSuffix("listen as it plays."))
    }

    /// A seat measured from another device whose clock runs 300 ppm slow, corrected as the session corrects it, reads
    /// as the same seat measured the normal way: the same verdict and curve, and the bass decay still estimated.
    @Test func `a seat played elsewhere and corrected reads as one played by the phone`() throws {
        let room = SeatBench.mockupRoom
        let floor = room.noiseFloor()
        let ratio = 0.9997
        func spots(_ record: (Int, SimulatedRoom.Channel) -> [Float]) -> [SpotAnalysis] {
            (0..<3).map { spot in
                SpotAnalyzer.analyze(left: record(spot, .left), right: record(spot, .right), sweep: Self.sweep, noiseFloor: floor)
            }
        }
        let normal = spots { spot, channel in
            room.recordPlayedElsewhere(Self.sweep, ratio: 1, spot: spot, channel: channel, seed: UInt64(10 + spot))
        }
        let corrected = spots { spot, channel in
            SweepFinder.corrected(room.recordPlayedElsewhere(Self.sweep, ratio: ratio, spot: spot, channel: channel, seed: UInt64(10 + spot)), ratio: ratio)
        }
        let normalReport = SeatDiagnosis.diagnose(spots: normal, room: nil)
        let report = SeatDiagnosis.diagnose(spots: corrected, room: nil, source: .anotherDevice)
        #expect(report.source == .anotherDevice)
        #expect(report.sourceNote == DiagnosisText.measuredFromAnotherDevice)
        #expect(report.isConclusive && report.validSpotCount == 3)
        #expect(report.verdict == normalReport.verdict)
        #expect(report.bassDecay != nil)
        let curve = try #require(report.curve)
        let normalCurve = try #require(normalReport.curve)
        let worst = zip(curve, normalCurve).map { abs($0 - $1) }.max() ?? .infinity
        print("seat played elsewhere, corrected: curve within \(worst) dB of the phone's")
        #expect(worst < 0.5)
        let stored = try storedForm(report)
        #expect(try JSONDecoder().decode(SeatReport.self, from: Data(stored.utf8)).source == .anotherDevice)
    }
}
