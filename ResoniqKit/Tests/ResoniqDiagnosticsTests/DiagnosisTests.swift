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
    static let seeds: [UInt64] = [1, 2, 3, 4, 5, 6]

    @Test(arguments: seeds)
    func `a healthy speaker gives no deviation findings`(seed: UInt64) {
        let report = SpeakerDiagnosis.diagnose(runs: Bench.healthyRunsBySeed[seed]!, counterpart: nil)
        #expect(deviations(report).isEmpty, "\(deviations(report).map(\.headline))")
        #expect(report.verdict == "Sounds healthy.")
        #expect(!report.findings.contains { $0.tag == .inferred })
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
            for run in Bench.healthyRunsBySeed[seed]! {
                let measurement = try! #require(run.measurement)
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
        let report = SpeakerDiagnosis.diagnose(runs: Bench.healthyRunsBySeed[1]!, counterpart: nil)
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.tag == .measured)
        #expect(even.bands == [.tweeter, .middle, .woofer])
        #expect(even.headline == "Tweeter, mid and woofer are even")
        #expect(even.detail == "No distortion or rattle found.")
        #expect(even.tagLine == "Measured")
        #expect(even.basis == Finding.Basis(runsAgreeing: 3, runsCompared: 3))
    }
}

// MARK: - Distortion: the rule of repetition

@Suite struct DistortionTests {
    static let threeOfThree = SpeakerDiagnosis.diagnose(runs: Bench.buzzingRuns, counterpart: nil)
    static let buzzing = Bench.buzzingRuns
    static let healthy = Bench.healthyRunsBySeed[1]!

    @Test func `a buzz in 3 of 3 runs is inferred with the basis "3 of 3 runs"`() throws {
        let buzz = try #require(Self.threeOfThree.findings.first { $0.kind == .distortion })
        #expect(buzz.tag == .inferred)
        #expect(buzz.basis.runsAgreeing == 3 && buzz.basis.runsCompared == 3)
        #expect(buzz.basis.text == "3 of 3 runs")
        #expect(buzz.confidence == .medium)
        #expect(buzz.band == .woofer)
        let range = try #require(buzz.frequencyRange)
        #expect(isNear(range.lower, 70) && isNear(range.upper, 110), "\(range)")
        #expect(deviations(Self.threeOfThree).count == 1, "\(deviations(Self.threeOfThree).map(\.headline))")
    }

    @Test func `the buzz reads as the mockups show it`() throws {
        let report = Self.threeOfThree
        let buzz = try #require(report.findings.first { $0.kind == .distortion })
        #expect(buzz.headline == "Buzz at 70–110 Hz")
        #expect(buzz.tagLine == "Inferred · 3 of 3 runs")
        #expect(buzz.sentence == "A buzz around 90 Hz.")
        #expect(buzz.confidenceStatement == "Inferred, medium confidence. It repeats every run, but from one microphone position I can't rule out something near the speaker vibrating.")
        #expect(buzz.repeatability == "Same place every time")
        #expect(buzz.listenFrequency == 90)
        #expect(report.verdict == "Sounds healthy, except the woofer may be buzzing.")
        let even = try #require(report.findings.first { $0.kind == .even })
        #expect(even.headline == "Tweeter and mid are even")
        #expect(even.detail == "No distortion or rattle found.")
        #expect(even.tagLine == "Measured")
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
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker), counterpart: nil)
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
        let report = SpeakerDiagnosis.diagnose(runs: Bench.runs(speaker), counterpart: nil)
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
        #expect(report.findings.map(\.headline) == ["Very top notes dip", "Tweeter and mid are even", "Buzz at 70–110 Hz"])
        #expect(report.findings.map(\.detail).first == "Above 14 kHz. Could be the phone's angle.")
    }
}

// MARK: - Recordings that cannot be used

@Suite struct InvalidRecordingTests {
    static let buzzing = Bench.buzzingRuns
    static let healthy = Bench.healthyRunsBySeed[1]!

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
}

// MARK: - Left and right

@Suite struct LeftRightTests {
    static let left = Bench.runs(Bench.healthy(with: [Biquad.peaking(frequency: 2000, q: 1.2, gain: -4, sampleRate: Bench.sampleRate)]), seed: 21)
    static let right = Bench.runs(Bench.healthy(with: [Biquad.peaking(frequency: 2000, q: 1.2, gain: 4, sampleRate: Bench.sampleRate)]), seed: 31)

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
        let dipped = Bench.runs(Bench.healthy(with: [Biquad.peaking(frequency: 2000, q: 1, gain: -9, sampleRate: Bench.sampleRate)]), seed: 41)
        let healthy = Bench.healthyRunsBySeed[2]!
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
