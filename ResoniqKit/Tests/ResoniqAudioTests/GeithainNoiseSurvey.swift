import AVFoundation
import Foundation
import ResoniqDSP
import Synchronization
import Testing
@testable import ResoniqAudio

/// A measurement, not a check: what the session's noise detector (`SweepNoiseDetector`, the part of the session that
/// pauses a run) makes of the Geithain RL900A recordings, block by block, for the research note
/// `docs/research/2026-11-14-healthy-speakers-real-room.md`. Only the detector is run, on the files: not the session's
/// pausing, resuming, splicing or repeating, which need the live capture.
///
/// It runs only when `RESONIQ_GEITHAIN_SURVEY` is set and the data is at `data/geithain-sweeps/`, so `make test` skips
/// it; `RESONIQ_GEITHAIN_LENGTHS`, `RESONIQ_GEITHAIN_SPEAKERS` and `RESONIQ_GEITHAIN_SURVEY_OUT` choose the sample and
/// the folder as for `GeithainSurvey` in ResoniqDiagnosticsTests. Run it optimised:
/// `RESONIQ_GEITHAIN_SURVEY=1 swift test --package-path ResoniqKit -c release -Xswiftc -enable-testing --filter GeithainNoiseSurvey`.
enum GeithainNoiseSurvey {
    static let environment = ProcessInfo.processInfo.environment
    static let data = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("data/geithain-sweeps/measurements_without_static_noise")

    static var isEnabled: Bool {
        environment["RESONIQ_GEITHAIN_SURVEY"] != nil
            && FileManager.default.fileExists(atPath: data.appendingPathComponent("playlist.csv").path)
    }

    static func list(_ name: String, default value: [Int]) -> [Int] {
        environment[name].map { $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } } ?? value
    }

    static var outputFolder: URL {
        if let path = environment["RESONIQ_GEITHAIN_SURVEY_OUT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/geithain-survey")
    }

    static func output(_ index: Int) -> URL { data.appendingPathComponent("output_files/OUTPUT_\(index).flac") }
    static func silence(_ index: Int) -> URL {
        let own = data.appendingPathComponent("silence_recordings/SILENCE_\(index).flac")
        return FileManager.default.fileExists(atPath: own.path) ? own : data.appendingPathComponent("silence_recordings/SILENCE_0.flac")
    }

    static func channels(_ url: URL) throws -> [[Float]] {
        struct Unreadable: Error {}
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData
        else { throw Unreadable() }
        let count = Int(buffer.frameLength)
        return (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: count)) }
    }

    /// The floor the session would build its detector on: the first steady second of the room alone (as
    /// `GeithainRuns.floor` takes it).
    static func floorSamples(_ quiet: [Float]) -> [Float] {
        let second = 48000
        let pieces = stride(from: 0, through: quiet.count - second, by: second).map { Array(quiet[$0..<($0 + second)]) }
        return pieces.first { NoiseFloor.measure($0, sampleRate: 48000).isSteady } ?? pieces[0]
    }

    struct Out: Codable {
        let index: Int
        let mic: Int
        let speaker: Int
        let length: Int
        let noise: String
        let noiseChannel: Int
        let interval: String
        let noiseLevel: Double
        /// Blocks (0.1 s) from the sweep's start to its end, plus half a second for the route and the room.
        let sweepBlocks: Int
        /// Of those, the blocks the detector called too noisy, and the first one's time from the sweep's start, seconds.
        let noisyBlocks: Int
        let firstNoisy: Double?
        /// The sweep frequency the detector found in the first noisy block, hertz.
        let firstNoisyFrequency: Double?
        /// The largest rise of the room's bins over the floor's during the sweep, dB.
        let maximumRise: Float
        /// Blocks after that to the end of the file, and how many were too noisy.
        let tailBlocks: Int
        let noisyTailBlocks: Int
        /// Every too-noisy block during the sweep: its time from the sweep's start (s), the sweep frequency the detector
        /// found in it (0 when none stood out) and its rise (dB).
        let noisy: [[Double]]
    }
}

@Suite(.enabled(if: GeithainNoiseSurvey.isEnabled, "set RESONIQ_GEITHAIN_SURVEY, with the Geithain sweeps in data/geithain-sweeps/"))
struct GeithainNoiseSurveyTests {
    @Test func `the noise detector on the healthy monitors' recordings`() throws {
        let text = try String(contentsOf: GeithainNoiseSurvey.data.appendingPathComponent("playlist.csv"), encoding: .utf8)
        let lengths = GeithainNoiseSurvey.list("RESONIQ_GEITHAIN_LENGTHS", default: [4])
        let speakers = GeithainNoiseSurvey.list("RESONIQ_GEITHAIN_SPEAKERS", default: [0, 1, 2])
        let rows = text.split(whereSeparator: \.isNewline).dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            .filter { lengths.contains(Int($0[2])!) && speakers.contains(Int($0[1])!) }
        let folder = GeithainNoiseSurvey.outputFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("noise-detector.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let lock = Mutex(())
        let floors = Mutex([String: [[Float]]]())
        let encoder = JSONEncoder()
        let block = 4800

        DispatchQueue.concurrentPerform(iterations: rows.count) { position in
            let field = rows[position]
            let index = Int(field[0])!
            let length = Int(field[2])!
            let sweep = LogSweep(startFrequency: 50, endFrequency: 22000, duration: Double(length), sampleRate: 48000)
            let silenceURL = GeithainNoiseSurvey.silence(index)
            let quiet: [[Float]]
            if let known = floors.withLock({ $0[silenceURL.path] }) {
                quiet = known
            } else {
                guard let all = try? GeithainNoiseSurvey.channels(silenceURL) else { return }
                quiet = (0..<7).map { GeithainNoiseSurvey.floorSamples(all[$0]) }
                floors.withLock { $0[silenceURL.path] = quiet }
            }
            guard let recording = try? GeithainNoiseSurvey.channels(GeithainNoiseSurvey.output(index)) else { return }
            for mic in 0..<7 {
                let detector = SweepNoiseDetector(noiseFloor: quiet[mic], sweep: sweep, blockLength: block)
                let samples = recording[mic]
                let start = 24000
                let sweepEnd = start + Int(Double(length) * 48000) + 24000
                var noisy = 0, tail = 0, noisyTail = 0, blocks = 0
                var first: Double?
                var firstFrequency: Double?
                var rise: Float = -.infinity
                var list: [[Double]] = []
                var offset = start
                while offset + block <= samples.count {
                    let assessment = detector.assess(Array(samples[offset..<(offset + block)]))
                    if offset < sweepEnd {
                        blocks += 1
                        rise = max(rise, assessment.riseDecibels)
                        if assessment.isTooNoisy {
                            noisy += 1
                            list.append([Double(offset - start) / 48000, assessment.sweepFrequency ?? 0, Double(assessment.riseDecibels)])
                            if first == nil {
                                first = Double(offset - start) / 48000
                                firstFrequency = assessment.sweepFrequency
                            }
                        }
                    } else {
                        tail += 1
                        if assessment.isTooNoisy { noisyTail += 1 }
                    }
                    offset += block
                }
                let file = field[3]
                let out = GeithainNoiseSurvey.Out(
                    index: index, mic: mic, speaker: Int(field[1])!, length: length,
                    noise: file.isEmpty ? "clean" : file.contains("impulse") ? "impulse" : "birds",
                    noiseChannel: Int(field[4])!, interval: field[5], noiseLevel: Double(field[6])!,
                    sweepBlocks: blocks, noisyBlocks: noisy, firstNoisy: first, firstNoisyFrequency: firstFrequency,
                    maximumRise: rise, tailBlocks: tail, noisyTailBlocks: noisyTail, noisy: list
                )
                guard var data = try? encoder.encode(out) else { continue }
                data.append(0x0A)
                lock.withLock { _ in handle.write(data) }
            }
        }
    }
}
