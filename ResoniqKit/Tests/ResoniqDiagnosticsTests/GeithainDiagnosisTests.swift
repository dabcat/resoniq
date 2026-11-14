import AVFoundation
import Foundation
import ResoniqDSP
import Synchronization
import Testing
@testable import ResoniqDiagnostics

/// The Geithain RL900A sweeps (see `GeithainSweeps` in ResoniqDSPTests; a test target cannot be imported), fed to the
/// diagnosis as the app would: three measurements of one speaker at one microphone are three runs, each analysed by
/// `RunAnalyzer` against that microphone's recording of the room alone. Present only when the data is at
/// `data/geithain-sweeps/`; skipped otherwise.
enum GeithainRuns {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("data/geithain-sweeps/measurements_without_static_noise")

    static func output(_ index: Int) -> URL { folder.appendingPathComponent("output_files/OUTPUT_\(index).flac") }
    static func silence(_ index: Int) -> URL {
        let own = folder.appendingPathComponent("silence_recordings/SILENCE_\(index).flac")
        return FileManager.default.fileExists(atPath: own.path) ? own : folder.appendingPathComponent("silence_recordings/SILENCE_0.flac")
    }

    /// One group: three 4 s measurements of one speaker at the same drive (a peak of 0.5), the label for the report.
    struct Group: Sendable, CustomTestStringConvertible {
        let label: String
        let indices: [Int]
        var testDescription: String { label }
    }

    /// The first two speakers, clean, with an impulse during the sweep and with birdsong. The third channel's unit
    /// reads as distorting (see `GeithainHighOrderTests`) and is not a healthy reference.
    static let healthy: [Group] = [
        Group(label: "speaker 0, clean", indices: [0, 2, 4]),
        Group(label: "speaker 0, impulse", indices: [48, 50, 52]),
        Group(label: "speaker 0, birdsong", indices: [96, 98, 100]),
        Group(label: "speaker 1, clean", indices: [720, 722, 724]),
        Group(label: "speaker 1, impulse", indices: [768, 770, 772]),
        Group(label: "speaker 1, birdsong", indices: [816, 818, 820]),
    ]
    static let microphones = [0, 3]

    static var isAvailable: Bool {
        (healthy.flatMap(\.indices) + [1440, 1442, 1444]).allSatisfy { FileManager.default.fileExists(atPath: output($0).path) }
            && FileManager.default.fileExists(atPath: silence(0).path)
    }

    /// The played sweep: 50 Hz to 22 kHz over 4 s, half a second into each file (fitted in ResoniqDSPTests).
    static let sweep = LogSweep(startFrequency: 50, endFrequency: 22000, duration: 4, sampleRate: 48000)

    static func channel(_ url: URL, _ channel: Int) throws -> [Float] {
        struct Unreadable: Error {}
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData
        else { throw Unreadable() }
        return Array(UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
    }

    /// The runs of `indices` at `mic`, analysed side by side.
    static func runs(_ indices: [Int], mic: Int) -> [RunAnalysis] {
        let results = Mutex([Int: RunAnalysis]())
        DispatchQueue.concurrentPerform(iterations: indices.count) { position in
            let index = indices[position]
            guard let recording = try? channel(output(index), mic), let quiet = try? channel(silence(index), mic) else { return }
            let analysis = RunAnalyzer.analyze(recording: recording, sweep: sweep, noiseFloor: floor(quiet))
            if analysis.isValid == false { print("Geithain \(index) mic \(mic): \(analysis.verdict)") }
            results.withLock { $0[position] = analysis }
        }
        return results.withLock { all in indices.indices.compactMap { all[$0] } }
    }

    /// The floor as the app measures it: one second of the room alone, the first steady one of the ten recorded (the
    /// app measures again when the room is not steady). The whole ten seconds is never steady: something in the room
    /// rises more than the steadiness threshold over the median at some moment.
    static func floor(_ quiet: [Float]) -> NoiseFloorReport {
        let second = 48000
        let floors = stride(from: 0, through: quiet.count - second, by: second).map {
            NoiseFloor.measure(Array(quiet[$0..<($0 + second)]), sampleRate: 48000)
        }
        return floors.first(where: \.isSteady) ?? floors[0]
    }

    static func describe(_ report: SpeakerReport) -> String {
        "\(report.verdict) — " + report.findings.map { "\($0.kind.rawValue): \($0.headline) [\($0.tagLine)]" }.joined(separator: "; ")
    }
}

@Suite(.enabled(if: GeithainRuns.isAvailable, "the Geithain sweeps are not in data/geithain-sweeps/"))
struct GeithainDiagnosisTests {
    @Test(arguments: GeithainRuns.healthy)
    func `healthy monitors in a real room raise no rub or buzz`(_ group: GeithainRuns.Group) throws {
        for mic in GeithainRuns.microphones {
            let runs = GeithainRuns.runs(group.indices, mic: mic)
            #expect(runs.count == 3)
            let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
            print("Geithain \(group.label), mic \(mic): \(GeithainRuns.describe(report))")
            #expect(!report.findings.contains { $0.kind == .highOrderDistortion }, "\(GeithainRuns.describe(report))")
            #expect(!report.findings.contains { $0.highOrder != nil })
        }
    }

    /// The third channel's unit, for the record: what the diagnosis says of it.
    @Test func `the third channel's unit, as the diagnosis reads it`() {
        let runs = GeithainRuns.runs([1440, 1442, 1444], mic: 0)
        let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil)
        print("Geithain speaker 2, clean, mic 0: \(GeithainRuns.describe(report))")
        #expect(report.findings.contains { $0.kind == .distortion || $0.kind == .highOrderDistortion })
    }
}
