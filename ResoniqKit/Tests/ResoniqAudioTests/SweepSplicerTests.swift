import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

@Suite(.timeLimit(.minutes(3))) struct SweepSplicerTests {
    /// A take of the sweep heard with delay `delay`: zeros, then the sweep from `firstIndex`, at capture positions
    /// from `start`, scheduled at `scheduledAt`.
    func take(_ sweep: [Float], firstIndex: Int, scheduledAt: Int64, delay: Int, start: Int64, count: Int) -> SweepSplicer.Take {
        let samples = (0..<count).map { offset -> Float in
            let index = Int(start + Int64(offset) - scheduledAt) - delay + firstIndex
            return index >= firstIndex && index < sweep.count ? sweep[index] : 0
        }
        return SweepSplicer.Take(samples: samples, start: start, sweepOrigin: scheduledAt - Int64(firstIndex))
    }

    @Test func `two takes of the same signal splice into the uninterrupted one exactly`() throws {
        let sweep = Fixture.sweep.samples()
        let delay = 3000
        let whole = take(sweep, firstIndex: 0, scheduledAt: 1000, delay: delay, start: 0, count: sweep.count + 10000)
        // The first take is cut at 60 000; the second starts 20 000 samples into the sweep, scheduled much later.
        var first = whole
        first.samples = Array(whole.samples[0..<60000])
        let second = take(sweep, firstIndex: 20000, scheduledAt: 500_000, delay: delay, start: 490_000, count: sweep.count)
        let spliced = try SweepSplicer.splice(first, second, crossfadeAt: 50000, crossfadeLength: 960)

        #expect(spliced.start == whole.start && spliced.sweepOrigin == whole.sweepOrigin)
        let common = min(spliced.samples.count, whole.samples.count)
        #expect(common >= sweep.count + delay)
        let worst = zip(spliced.samples.prefix(common), whole.samples.prefix(common)).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-6)
    }

    @Test func `a crossfade outside either take is refused`() {
        let first = SweepSplicer.Take(samples: [Float](repeating: 0, count: 100), start: 0, sweepOrigin: 0)
        let second = SweepSplicer.Take(samples: [Float](repeating: 0, count: 100), start: 1000, sweepOrigin: 1000)
        #expect(throws: SweepSplicer.SpliceError.crossfadeOutsideFirstTake) {
            try SweepSplicer.splice(first, second, crossfadeAt: 95, crossfadeLength: 10)
        }
        // Position 10 maps to 1010 in a take whose samples start at 1050.
        let late = SweepSplicer.Take(samples: [Float](repeating: 0, count: 100), start: 1050, sweepOrigin: 1000)
        #expect(throws: SweepSplicer.SpliceError.secondTakeDoesNotCover) {
            try SweepSplicer.splice(first, late, crossfadeAt: 10, crossfadeLength: 10)
        }
    }

    @Test func `the plan resumes an overlap before the noise and splices before it`() throws {
        let configuration = Fixture.configuration
        let rate = Fixture.sampleRate
        let plan = try #require(SweepSplicer.plan(
            noiseOnset: 200_000, sweepOrigin: 100_000, firstIndex: 0, delay: 4800,
            sweepCount: Fixture.sweep.sampleCount, configuration: configuration, sampleRate: rate
        ))
        let noiseIndex = 200_000 - 100_000 - 4800
        #expect(plan.resumeIndex == noiseIndex - Int(configuration.resumeOverlap * rate))
        // The crossfade ends one guard before the onset.
        let crossfadeEnd = plan.crossfadeAt + Int64(configuration.crossfade * rate)
        #expect(crossfadeEnd == 200_000 - Int64(configuration.noiseGuard * rate))
    }

    @Test func `no splice is planned for noise at the start, or right after a resumed take began`() {
        let configuration = Fixture.configuration
        let rate = Fixture.sampleRate
        #expect(SweepSplicer.plan(
            noiseOnset: 110_000, sweepOrigin: 100_000, firstIndex: 0, delay: 1000,
            sweepCount: Fixture.sweep.sampleCount, configuration: configuration, sampleRate: rate
        ) == nil)
        // A take that resumed from sample 50 000 and was caught again 0.1 s later.
        #expect(SweepSplicer.plan(
            noiseOnset: 100_000 + 50_000 + 1000 + 4800, sweepOrigin: 100_000, firstIndex: 50_000, delay: 1000,
            sweepCount: Fixture.sweep.sampleCount, configuration: configuration, sampleRate: rate
        ) == nil)
    }

    /// The whole mechanism on a simulated speaker with a route delay, a distorting band and room noise: one take
    /// stopped partway, a second resumed from the plan's point after a pause, spliced, against one uninterrupted take.
    @Test func `a spliced recording of a simulated speaker deconvolves like an uninterrupted one`() async throws {
        let speaker = SimulatedSpeaker(
            gain: 0.5,
            filters: [.highPass(frequency: 60, q: 0.707), .peaking(frequency: 1200, q: 2, gain: -6)],
            defect: .init(band: 2000...3000, cubic: 8)
        )
        let rate = Fixture.sampleRate
        let delaySeconds = 0.25
        let sweep = Fixture.sweep
        let samples = sweep.samples()
        let configuration = Fixture.configuration

        func io() -> SimulatedAudioIO {
            SimulatedAudioIO(configuration: .init(
                sampleRate: rate, routeDelay: delaySeconds, noiseRMS: 1e-4, left: speaker, right: speaker, pacing: .immediate
            ))
        }

        // Uninterrupted.
        let reference = io()
        let stream = try await reference.start()
        var tape: [Float] = []
        var origin: Int64 = 0
        for try await block in stream.blocks {
            if block.position == 4800 { origin = try reference.schedule(samples, on: .left, mode: .once) }
            tape += block.samples
            if tape.count >= Int(rate * 5) { break }
        }
        await reference.stop()
        let uninterrupted = Array(tape[Int(origin)...])

        // Interrupted at 2.0 s into the sweep, resumed 1 s later.
        let interrupted = io()
        let second = try await interrupted.start()
        var first = SweepSplicer.Take(samples: [], start: 0, sweepOrigin: 0)
        var resumed: SweepSplicer.Take?
        var plan: SweepSplicer.Plan?
        let delay = Int(delaySeconds * rate)
        for try await block in second.blocks {
            if block.position == 4800 {
                first.sweepOrigin = try interrupted.schedule(samples, on: .left, mode: .once)
            }
            let elapsed = block.position - first.sweepOrigin
            if plan == nil, first.sweepOrigin > 0, elapsed >= Int64(2.0 * rate) + Int64(delay) {
                interrupted.stopPlayback()
                plan = SweepSplicer.plan(
                    noiseOnset: block.position, sweepOrigin: first.sweepOrigin, firstIndex: 0, delay: delay,
                    sweepCount: samples.count, configuration: configuration, sampleRate: rate
                )
            }
            if let plan, resumed == nil, elapsed >= Int64(3.0 * rate) + Int64(delay) {
                let faded = SweepSplicer.fadedIn(samples[plan.resumeIndex...], length: Int(configuration.fadeIn * rate))
                let position = try interrupted.schedule(faded, on: .left, mode: .once)
                resumed = SweepSplicer.Take(samples: [], start: block.end, sweepOrigin: position - Int64(plan.resumeIndex))
                continue
            }
            if resumed == nil, plan == nil {
                first.samples += block.samples
            } else if resumed != nil {
                resumed!.samples += block.samples
                if Double(resumed!.samples.count) >= rate * 3.5 { break }
            }
        }
        await interrupted.stop()

        let thePlan = try #require(plan)
        let theResumed = try #require(resumed)
        let spliced = try SweepSplicer.splice(first, theResumed, crossfadeAt: thePlan.crossfadeAt, crossfadeLength: 960)
        let recording = Array(spliced.samples[Int(spliced.sweepOrigin - spliced.start)...].prefix(uninterrupted.count))

        let measured = ResponseCheck.response(recording, sweep: sweep)
        let whole = ResponseCheck.response(uninterrupted, sweep: sweep)
        let smoothed = ResponseCheck.worstDifference(measured, whole)
        let raw = zip(measured.decibels, whole.decibels).enumerated()
            .filter { measured.frequencies[$0.offset] >= 100 && measured.frequencies[$0.offset] <= 16000 }
            .map { abs($0.element.0 - $0.element.1) }.max() ?? .infinity
        print("splice on a simulated speaker: worst difference \(smoothed) dB smoothed, \(raw) dB raw, resumed at \(sweep.frequency(at: Double(thePlan.resumeIndex) / rate)) Hz")
        #expect(smoothed < 0.1)
        #expect(raw < 0.5)

        // The distortion in its band survives the splice too.
        let distortionSpliced = HarmonicDistortion.analyze(impulseResponse: Deconvolution.impulseResponse(recording: recording, sweep: sweep), sweep: sweep)
        let distortionWhole = HarmonicDistortion.analyze(impulseResponse: Deconvolution.impulseResponse(recording: uninterrupted, sweep: sweep), sweep: sweep)
        let thd = (distortionSpliced.thdPercent(at: 2500), distortionWhole.thdPercent(at: 2500))
        print("THD at 2.5 kHz: spliced \(thd.0) %, uninterrupted \(thd.1) %")
        #expect(abs(thd.0 - thd.1) < max(0.1 * thd.1, 0.05))
    }
}
