import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

/// The level reading the Listening and Three spots screens show, the paused screen's interference line, and what
/// a speaker report's response may draw.
@Suite struct ReadingTests {
    static let quietPeak = QualityThresholds.standard.minimumPeakDecibels - 1
    static let healthyPeak = QualityThresholds.standard.minimumPeakDecibels + 10

    @Test func `the input level: clipping, too quiet only above the woofer, otherwise good`() {
        #expect(InputLevel(isClipping: true, frequency: 1000, peakDecibels: Self.quietPeak) == .tooLoud)
        #expect(InputLevel(isClipping: false, frequency: 1000, peakDecibels: Self.quietPeak) == .tooQuiet)
        // Under the woofer's upper edge a speaker may be rolling off: not judged.
        #expect(InputLevel(isClipping: false, frequency: 200, peakDecibels: Self.quietPeak) == .good)
        #expect(InputLevel(isClipping: false, frequency: 300, peakDecibels: Self.quietPeak) == .good)
        #expect(InputLevel(isClipping: false, frequency: nil, peakDecibels: Self.quietPeak) == .good)
        #expect(InputLevel(isClipping: false, frequency: 1000, peakDecibels: Self.healthyPeak) == .good)
    }

    @Test func `a level that is not good says what to do, and a good one says nothing`() {
        #expect(InputLevel.good.advice == nil)
        #expect(InputLevel.tooQuiet.advice == "Turn the volume up or hold the phone closer.")
        #expect(InputLevel.tooLoud.advice == "Turn the volume down a little.")
    }

    @Test func `its words, long for Listening and short for Three spots`() {
        #expect(InputLevel.good.label == "Good, no clipping")
        #expect(InputLevel.tooQuiet.label == "Too quiet")
        #expect(InputLevel.tooLoud.label == "Too loud, clipping")
        #expect(InputLevel.good.shortLabel == "Good")
        #expect(InputLevel.tooQuiet.shortLabel == "Too quiet")
        #expect(InputLevel.tooLoud.shortLabel == "Too loud")
    }

    @Test func `the paused screen's line names the noise, with its tag, or says nothing`() async {
        let talking = StubClassifier(result: .success(windows([[("speech", 0.82)]])))
        let note = await InterferenceAdvisor.note(heard: [0], sampleRate: 48000, sweepPlaying: false, classifier: talking)
        #expect(note == InterferenceNote(sentence: "It sounds like someone talking.", tagLine: "Inferred · sound classifier, 82 %"))
        // Music while the sweep plays may be the sweep itself.
        let music = StubClassifier(result: .success(windows([[("music", 0.9)]])))
        #expect(await InterferenceAdvisor.note(heard: [0], sampleRate: 48000, sweepPlaying: true, classifier: music) == nil)
        #expect(await InterferenceAdvisor.note(heard: [0], sampleRate: 48000, sweepPlaying: false, classifier: music)?.sentence != nil)
        let failing = StubClassifier(result: .failure(.init()))
        #expect(await InterferenceAdvisor.note(heard: [0], sampleRate: 48000, sweepPlaying: false, classifier: failing) == nil)
    }

    @Test func `a speaker report draws its response only where every run measured it`() throws {
        let narrow = (0..<3).map { _ in Handmade.run(responseBand: FrequencyRange(lower: 40, upper: 16000)) }
        let report = SpeakerDiagnosis.diagnose(runs: narrow, counterpart: nil)
        let drawn = try #require(report.drawableResponse)
        let grid = ResponseGrid.frequencies
        for index in drawn.indices {
            #expect((drawn[index] != nil) == (grid[index] >= 40 && grid[index] <= 16000))
        }
        let full = SpeakerDiagnosis.diagnose(runs: (0..<3).map { _ in Handmade.run() }, counterpart: nil)
        #expect(full.drawableResponse?.allSatisfy { $0 != nil } == true)
        let none = SpeakerDiagnosis.diagnose(runs: [Bench.clippedRun], counterpart: nil)
        #expect(none.drawableResponse == nil)
    }
}
