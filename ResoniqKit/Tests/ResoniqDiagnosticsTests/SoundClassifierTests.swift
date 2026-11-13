#if canImport(SoundAnalysis)
import AVFoundation
import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

/// Test signals at 48 kHz, 4 s each.
enum ClassifierSignals {
    static let sampleRate = 48000.0
    static let count = Int(4 * sampleRate)

    /// White noise at −23 dBFS RMS: what a quiet room's hiss is not, but a steady broadband sound is.
    static let noise: [Float] = {
        var generator = SeededGenerator(state: 7)
        return generator.noise(count: count, rms: 0.07).map(Float.init)
    }()

    /// Eight notes of half a second, each with six harmonics and a decay: a simple piano-like tune.
    static let music: [Float] = {
        let notes: [Double] = [261.6, 329.6, 392.0, 523.3, 392.0, 329.6, 293.7, 349.2]
        var music = [Float](repeating: 0, count: count)
        for (note, frequency) in notes.enumerated() {
            let start = Int(Double(note) * 0.5 * sampleRate)
            for index in 0..<Int(0.5 * sampleRate) where start + index < count {
                let time = Double(index) / sampleRate
                var value = 0.5 * sin(2 * .pi * frequency / 2 * time)
                for harmonic in 1...6 { value += sin(2 * .pi * frequency * Double(harmonic) * time) / Double(harmonic * harmonic) }
                music[start + index] += Float(0.2 * value * exp(-3 * time))
            }
        }
        return music
    }()

    /// A clean run of the app's measurement sweep (10 Hz–22 kHz, 4 s) through the simulated healthy speaker, as the
    /// microphone records it.
    static let sweepRecording: [Float] = Bench.healthy.record(LogSweep.measurement(sampleRate: sampleRate))

    /// A synthetic voice from the Mac's `say`, 48 kHz float; nil where it cannot be made.
    static let speech: [Float]? = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resoniq-speech-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--data-format=LEF32@48000",
                             "Could you turn the television down for a moment? I am measuring the speakers in the living room."]
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0], buffer.frameLength > 0
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }()
}

/// Prints each window's top labels, for the record of what the classifier really said.
private func log(_ name: String, _ labels: [SoundClassification], seconds: Double) {
    let windows = Dictionary(grouping: labels, by: \.start).sorted { $0.key < $1.key }
    print("[SoundClassifier] \(name): \(windows.count) windows in \(String(format: "%.3f", seconds)) s")
    for (start, window) in windows {
        let top = window.sorted { $0.confidence > $1.confidence }.prefix(4)
            .map { "\($0.identifier) \(String(format: "%.2f", $0.confidence))" }.joined(separator: ", ")
        print("[SoundClassifier]   \(String(format: "%.2f", start)) s: \(top)")
    }
}

private func timed(_ samples: [Float]) async throws -> ([SoundClassification], Double) {
    let start = ContinuousClock.now
    let labels = try await SystemSoundClassifier().classify(samples, sampleRate: ClassifierSignals.sampleRate)
    let elapsed = ContinuousClock.now - start
    return (labels, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
}

@Suite(.enabled(if: SystemSoundClassifier.isAvailable, "Apple's built-in sound classifier cannot be created on this machine"))
struct SoundClassifierTests {
    @Test func `the live label list is the committed one`() throws {
        #expect(try SystemSoundClassifier.knownLabels() == SoundClassifierLabels.version1)
    }

    @Test(.enabled(if: ClassifierSignals.speech != nil, "the Mac's say command could not make a voice"))
    func `a voice is named as someone talking`() async throws {
        let speech = try #require(ClassifierSignals.speech)
        let (labels, seconds) = try await timed(speech)
        log("speech (\(String(format: "%.1f", Double(speech.count) / ClassifierSignals.sampleRate)) s)", labels, seconds: seconds)
        let report = try #require(InterferenceAdvisor.describe(classifications: labels))
        #expect(report.kind == .speech)
        #expect(report.confidence > 0.9)
        #expect(report.fraction > 0.9)
    }

    @Test func `a tune is named as music, but not while the sweep plays`() async throws {
        let (labels, seconds) = try await timed(ClassifierSignals.music)
        log("music", labels, seconds: seconds)
        #expect(InterferenceAdvisor.describe(classifications: labels)?.kind == .music)
        #expect(InterferenceAdvisor.describe(classifications: labels, context: .sweepPlaying) == nil)
    }

    @Test func `steady noise is not named`() async throws {
        let (labels, seconds) = try await timed(ClassifierSignals.noise)
        log("white noise", labels, seconds: seconds)
        #expect(!labels.isEmpty)
        #expect(InterferenceAdvisor.describe(classifications: labels) == nil)
    }

    /// The test signal problem: the sweep reads as music and synthesiser, so a run recorded while it plays is
    /// classified with `.sweepPlaying`.
    @Test func `a clean sweep recording yields no interference report`() async throws {
        let (labels, seconds) = try await timed(ClassifierSignals.sweepRecording)
        log("clean measurement sweep", labels, seconds: seconds)
        #expect(InterferenceAdvisor.describe(classifications: labels, context: .sweepPlaying) == nil)
        // The problem it solves: heard as if the sweep were not playing, the sweep would be named as music.
        #expect(InterferenceAdvisor.describe(classifications: labels, context: .sweepSilent)?.kind == .music)
        let note = await InterferenceAdvisor.noiseNote(heard: ClassifierSignals.sweepRecording, sampleRate: ClassifierSignals.sampleRate,
                                                       context: .sweepPlaying, classifier: SystemSoundClassifier())
        #expect(note == nil)
    }

    @Test(.enabled(if: ClassifierSignals.speech != nil, "the Mac's say command could not make a voice"))
    func `someone talking over the sweep is still named`() async throws {
        let speech = try #require(ClassifierSignals.speech)
        var mixed = ClassifierSignals.sweepRecording
        for index in mixed.indices where index < speech.count { mixed[index] += speech[index] }
        let (labels, seconds) = try await timed(mixed)
        log("speech over the sweep", labels, seconds: seconds)
        #expect(InterferenceAdvisor.describe(classifications: labels, context: .sweepPlaying)?.kind == .speech)
    }

    @Test func `audio shorter than a window gives no classification`() async throws {
        let short = Array(ClassifierSignals.music.prefix(Int(1.4 * ClassifierSignals.sampleRate)))
        #expect(try await SystemSoundClassifier().classify(short, sampleRate: ClassifierSignals.sampleRate).isEmpty)
        #expect(try await SystemSoundClassifier().classify([], sampleRate: ClassifierSignals.sampleRate).isEmpty)
    }

    @Test func `windows are 1.5 s apart by 0.75 s, each with its top labels`() async throws {
        let (labels, _) = try await timed(ClassifierSignals.music)
        let starts = Set(labels.map(\.start)).sorted()
        #expect(starts.count == 4)
        #expect(zip(starts, starts.dropFirst()).allSatisfy { abs($1 - $0 - 0.75) < 0.01 })
        #expect(labels.allSatisfy { abs($0.duration - 1.5) < 0.01 })
        #expect(Dictionary(grouping: labels, by: \.start).values.allSatisfy { $0.count == SystemSoundClassifier.labelsPerWindow })
    }

    @Test func `a cancelled classification throws and resumes once`() async {
        let task = Task { try await SystemSoundClassifier().classify(ClassifierSignals.noise + ClassifierSignals.noise, sampleRate: ClassifierSignals.sampleRate) }
        task.cancel()
        let result = await task.result
        // Either it was cancelled in time, or it had already finished; it never hangs or crashes.
        switch result {
        case .success(let labels): #expect(!labels.isEmpty)
        case .failure(let error): #expect(error is CancellationError)
        }
    }
}
#endif
