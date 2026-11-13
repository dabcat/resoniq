import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

/// Frequencies found by the diagnosis are held to a third of an octave of where the simulation put them: the
/// response is smoothed to 1/3 octave, so its edges cannot be sharper than that.
let rangeTolerance: Float = 1.0 / 3

func isNear(_ measured: Float, _ expected: Float, octaves: Float = rangeTolerance) -> Bool {
    abs(log2(measured / expected)) <= octaves
}

func deviations(_ report: SpeakerReport) -> [Finding] {
    report.findings.filter(\.kind.isDeviation)
}

// MARK: - Healthy speakers: the worst failure is a false alarm

@Suite struct HealthySpeakerTests {
    /// Seeds of the speaker's own −60 dBFS noise: a quiet room.
    static let seeds: [UInt64] = [1, 2, 3, 4]
    /// Rooms down to the recording check's 20 dB gate: two seeds at the gate, where noise reads as the most
    /// distortion, and one at 25 and 30 dB.
    static let noisyCases: [HealthyCase] = [
        HealthyCase(seed: 7, signalToNoise: 20),
        HealthyCase(seed: 8, signalToNoise: 20),
        HealthyCase(seed: 7, signalToNoise: 25),
        HealthyCase(seed: 7, signalToNoise: 30),
    ]
    static let allCases: [HealthyCase] = seeds.map { HealthyCase(seed: $0, signalToNoise: nil) } + noisyCases

    @Test(arguments: allCases)
    func `a healthy speaker gives no deviation findings`(_ item: HealthyCase) {
        let runs = Bench.healthyRuns[item]!
        #expect(runs.allSatisfy { $0.isValid }, "\(runs.map(\.verdict))")
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(deviations(report).isEmpty, "\(deviations(report).map(\.headline))")
        #expect(report.verdict == "Sounds healthy.")
        #expect(!report.findings.contains { $0.tag == .inferred })
        #expect(!report.findings.contains { $0.kind == .distortionUnclear }, "\(report.findings.map(\.headline))")
    }

    /// The review's most severe defect: at 20 dB signal-to-noise a clean speaker's THD reads 2–5 % from the noise
    /// alone. That reading is not a measurement, so it is never a buzz, and the even statement does not call the
    /// speaker clean where it was taken.
    @Test func `noise read as distortion is neither a buzz nor called clean`() throws {
        let runs = Bench.healthyRuns[HealthyCase(seed: 7, signalToNoise: 20)]!
        let measurement = try #require(runs[0].measurement)
        let index = ResponseGrid.nearestIndex(to: 5000)
        guard case .belowNoise(let read, let bound?) = measurement.distortion(atIndex: index) else {
            Issue.record("expected THD below the noise at 5 kHz, got \(measurement.distortion(atIndex: index))")
            return
        }
        // The speaker's own THD is about 1 %; the rest is noise, and the noise's bound is over the buzz threshold.
        print("healthy at 20 dB: THD reads \(read) % at 5 kHz, known only to be under \(bound) %")
        #expect(read > 2)
        #expect(bound >= DiagnosisThresholds.standard.distortionPercent)

        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .distortion })
        let even = try #require(report.findings.first { $0.kind == .even })
        // The statement covers only where every run ruled a buzz out, which stops well short of 5 kHz.
        let ruledOut = SpeakerDiagnosis.distortionRuledOut(
            Dictionary(uniqueKeysWithValues: runs.enumerated().map { ($0.offset, $0.element.measurement!) }),
            audible: [Bool](repeating: true, count: ResponseGrid.count),
            thresholds: .standard
        )
        let last = try #require(ResponseGrid.frequencies.indices.last { ruledOut[$0] && ResponseGrid.frequencies[$0] < 5000 })
        #expect(!ruledOut[index])
        #expect(even.detail == "Distortion stayed under 10 % from 80 Hz to \(DiagnosisText.frequency(ResponseGrid.frequencies[last])).", "\(even.detail)")
        #expect(ResponseGrid.frequencies[last] < 2000)
    }

    /// A speaker with ±2.5 dB of ordinary unevenness and a steep bass roll-off is still healthy.
    @Test(arguments: [11, 12] as [UInt64])
    func `an uneven but healthy speaker gives no deviation findings`(seed: UInt64) {
        let speaker = SimulatedSpeaker(
            filters: [
                Biquad.highPass(frequency: 80, q: 0.707, sampleRate: Bench.sampleRate),
                Biquad.peaking(frequency: 300, q: 1.4, gain: -2.5, sampleRate: Bench.sampleRate),
                Biquad.peaking(frequency: 2500, q: 1.4, gain: 2.5, sampleRate: Bench.sampleRate),
            ],
            quadratic: 0.16,
            cubic: 0.32,
            noiseRMS: 0.003
        )
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker, seed: seed), counterpart: nil)
        #expect(deviations(report).isEmpty, "\(deviations(report).map(\.headline))")
    }

    @Test func `the margin to every threshold on a healthy speaker is printed and comfortable`() {
        let thresholds = DiagnosisThresholds.standard
        var worstDeviation: Float = 0
        var worstDistortion: Float = 0
        for seed in Self.seeds {
            for run in Bench.healthyRuns(seed: seed) {
                let measurement = try! #require(run.measurement)
                // In a quiet room a buzz is ruled out everywhere THD is read: the speaker's own 1 % is measured, or
                // (around 2 kHz, where it sits within 10 dB of the floor) known to be under about 1.1 %.
                for index in ResponseGrid.frequencies.indices where measurement.thdDecibels[index] != nil {
                    switch measurement.distortion(atIndex: index) {
                    case .measured(let percent) where percent < thresholds.distortionPercent: continue
                    case .belowNoise(_, let bound?) where bound < thresholds.distortionPercent / 2: continue
                    case let reading:
                        Issue.record("no buzz ruled out at \(ResponseGrid.frequencies[index]) Hz: \(reading)")
                    }
                    break
                }
                let deviation = Trend.deviation(of: measurement.response, thresholds: thresholds)
                for (index, frequency) in ResponseGrid.frequencies.enumerated()
                where frequency >= thresholds.responseLowerFrequency && frequency <= thresholds.topEndFrequency {
                    worstDeviation = max(worstDeviation, abs(deviation[index]))
                }
                for (index, frequency) in ResponseGrid.frequencies.enumerated() where frequency >= thresholds.distortionLowerFrequency {
                    if let thd = measurement.thdPercent(atIndex: index) { worstDistortion = max(worstDistortion, thd) }
                }
            }
        }
        print("healthy: worst deviation \(worstDeviation) dB (threshold \(thresholds.deviationDecibels)), worst THD \(worstDistortion) % (threshold \(thresholds.distortionPercent))")
        #expect(worstDeviation < thresholds.deviationDecibels / 2)
        #expect(worstDistortion < thresholds.distortionPercent / 2)
    }

    @Test func `a healthy speaker is described as even, and the statement is measured`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: Bench.healthyRuns(seed: 1), counterpart: nil)
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.tag == .measured)
        #expect(even.bands == [.tweeter, .middle, .woofer])
        #expect(even.headline == "Tweeter, mid and woofer are even")
        // Distortion is read from 80 Hz (the DSP's trusted band for the second harmonic) to under half the sweep's
        // end; rattle is not measured from a sweep, so it is not mentioned.
        #expect(even.detail == "Distortion stayed under 10 % from 80 Hz to 9.2 kHz.")
        #expect(even.tagLine == "Measured")
        #expect(even.basis == Finding.Basis(runsAgreeing: 3, runsCompared: 3))
    }
}

// MARK: - Distortion: the rule of repetition

@Suite struct DistortionTests {
    static let threeOfThree = SpeakerDiagnosis.diagnose(runs: Bench.buzzingRuns, counterpart: nil)
    static let buzzing = Bench.buzzingRuns
    static let healthy = Bench.healthyRuns(seed: 1)

    @Test func `a buzz in 3 of 3 runs is inferred with the basis "3 of 3 runs"`() throws {
        let buzz = try #require(Self.threeOfThree.findings.first { $0.kind == .distortion })
        #expect(buzz.tag == .inferred)
        #expect(buzz.basis.runsAgreeing == 3 && buzz.basis.runsCompared == 3)
        #expect(buzz.basis.text == "3 of 3 runs")
        #expect(buzz.confidence == .medium)
        #expect(buzz.band == .woofer)
        let range = try #require(buzz.frequencyRange)
        // The simulated buzz is 72–110 Hz; THD is read from 80 Hz.
        #expect(isNear(range.lower, 80) && isNear(range.upper, 110), "\(range)")
        #expect(deviations(Self.threeOfThree).count == 1, "\(deviations(Self.threeOfThree).map(\.headline))")
    }

    /// The mockup's words, with the numbers the DSP's trusted band allows: the mockup's "70–110 Hz" and "around
    /// 90 Hz" are now "80–110 Hz" and "around 100 Hz", since no THD is read under 80 Hz; and the even statement says
    /// over which frequencies distortion was measured instead of "No distortion or rattle found." (rattle is not
    /// measured).
    @Test func `the buzz reads as the mockups show it`() throws {
        let report = Self.threeOfThree
        let buzz = try #require(report.findings.first { $0.kind == .distortion })
        #expect(buzz.headline == "Buzz at 80–110 Hz")
        #expect(buzz.tagLine == "Inferred · 3 of 3 runs")
        #expect(buzz.sentence == "A buzz around 100 Hz.")
        #expect(buzz.confidenceStatement == "Inferred, medium confidence. It repeats every run, but from one microphone position I can't rule out something near the speaker vibrating.")
        #expect(buzz.repeatability == "Same place every time")
        #expect(buzz.listenFrequency == 100)
        #expect(report.verdict == "Sounds healthy, except the woofer may be buzzing.")
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.headline == "Tweeter and mid are even")
        #expect(even.detail == "Distortion stayed under 10 % from 310 Hz to 9.2 kHz.")
        #expect(even.tagLine == "Measured")
    }

    @Test func `a buzz in a room at the 20 dB gate is still measured`() throws {
        let runs = Bench.runs(Bench.noisy(Bench.buzzing, signalToNoise: 20), seed: 9)
        #expect(runs.allSatisfy { $0.isValid }, "\(runs.map(\.verdict))")
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        let buzz = try #require(report.findings.first { $0.kind == .distortion })
        #expect(buzz.tag == .inferred && buzz.basis.text == "3 of 3 runs")
        let range = try #require(buzz.frequencyRange)
        #expect(isNear(range.lower, 80) && isNear(range.upper, 110), "\(range)")
        #expect(deviations(report).count == 1, "\(deviations(report).map(\.headline))")
    }

    @Test func `the numbers behind the buzz are kept for each run`() throws {
        let buzz = try #require(Self.threeOfThree.findings.first { $0.kind == .distortion })
        let numbers = try #require(buzz.numbers)
        #expect(numbers.unit == .percent)
        #expect(numbers.perRun.count == 3 && numbers.perRun.allSatisfy { ($0 ?? 0) > 15 })
        #expect(numbers.extreme > 15 && numbers.extreme < 40, "\(numbers.extreme)")
        #expect(isNear(numbers.extremeFrequency, 90, octaves: 0.5))
        #expect(numbers.threshold == DiagnosisThresholds.standard.distortionPercent)
        // The Finding screen lays the three runs over each other around the buzz.
        #expect(Self.threeOfThree.runs.count == 3)
        #expect(Self.threeOfThree.runs.allSatisfy { $0.measurement?.thdDecibels.count == ResponseGrid.count })
        let context = try #require(buzz.context)
        // The mockup shows the runs from 40 to 200 Hz around 70–110 Hz: most of an octave either side.
        let range = try #require(buzz.frequencyRange)
        #expect(isNear(context.lower, range.lower / 1.8, octaves: 0.01) && isNear(context.upper, range.upper * 1.8, octaves: 0.01))
    }

    @Test func `a buzz in 2 of 3 runs is inferred with lower confidence`() throws {
        let runs = [Self.buzzing[0], Self.healthy[1], Self.buzzing[2]]
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        let buzz = try #require(report.findings.first { $0.kind == .distortion })
        #expect(buzz.tag == .inferred)
        #expect(buzz.basis.text == "2 of 3 runs")
        #expect(buzz.tagLine == "Inferred · 2 of 3 runs")
        #expect(buzz.confidence == .low)
        #expect(buzz.repeatability == "Same place in 2 of 3 runs")
        #expect(buzz.confidenceStatement.hasPrefix("Inferred, low confidence."))
        #expect(buzz.numbers?.perRun[1] == nil)
    }

    @Test func `a buzz in 1 of 3 runs is dropped`() {
        let runs = [Self.healthy[0], Self.healthy[1], Self.buzzing[2]]
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(deviations(report).isEmpty, "\(deviations(report).map(\.headline))")
        #expect(report.verdict == "Sounds healthy.")
    }
}

// MARK: - Response

@Suite struct ResponseTests {
    @Test func `a broad dip in every run is inferred and placed where it is`() throws {
        let speaker = Bench.healthy(with: [Biquad.peaking(frequency: 1000, q: 1, gain: -9, sampleRate: Bench.sampleRate)])
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker, sweep: Bench.responseSweep), counterpart: nil)
        let dip = try #require(report.findings.first { $0.kind == .responseDip })
        #expect(dip.tag == .inferred && dip.basis.text == "3 of 3 runs")
        #expect(dip.band == .middle)
        let range = try #require(dip.frequencyRange)
        #expect(isNear(range.centre, 1000), "\(range)")
        #expect(range.octaves > 0.5 && range.octaves < 2.5, "\(range.octaves)")
        let depth = try #require(dip.numbers?.extreme)
        #expect(depth < -6 && depth > -10, "\(depth)")
        #expect(deviations(report).count == 1)
        #expect(report.verdict.hasPrefix("Sounds healthy, except the middle driver may be weak around"))
        #expect(!report.verdict.contains("is broken"))
        // The portrait shows the dip as a deviation, and narrower there.
        #expect(report.profile.deviations == [range])
        let index = ResponseGrid.nearestIndex(to: 1000)
        let reference = ResponseGrid.nearestIndex(to: 5000)
        #expect(report.profile.widths[index] < report.profile.widths[reference] * 0.85)
    }

    @Test func `a peak in every run is inferred`() throws {
        let speaker = Bench.healthy(with: [Biquad.peaking(frequency: 3000, q: 1, gain: 9, sampleRate: Bench.sampleRate)])
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker, sweep: Bench.responseSweep), counterpart: nil)
        let peak = try #require(report.findings.first { $0.kind == .responsePeak })
        #expect(peak.tag == .inferred)
        #expect(isNear(try #require(peak.frequencyRange).centre, 3000))
        #expect(deviations(report).count == 1)
    }

    @Test func `a dip above 14 kHz is inconclusive, could be the phone's angle`() throws {
        let speaker = Bench.healthy(with: [
            Biquad.lowPass(frequency: 14000, q: 0.707, sampleRate: Bench.sampleRate),
        ])
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker), counterpart: nil)
        let top = try #require(report.findings.first { $0.kind == .topEndDip })
        #expect(top.tag == .inconclusive)
        #expect(top.tagLine == "Inconclusive")
        #expect(top.headline == "Very top notes dip")
        #expect(top.detail == "Above 14 kHz. Could be the phone's angle.")
        #expect(top.band == .tweeter)
        #expect(deviations(report).isEmpty, "\(deviations(report).map(\.headline))")
        // Inconclusive is not a suspected defect: the speaker still sounds healthy, and the tweeter is even.
        #expect(report.verdict == "Sounds healthy.")
        #expect(report.findings.first { $0.kind == .even }?.bands.contains(.tweeter) == true)
        // The mockup's order: top of the portrait first.
        #expect(report.findings.first?.kind == .topEndDip)
    }

    @Test func `the mockup's result: top-end dip, even tweeter and mid, buzz`() {
        let speaker: SimulatedSpeaker = {
            var speaker = Bench.buzzing
            speaker.filters.append(Biquad.lowPass(frequency: 14000, q: 0.707, sampleRate: Bench.sampleRate))
            return speaker
        }()
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker), counterpart: nil)
        #expect(report.verdict == "Sounds healthy, except the woofer may be buzzing.")
        #expect(report.findings.map(\.tagLine) == ["Inconclusive", "Measured", "Inferred · 3 of 3 runs"])
        #expect(report.findings.map(\.headline) == ["Very top notes dip", "Tweeter and mid are even", "Buzz at 80–110 Hz"])
        #expect(report.findings.map(\.detail).first == "Above 14 kHz. Could be the phone's angle.")
    }
}

// MARK: - Recordings that cannot be used

@Suite struct InvalidRecordingTests {
    static let buzzing = Bench.buzzingRuns
    static let healthy = Bench.healthyRuns(seed: 1)

    @Test func `a clipped run is reported and nothing is concluded from it`() throws {
        let clippedRun = Bench.clippedRun
        guard case .clipped(let clipping) = clippedRun.verdict else {
            Issue.record("expected a clipped verdict, got \(clippedRun.verdict)")
            return
        }
        #expect(clippedRun.measurement == nil)
        // The buzz is in the clipped run and one good run only: one good run is not enough.
        let report = SpeakerDiagnosis.diagnose(runs: [Self.buzzing[0], clippedRun, Self.healthy[1]], counterpart: nil)
        let invalid = try #require(report.findings.first)
        #expect(invalid.kind == .invalidRecording)
        #expect(invalid.tag == .inconclusive)
        #expect(invalid.recordingProblem == .clipped)
        #expect(invalid.headline == "One run was too loud to use")
        #expect(invalid.basis.text == "1 of 3 runs")
        #expect(deviations(report).isEmpty)
        #expect(report.runs[1].check == .clipped(clippedFraction: clipping.clippedFraction))
        #expect(report.runs[1].measurement == nil)
    }

    @Test func `with one invalid run the basis counts the runs that could be compared`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: [Self.buzzing[0], Self.buzzing[1], Bench.clippedRun], counterpart: nil)
        let buzz = try #require(report.findings.first { $0.kind == .distortion })
        #expect(buzz.basis.text == "2 of 2 runs")
        #expect(buzz.confidence == .low)
        #expect(buzz.numbers?.perRun.count == 3 && buzz.numbers?.perRun[2] == nil)
        #expect(report.findings.first?.kind == .invalidRecording)
    }

    @Test func `a noisy run is reported as too noisy`() throws {
        let run = Bench.noisyRun
        guard case .tooNoisy = run.verdict else {
            Issue.record("expected too noisy, got \(run.verdict)")
            return
        }
        #expect(run.record.check.problem == .tooNoisy)
        let report = SpeakerDiagnosis.diagnose(runs: [run, Self.healthy[1], Self.healthy[2]], counterpart: nil)
        #expect(report.findings.first?.headline == "One run was too noisy to use")
        #expect(report.isConclusive)
        #expect(deviations(report).isEmpty)
    }

    @Test func `with fewer than two usable runs nothing is concluded`() {
        let report = SpeakerDiagnosis.diagnose(runs: [Bench.noisyRun, Bench.clippedRun, Self.buzzing[0]], counterpart: nil)
        #expect(!report.isConclusive)
        #expect(report.findings.allSatisfy { $0.kind == .invalidRecording })
        #expect(report.findings.count == 2)
        #expect(report.verdict == "I couldn't get clean enough recordings to judge this speaker.")
        #expect(report.profile == .notHeard)
    }

    @Test func `a corrupt run is invalid and says so in its own words`() throws {
        var recording = Bench.healthy.record(Bench.sweep)
        recording[50_000] = .nan
        recording[50_001] = .infinity
        let run = RunAnalyzer.analyze(recording: recording, sweep: Bench.sweep, noiseFloor: Bench.noiseFloor(rms: Bench.healthy.noiseRMS))
        #expect(run.verdict == .corrupt(nonFiniteSampleCount: 2))
        #expect(run.record.check == .corrupt(nonFiniteSampleCount: 2))
        #expect(run.measurement == nil)
        let report = SpeakerDiagnosis.diagnose(runs: [run, Self.healthy[1], Self.healthy[2]], counterpart: nil)
        let invalid = try #require(report.findings.first)
        #expect(invalid.recordingProblem == .corrupt)
        #expect(invalid.tag == .inconclusive)
        #expect(invalid.headline == "One run came back damaged")
        #expect(invalid.sentence == "The recording came back damaged, so I left that run out.")
        #expect(report.isConclusive && deviations(report).isEmpty)
    }

    /// A recording that stopped before the sweep's end arrived concludes nothing, not even about the part it holds
    /// (`RecordingCheck.incomplete` gives the reasons).
    @Test func `a run cut short is invalid, and nothing is drawn from the part it holds`() throws {
        let whole = Bench.buzzing.record(Bench.sweep)
        // The sweep's last sample arrives at the delay plus its length; stop half a second before.
        let end = Int(Bench.buzzing.delaySamples) + Bench.sweep.sampleCount - Int(0.5 * Bench.sampleRate)
        let run = RunAnalyzer.analyze(recording: Array(whole[..<end]), sweep: Bench.sweep, noiseFloor: Bench.noiseFloor(rms: Bench.healthy.noiseRMS))
        guard case .valid = run.verdict, case .incomplete(let captured?) = run.record.check else {
            Issue.record("expected a valid level and an incomplete recording, got \(run.verdict), \(run.record.check)")
            return
        }
        #expect(captured.lower == Float(Bench.sweep.startFrequency))
        #expect(captured.upper < Float(Bench.sweep.endFrequency) && captured.upper > 1000, "\(captured)")
        #expect(run.measurement == nil)
        // The buzz is in this run and one good run: one good run is not enough.
        let report = SpeakerDiagnosis.diagnose(runs: [run, Self.buzzing[1], Self.healthy[2]], counterpart: nil)
        let invalid = try #require(report.findings.first)
        #expect(invalid.recordingProblem == .incomplete)
        #expect(invalid.headline == "One run was cut short")
        #expect(deviations(report).isEmpty, "\(deviations(report).map(\.headline))")
    }
}

// MARK: - What is known, from measurements made by hand

/// Runs built directly from `RunMeasurement`, so each rule of evidence is tested on exactly the reading it is about.
enum Handmade {
    static let bands = OctaveBands.centres(fraction: 1, from: 31.5, to: 16000)

    /// THD at one grid frequency: what was read, whether it is a measurement, and the noise floor.
    struct Reading {
        var percent: Float
        var measurable: Bool
        var floorPercent: Float?
    }

    /// A clean speaker's reading: 1 % over a floor of 0.05 %, measured.
    static let clean = Reading(percent: 1, measurable: true, floorPercent: 0.05)

    /// One valid run: a flat response at −12 dB measured over `responseBand` (`response` may change it), and THD
    /// from 80 Hz to 9 kHz from `thd`.
    static func run(
        responseBand: FrequencyRange? = FrequencyRange(lower: 20, upper: 20000),
        response: (Float) -> Float = { _ in -12 },
        thd: (Float) -> Reading = { _ in clean }
    ) -> RunAnalysis {
        let grid = ResponseGrid.frequencies
        let levels = grid.map(response)
        let readings: [Reading?] = grid.map { $0 >= 80 && $0 <= 9000 ? thd($0) : nil }
        let measurement = RunMeasurement(
            response: levels,
            referenceLevel: RunAnalyzer.referenceLevel(of: levels),
            responseBand: responseBand,
            thdDecibels: readings.map { $0.map { Decibels.fromAmplitude($0.percent / 100) } },
            thdMeasurable: readings.map { $0?.measurable ?? false },
            thdNoiseFloorDecibels: readings.map { $0?.floorPercent.map { Decibels.fromAmplitude($0 / 100) } },
            delay: 0.05,
            bandCentres: bands,
            bandSignalToNoise: bands.map { _ in 40 }
        )
        return RunAnalysis(verdict: .valid(level: Level(peak: 0.25, rms: 0.1, dcOffset: 0), signalToNoise: 40), measurement: measurement)
    }

    /// 15 % between 1 and 2 kHz, `measurable` or below a floor of 8 % (known only to be under 25 %); clean elsewhere.
    static func midBuzz(measurable: Bool) -> RunAnalysis {
        run(thd: { (1000...2000).contains($0) ? Reading(percent: 15, measurable: measurable, floorPercent: 8) : clean })
    }
}

@Suite struct EvidenceTests {
    @Test func `distortion over the threshold but not clear of the noise is inconclusive, never a buzz`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: (0..<3).map { _ in Handmade.midBuzz(measurable: false) }, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .distortion })
        let unclear = try #require(report.findings.first { $0.kind == .distortionUnclear })
        #expect(unclear.tag == .inconclusive)
        #expect(unclear.tagLine == "Inconclusive")
        #expect(unclear.basis.text == "3 of 3 runs")
        #expect(unclear.confidence == nil)
        #expect(unclear.headline == "Too noisy to tell at 1–2 kHz")
        #expect(unclear.detail == "Distortion read about 15 % there, but the room's noise reads nearly as high.")
        #expect(unclear.confidenceStatement.hasPrefix("Inconclusive."))
        #expect(!unclear.kind.isDeviation)
        #expect(report.verdict == "Sounds healthy.")
        // The even statement stops short of the unclear band.
        let even = try #require(report.findings.first { $0.kind == .even })
        let below = try #require(ResponseGrid.frequencies.last { $0 < 1000 })
        let from = try #require(ResponseGrid.frequencies.first { $0 >= 80 })
        #expect(even.detail == "Distortion stayed under 10 % from \(DiagnosisText.frequency(from)) to \(DiagnosisText.frequency(below)).")
    }

    @Test func `the same distortion clear of the noise is a buzz`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: (0..<3).map { _ in Handmade.midBuzz(measurable: true) }, counterpart: nil)
        let buzz = try #require(report.findings.first { $0.kind == .distortion })
        #expect(buzz.tag == .inferred && buzz.band == .middle)
        #expect(!report.findings.contains { $0.kind == .distortionUnclear })
    }

    @Test func `unclear distortion in one run of three is dropped`() {
        let runs = [Handmade.midBuzz(measurable: false), Handmade.run(), Handmade.run()]
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .distortionUnclear || $0.kind == .distortion })
    }

    @Test func `distortion below a floor that rules no buzz out is not called clean`() throws {
        // From 3 kHz up, 6 % read under a floor of 5 %: all that is known is that THD is under 16 %, which does not
        // rule a 10 % buzz out; and 6 % is under the threshold, so nothing is unclear either.
        let noisy = Handmade.Reading(percent: 6, measurable: false, floorPercent: 5)
        let runs = (0..<3).map { _ in Handmade.run(thd: { $0 >= 3000 ? noisy : Handmade.clean }) }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .distortion || $0.kind == .distortionUnclear })
        let even = try #require(report.findings.first { $0.kind == .even })
        let below = try #require(ResponseGrid.frequencies.last { $0 < 3000 })
        #expect(even.detail.hasSuffix("to \(DiagnosisText.frequency(below)).") , "\(even.detail)")
    }

    @Test func `with distortion measured nowhere, the even statement says so`() throws {
        let unknown = Handmade.Reading(percent: 3, measurable: false, floorPercent: nil)
        let report = SpeakerDiagnosis.diagnose(runs: (0..<3).map { _ in Handmade.run(thd: { _ in unknown }) }, counterpart: nil)
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.detail == "I couldn't measure distortion over the room's noise.")
        #expect(even.headline == "Tweeter, mid and woofer are even")
    }

    @Test func `nothing is raised from held values outside the measured band`() throws {
        // Measured from 100 Hz to 10 kHz only. What lies outside (a deep "dip" in the bass, a "peak" in the top) is
        // not a measurement and must raise nothing.
        let band = FrequencyRange(lower: 100, upper: 10000)
        let response: (Float) -> Float = { $0 < 60 ? -40 : ($0 > 12000 ? 0 : -12) }
        let report = SpeakerDiagnosis.diagnose(runs: (0..<3).map { _ in Handmade.run(responseBand: band, response: response) }, counterpart: nil)
        #expect(report.findings.allSatisfy { !$0.kind.isDeviation && $0.kind != .topEndDip }, "\(report.findings.map(\.headline))")
        // Woofer and tweeter were not measured whole, so only the mid is called even.
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.bands == [.middle])
        // The portrait holds the edge widths outside the band.
        let widths = report.profile.widths
        let first = try #require(ResponseGrid.frequencies.firstIndex { band.contains($0) })
        let last = try #require(ResponseGrid.frequencies.lastIndex { band.contains($0) })
        #expect(widths[..<first].allSatisfy { $0 == widths[first] })
        #expect(widths[(last + 1)...].allSatisfy { $0 == widths[last] })
        #expect(abs(widths[first] - PortraitProfile.referenceWidth) < 1e-5)
    }
}

// MARK: - Left and right

@Suite struct LeftRightTests {
    static let left = Bench.runs(Bench.healthy(with: [Biquad.peaking(frequency: 2000, q: 1.2, gain: -4, sampleRate: Bench.sampleRate)]), seed: 21, sweep: Bench.responseSweep)
    static let right = Bench.runs(Bench.healthy(with: [Biquad.peaking(frequency: 2000, q: 1.2, gain: 4, sampleRate: Bench.sampleRate)]), seed: 31, sweep: Bench.responseSweep)

    @Test func `speakers that differ are told apart, though neither deviates alone`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: Self.left, counterpart: Self.right)
        let difference = try #require(report.findings.first { $0.kind == .leftRightDifference })
        #expect(difference.tag == .inferred && difference.basis.text == "3 of 3 runs")
        #expect(isNear(try #require(difference.frequencyRange).centre, 2000))
        #expect(try #require(difference.numbers?.extreme) < -6)
        #expect(difference.detail.contains("quieter"))
        #expect(deviations(report).count == 1)
        // Without the other speaker there is nothing to compare.
        #expect(deviations(SpeakerDiagnosis.diagnose(runs: Self.left, counterpart: nil)).isEmpty)
    }

    @Test func `a difference the other speaker's own dip explains is left to that speaker's report`() {
        let dipped = Bench.runs(Bench.healthy(with: [Biquad.peaking(frequency: 2000, q: 1, gain: -9, sampleRate: Bench.sampleRate)]), seed: 41, sweep: Bench.responseSweep)
        let healthy = Bench.healthyRuns(seed: 2)
        let report = SpeakerDiagnosis.diagnose(runs: healthy, counterpart: dipped)
        #expect(deviations(report).isEmpty, "\(deviations(report).map(\.headline))")
        let other = SpeakerDiagnosis.diagnose(runs: dipped, counterpart: healthy)
        #expect(deviations(other).map(\.kind) == [.responseDip])
    }
}

// MARK: - Words

@Suite struct WordingTests {
    @Test func `frequencies are written the way the mockups write them`() {
        #expect(DiagnosisText.frequency(87.7) == "90 Hz")
        #expect(DiagnosisText.frequency(68) == "70 Hz")
        #expect(DiagnosisText.frequency(1020) == "1 kHz")
        #expect(DiagnosisText.frequency(1240) == "1.2 kHz")
        #expect(DiagnosisText.frequency(14300) == "14 kHz")
        #expect(DiagnosisText.range(FrequencyRange(lower: 68, upper: 113)) == "70–110 Hz")
        #expect(DiagnosisText.range(FrequencyRange(lower: 800, upper: 1240)) == "800 Hz–1.2 kHz")
        #expect(DiagnosisText.range(FrequencyRange(lower: 1240, upper: 3020)) == "1.2–3 kHz")
    }

    @Test func `no finding states a defect as confirmed, and nothing is a score`() {
        let reports = [
            DistortionTests.threeOfThree,
            SpeakerDiagnosis.diagnose(runs: LeftRightTests.left, counterpart: LeftRightTests.right),
        ]
        let forbidden = ["is broken", "is faulty", "is damaged", "confirmed", "score", "%/100", "out of 10"]
        for report in reports {
            let texts = [report.verdict] + report.findings.flatMap { [$0.headline, $0.detail, $0.sentence, $0.confidenceStatement] }
            for text in texts {
                for word in forbidden { #expect(!text.lowercased().contains(word), "\(text)") }
            }
            for finding in report.findings where finding.kind.isDeviation {
                #expect(finding.tag == .inferred)
                #expect(finding.confidence != .high)
                #expect(finding.confidenceStatement.hasPrefix("Inferred"))
            }
        }
        #expect(DistortionTests.threeOfThree.verdict.contains("may be"))
    }

    @Test func `a report survives being stored`() throws {
        let report = DistortionTests.threeOfThree
        let decoded = try JSONDecoder().decode(SpeakerReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
    }
}
