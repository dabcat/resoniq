import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// A splice assumes the route's delay is the same in both takes. When it is not (Bluetooth and AirPlay drift), the
/// takes are compared where they overlap and a run whose takes disagree starts over instead of being spliced.
@MainActor
@Suite(.timeLimit(.minutes(3))) struct SpliceAlignmentTests {
    /// Noise 2.0 s into run 2, as in the splice test; `shift` samples are added to the route delay while paused.
    func measure(shiftingDelayBy shift: Int) async throws -> (result: MeasurementResult, notes: [RunNote]) {
        let burst = NoiseBurst(start: .afterScheduling(buffer: 1, offset: 2.0), duration: 0.6, rms: 0.02)
        let io = Fixture.io(bursts: [burst])
        let session = Fixture.session(io: io)
        var shifted = false
        let log = StateLog(session) { state, _ in
            if !shifted, case .paused(run: 2, _) = state {
                shifted = true
                io.setRouteDelay(0.02 + Double(shift) / Fixture.sampleRate)
            }
        }
        let final = await session.run()
        let result = try #require(final.result, "ended \(final)")
        #expect(shifted)
        return (result, log.notes)
    }

    @Test func `takes that line up are spliced, and their offset and the run's delay are recorded`() async throws {
        let (result, _) = try await measure(shiftingDelayBy: 0)
        let spliced = result.runs[1]
        #expect(spliced.spliceCount == 1)
        #expect(spliced.takeOffsets.count == 1)
        #expect(abs(spliced.takeOffsets[0]) < 0.2, "\(spliced.takeOffsets)")
        for run in result.runs {
            // The route's 20 ms plus the lead-in before the sweep, from the deconvolved response.
            let expected = 0.02 + Double(run.leadIn) / Fixture.sampleRate
            let measured = try #require(run.measuredDelay)
            #expect(abs(measured - expected) < 0.001, "\(measured) s")
        }
    }

    @Test func `takes five samples apart are not spliced: the run starts over`() async throws {
        let (result, notes) = try await measure(shiftingDelayBy: 5)
        let run = result.runs[1]
        #expect(run.spliceCount == 0)
        #expect(notes.contains(.restarted(.timelineUnreliable)))
        let measured = ResponseCheck.response(run.samples)
        let worst = ResponseCheck.worstDifference(measured, ResponseCheck.expected(.bookshelf, like: measured))
        print("restarted after a 5-sample drift: worst response error \(worst) dB")
        #expect(worst < 0.5)
    }

    @Test func `the misalignment between two takes is measured to a fraction of a sample`() {
        // A chirp-like signal and the same signal 3 samples later.
        let signal = (0..<8000).map { Float(sin(Double($0) * Double($0) * 1e-4) * 0.2) }
        let later = [Float](repeating: 0, count: 3) + signal
        let lag = RunRecorder.misalignment(signal[2000..<6000], against: later, at: 2000, searching: 24)
        #expect(abs((lag ?? .infinity) - 3) < 0.1, "\(String(describing: lag))")
    }
}
