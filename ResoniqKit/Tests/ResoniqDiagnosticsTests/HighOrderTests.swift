import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

/// `run` with the level above the tenth harmonic set by hand from 40 Hz to 1.7 kHz: `level(f)` gives what was read in
/// dB re the tone, whether it is a measurement, and the floor.
func withHighOrder(_ run: RunAnalysis, _ level: (Float) -> (decibels: Float, measurable: Bool, floor: Float?)) -> RunAnalysis {
    let m = run.measurement!
    let readings = ResponseGrid.frequencies.map { $0 >= 40 && $0 <= 1700 ? level($0) : nil }
    let measurement = RunMeasurement(
        response: m.response, referenceLevel: m.referenceLevel, responseBand: m.responseBand,
        thdDecibels: m.thdDecibels, thdMeasurable: m.thdMeasurable, thdNoiseFloorDecibels: m.thdNoiseFloorDecibels,
        delay: m.delay, bandCentres: m.bandCentres, bandSignalToNoise: m.bandSignalToNoise,
        highOrderDecibels: readings.map { $0?.decibels },
        highOrderMeasurable: readings.map { $0?.measurable ?? false },
        highOrderNoiseFloorDecibels: readings.map { $0?.floor }
    )
    return RunAnalysis(verdict: run.verdict, measurement: measurement).adding(sweepTiedSound: run.record.sweepTiedSound)
}

/// A clean reading: −70 dB re the tone, measured over a floor of −85 dB.
func cleanHighOrder(_: Float) -> (decibels: Float, measurable: Bool, floor: Float?) { (-70, true, -85) }

/// −35 dB, measured, inside `range`; clean elsewhere.
func highOrder(at range: ClosedRange<Float>) -> (Float) -> (decibels: Float, measurable: Bool, floor: Float?) {
    { range.contains($0) ? (-35, true, -85) : (-70, true, -85) }
}

@Suite struct HighOrderFindingTests {
    static let rubbingRuns = Bench.runs(Bench.rubbing)

    @Test func `the threshold is one definition, between the borderline and the bad recording`() {
        #expect(DiagnosisThresholds.standard.highOrderDecibels == -50)
        #expect(DiagnosisThresholds.standard.highOrderLowerFrequency == 80)
        #expect(DiagnosisThresholds.standard.highOrderDecibels > -59.4 && DiagnosisThresholds.standard.highOrderDecibels < -40.3)
    }

    @Test func `a simulated rub with low THD is a hedged, inferred rub or buzz finding`() throws {
        let runs = Self.rubbingRuns
        let measurement = try #require(runs[0].measurement)
        for frequency: Float in [70, 90, 110] {
            let index = ResponseGrid.nearestIndex(to: frequency)
            print("rubbing at \(frequency) Hz: \(measurement.highOrder(atIndex: index)), THD \(measurement.distortion(atIndex: index))")
        }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .distortion }, "THD stays low: no buzz from THD")
        let rub = try #require(report.findings.first { $0.kind == .highOrderDistortion }, "\(report.findings.map(\.headline))")
        let range = try #require(rub.frequencyRange)
        print("rub finding: \(rub.headline) — \(rub.detail) [\(rub.numbers!.extreme) dB]")
        // Looked for from 80 Hz (`highOrderLowerFrequency`), though the rub starts at 60 Hz, as THD is.
        #expect(range.lower >= 79 && range.lower < 85 && range.upper > 100 && range.upper < 160)
        #expect(rub.headline == "Possible rub or buzz at 80–120 Hz")
        #expect(rub.tag == .inferred)
        #expect(rub.basis.text == "3 of 3 runs")
        #expect(rub.confidence == .medium)
        #expect(rub.kind.isDeviation && rub.isSuspectedDefect)
        #expect(rub.headline.hasPrefix("Possible rub or buzz at "))
        #expect(rub.sentence.hasPrefix("A possible rub or buzz around "))
        #expect(rub.detail.hasPrefix("Above the tone's tenth harmonic it read about "))
        #expect(rub.detail.contains("Ordinary distortion stayed under 10 % there"))
        #expect(rub.confidenceStatement == "Inferred, medium confidence. It repeats every run, but from one microphone position I can't tell the speaker from something near the speaker buzzing along, such as a loose panel or an object on the shelf.")
        let numbers = try #require(rub.numbers)
        #expect(numbers.unit == .toneDecibels)
        #expect(numbers.threshold == -50)
        #expect(numbers.extreme > -40)
        #expect(numbers.perRun.allSatisfy { $0 != nil })
        #expect(report.verdict == "Sounds healthy, except the woofer may be rubbing or buzzing.")
        // It blocks the even statement for the woofer.
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(!even.bands.contains(.woofer))
        // Never stated as a confirmed defect.
        for line in [rub.headline, rub.detail, rub.sentence, report.verdict] {
            #expect(!line.contains("is rubbing") && !line.contains("is broken") && !line.contains("defect"))
        }
    }

    @Test func `in one run only it is dropped`() {
        let runs = Bench.runs(Bench.rubbing, seed: 3) { index, speaker in if index > 0 { speaker.rub = nil } }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .highOrderDistortion })
    }

    @Test func `in two of three runs it is low confidence and names what else would read the same`() throws {
        let runs = Bench.runs(Bench.rubbing, seed: 4) { index, speaker in if index == 1 { speaker.rub = nil } }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        let rub = try #require(report.findings.first { $0.kind == .highOrderDistortion })
        #expect(rub.basis.text == "2 of 3 runs")
        #expect(rub.confidence == .low)
        #expect(rub.confidenceStatement == "Inferred, low confidence. It showed in 2 of 3 runs, so it may have been a sound in the room, or something near the speaker buzzing along, such as a loose panel or an object on the shelf.")
        #expect(rub.numbers?.perRun[1] == nil)
    }

    /// The worst failure is a false alarm: a healthy speaker in a room loud enough to just pass the recording check
    /// reads its noise above the tenth harmonic, and that is never a finding.
    @Test(arguments: [UInt64(11), 12, 13, 14])
    func `a healthy speaker in a noisy room raises nothing`(seed: UInt64) {
        let runs = Bench.runs(Bench.noisy(Bench.healthy, signalToNoise: 20), seed: seed)
        #expect(runs.allSatisfy { $0.isValid })
        print("healthy at 20 dB, seed \(seed), at 100 Hz: \(runs[0].measurement!.highOrder(atIndex: ResponseGrid.nearestIndex(to: 100)))")
        for run in runs {
            let measurement = run.measurement!
            let measuredOver = ResponseGrid.frequencies.indices.contains { index in
                if case .measured(let level) = measurement.highOrder(atIndex: index) { return level >= -50 }
                return false
            }
            #expect(!measuredOver)
        }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .highOrderDistortion })
        #expect(deviations(report).isEmpty, "\(deviations(report).map(\.headline))")
        #expect(report.verdict == "Sounds healthy.")
    }

    /// A steady noise that starts after the floor was measured (a fridge, a fan, a kettle) and lasts through the runs
    /// raises the band above the tenth harmonic in every frame. The floor measured before the runs does not see it; the
    /// run's own tail does, and it is never a rub.
    static let noiseAfterFloorCases: [HealthyCase] = [
        HealthyCase(seed: 21, signalToNoise: 20), HealthyCase(seed: 22, signalToNoise: 25),
        HealthyCase(seed: 23, signalToNoise: 30), HealthyCase(seed: 24, signalToNoise: 35),
    ]

    @Test(arguments: noiseAfterFloorCases)
    func `steady noise that started after the floor was measured raises no rub or buzz`(_ item: HealthyCase) {
        var speaker = Bench.noisy(Bench.healthy, signalToNoise: item.signalToNoise!)
        speaker.floorRMS = Bench.healthy.noiseRMS
        let runs = Bench.runs(speaker, seed: item.seed)
        let measurement = runs[0].measurement!
        print("noise after the floor, \(item): at 100 Hz \(measurement.highOrder(atIndex: ResponseGrid.nearestIndex(to: 100)))")
        for run in runs {
            guard let measurement = run.measurement else { continue }
            for index in ResponseGrid.frequencies.indices {
                if case .measured(let level) = measurement.highOrder(atIndex: index) { #expect(level < -50, "\(ResponseGrid.frequencies[index]) Hz") }
            }
        }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .highOrderDistortion }, "\(report.findings.map(\.headline))")
    }

    @Test(arguments: [UInt64(31), 32])
    func `steady noise in two of three runs raises no rub or buzz`(seed: UInt64) {
        let runs = Bench.runs(Bench.healthy, seed: seed) { index, speaker in
            guard index < 2 else { return }
            speaker = Bench.noisy(speaker, signalToNoise: 25)
            speaker.floorRMS = Bench.healthy.noiseRMS
        }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .highOrderDistortion }, "\(report.findings.map(\.headline))")
    }

    @Test(arguments: HealthySpeakerTests.allCases)
    func `a healthy speaker never reads a measured level over the threshold`(_ item: HealthyCase) {
        for run in Bench.healthyRuns[item]! {
            let measurement = run.measurement!
            #expect(measurement.highOrderDecibels != nil)
            for index in ResponseGrid.frequencies.indices {
                if case .measured(let level) = measurement.highOrder(atIndex: index) { #expect(level < -50) }
            }
        }
    }

    @Test func `where noise hid the high orders the even statement says they weren't checked`() throws {
        let runs = Bench.healthyRuns(seed: 1)
        let measurement = try #require(runs[0].measurement)
        for frequency: Float in [100, 1000] {
            print("healthy, quiet room, at \(frequency) Hz: \(measurement.highOrder(atIndex: ResponseGrid.nearestIndex(to: frequency)))")
        }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.detail.hasSuffix(" I couldn't check for rub or buzz over the room's noise."), "\(even.detail)")
        #expect(!even.detail.contains("no sign of rub"))
    }

    @Test func `where every run read them clean the even statement names that stretch, and only it`() throws {
        let runs = (0..<3).map { _ in withHighOrder(Handmade.run(), cleanHighOrder) }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.detail.hasSuffix(" I found no sign of rub or buzz from 80 Hz to 1.7 kHz."), "\(even.detail)")
    }

    @Test func `a record stored without the high orders says nothing about them`() throws {
        let report = SpeakerDiagnosis.diagnose(runs: (0..<3).map { _ in Handmade.run() }, counterpart: nil)
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(!even.detail.contains("rub or buzz"))
    }

    @Test func `a level over the threshold that did not stand clear of the noise is never a finding`() {
        let runs = (0..<3).map { _ in withHighOrder(Handmade.run()) { (100...200).contains($0) ? (-35, false, -38) : (-70, true, -85) } }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .highOrderDistortion })
        #expect(report.verdict == "Sounds healthy.")
    }

    @Test func `hand-made, it reads as a rub or buzz with its numbers`() throws {
        let runs = (0..<3).map { _ in withHighOrder(Handmade.run(), highOrder(at: 100...200)) }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        let rub = try #require(report.findings.first { $0.kind == .highOrderDistortion })
        #expect(rub.headline == "Possible rub or buzz at 100–200 Hz")
        #expect(rub.detail == "Above the tone's tenth harmonic it read about 35 dB under the tone around \(DiagnosisText.frequency(rub.numbers!.extremeFrequency)). Ordinary distortion stayed under 10 % there; a rub or buzz shows in these higher overtones first.")
        #expect(rub.sentence == "A possible rub or buzz around 140 Hz.")
        #expect(rub.numbers?.extreme == -35)
        #expect(report.verdict == "Sounds healthy, except the woofer may be rubbing or buzzing.")
    }

    @Test func `over a measured buzz it is that buzz's further evidence, not a second finding`() throws {
        let runs = (0..<3).map { _ in withHighOrder(Handmade.midBuzz(measurable: true), highOrder(at: 1000...1600)) }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .highOrderDistortion })
        let buzz = try #require(report.findings.first { $0.kind == .distortion })
        let evidence = try #require(buzz.highOrder)
        #expect(evidence.runsMeasured == 3 && evidence.runsCompared == 3)
        #expect(evidence.extreme == -35)
        #expect(evidence.statement == "Above the tone's tenth harmonic it read about 35 dB under the tone there too, in 3 of 3 runs.")
        #expect(buzz.detail.hasSuffix(" " + evidence.statement))
    }

    @Test func `over a possible rattle it is that rattle's further evidence, not a second finding`() throws {
        let runs = (0..<3).map { _ in withHighOrder(Handmade.run(), highOrder(at: 150...300)).adding(sweepTiedSound: rattleBand) }
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        #expect(!report.findings.contains { $0.kind == .highOrderDistortion })
        let rattle = try #require(report.findings.first { $0.kind == .rattle })
        #expect(rattle.highOrder?.runsMeasured == 3)
        #expect(rattle.detail.hasSuffix("in 3 of 3 runs."))
    }

    @Test func `a measurement without the high orders is stored as before, and one with them round-trips`() throws {
        let plain = try #require(Handmade.run().measurement)
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("highOrder"))
        let decoded = try JSONDecoder().decode(RunMeasurement.self, from: Data(json.utf8))
        #expect(decoded == plain)
        #expect(decoded.highOrder(atIndex: ResponseGrid.nearestIndex(to: 100)) == .notRead)

        let rich = try #require(Self.rubbingRuns[0].measurement)
        let again = try JSONDecoder().decode(RunMeasurement.self, from: try JSONEncoder().encode(rich))
        #expect(again == rich)
    }
}
