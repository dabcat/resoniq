#if canImport(SoundAnalysis)
import AVFoundation
import Foundation
import ResoniqDSP
import Synchronization
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

    /// A synthetic voice from the Mac's `say`, 48 kHz float; nil where it cannot be made, or not within `sayTimeout`
    /// (the process is then stopped). Made once, waited for off the concurrency pool.
    static var speech: [Float]? {
        get async { await speechTask.value }
    }

    /// `say` writes to a file and needs no audio device; it takes about a second. **First guess**: 20 s.
    static let sayTimeout: Duration = .seconds(20)

    private static let speechTask = Task<[Float]?, Never> {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resoniq-speech-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--data-format=LEF32@48000",
                             "Could you turn the television down for a moment? I am measuring the speakers in the living room."]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        do {
            try await OffPool.run(timeout: sayTimeout) { process.waitUntilExit() }
        } catch {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0,
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0], buffer.frameLength > 0
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

/// The classifier the tests run, and whether it answers here.
///
/// `RESONIQ_TEST_SOUND_CLASSIFIER` simulates a machine where the system classifier does not work, to check that the
/// suite still finishes: `unavailable` (the probe says no) or `silent` (a classifier that never answers, so the
/// probe times out). Unset, it is the real one.
enum TestClassifier {
    static let mode = ProcessInfo.processInfo.environment["RESONIQ_TEST_SOUND_CLASSIFIER"]

    /// Generous, so a slow shared runner still gets an answer; the product's limit is `standardTimeout`.
    static let timeout: Duration = .seconds(60)

    static var classifier: SystemSoundClassifier {
        mode == "silent" ? SystemSoundClassifier(timeout: .seconds(2), backend: SilentAnalysis()) : SystemSoundClassifier(timeout: timeout)
    }

    static func isWorking() async -> Bool {
        switch mode {
        case "unavailable": false
        case "silent": await SystemSoundClassifier.probe(classifier)
        default: await SystemSoundClassifier.isWorking()
        }
    }
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

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func timed(_ samples: [Float]) async throws -> ([SoundClassification], Double) {
    let start = ContinuousClock.now
    let labels = try await TestClassifier.classifier.classify(samples, sampleRate: ClassifierSignals.sampleRate)
    return (labels, seconds(ContinuousClock.now - start))
}

/// The real classifier: every test is skipped, with the reason, where it does not answer, and bounded where it does.
@Suite(.enabled("Apple's built-in sound classifier does not answer on this machine (SystemSoundClassifier.isWorking)") {
    await TestClassifier.isWorking()
}, .timeLimit(.minutes(2)))
struct SoundClassifierTests {
    @Test func `the live label list is the committed one`() throws {
        #expect(try SystemSoundClassifier.knownLabels() == SoundClassifierLabels.version1)
    }

    @Test(.enabled("the Mac's say command could not make a voice in time") { await ClassifierSignals.speech != nil })
    func `a voice is named as someone talking`() async throws {
        let speech = try #require(await ClassifierSignals.speech)
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
                                                       context: .sweepPlaying, classifier: TestClassifier.classifier)
        #expect(note == nil)
    }

    @Test(.enabled("the Mac's say command could not make a voice in time") { await ClassifierSignals.speech != nil })
    func `someone talking over the sweep is still named`() async throws {
        let speech = try #require(await ClassifierSignals.speech)
        var mixed = ClassifierSignals.sweepRecording
        for index in mixed.indices where index < speech.count { mixed[index] += speech[index] }
        let (labels, seconds) = try await timed(mixed)
        log("speech over the sweep", labels, seconds: seconds)
        #expect(InterferenceAdvisor.describe(classifications: labels, context: .sweepPlaying)?.kind == .speech)
    }

    @Test func `audio shorter than a window gives no classification`() async throws {
        let short = Array(ClassifierSignals.music.prefix(Int(1.4 * ClassifierSignals.sampleRate)))
        #expect(try await TestClassifier.classifier.classify(short, sampleRate: ClassifierSignals.sampleRate).isEmpty)
        #expect(try await TestClassifier.classifier.classify([], sampleRate: ClassifierSignals.sampleRate).isEmpty)
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
        let task = Task { try await TestClassifier.classifier.classify(ClassifierSignals.noise + ClassifierSignals.noise, sampleRate: ClassifierSignals.sampleRate) }
        task.cancel()
        let result = await task.result
        // Either it was cancelled in time, or it had already finished; it never hangs or crashes.
        switch result {
        case .success(let labels): #expect(!labels.isEmpty)
        case .failure(let error): #expect(error is CancellationError)
        }
    }
}

/// What the classifier refuses before it reaches the system: it needs neither the system classifier nor `say`, so it
/// always runs.
struct SoundClassifierInputTests {
    @Test(arguments: [44100.5, 0, -48000, .infinity, .nan, 1e12])
    func `a sample rate the analyzer cannot use gives no classification, not a trap`(sampleRate: Double) async throws {
        let samples = [Float](repeating: 0.1, count: 4 * 48000)
        #expect(try await SystemSoundClassifier().classify(samples, sampleRate: sampleRate).isEmpty)
        #expect(!SystemSoundClassifier.isUsable(sampleRate: sampleRate))
    }

    @Test func `a whole number of hertz is usable`() {
        #expect(SystemSoundClassifier.isUsable(sampleRate: 48000) && SystemSoundClassifier.isUsable(sampleRate: 44100))
    }
}

// MARK: - The timeout, without the system classifier

/// An analysis that never answers: it waits until its task is cancelled, as the backend contract asks, and counts
/// how often it started, was resumed and ended.
final class SilentAnalysis: SoundAnalysisBackend {
    struct Counts: Equatable { var started = 0, resumed = 0, ended = 0 }
    private let counts = Mutex(Counts())
    private let waiting = Mutex<CheckedContinuation<[SoundClassification], any Error>?>(nil)

    var snapshot: Counts { counts.withLock { $0 } }

    func analyze(_ samples: [Float], sampleRate: Double) async throws -> [SoundClassification] {
        counts.withLock { $0.started += 1 }
        defer { counts.withLock { $0.ended += 1 } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.withLock { $0 = continuation }
                if Task.isCancelled { resumeOnce() }
            }
        } onCancel: {
            resumeOnce()
        }
    }

    private func resumeOnce() {
        guard let continuation = waiting.withLock({ state in defer { state = nil }; return state }) else { return }
        counts.withLock { $0.resumed += 1 }
        continuation.resume(throwing: CancellationError())
    }
}

/// An analysis that answers, but only after `delay` and whatever its task says: a late callback.
struct LateAnalysis: SoundAnalysisBackend {
    let delay: Duration

    func analyze(_ samples: [Float], sampleRate: Double) async throws -> [SoundClassification] {
        try await Task.sleep(for: delay)
        return [SoundClassification(identifier: "speech", confidence: 0.99, start: 0, duration: 1.5)]
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SoundClassifierTimeoutTests {
    static let samples = [Float](repeating: 0.01, count: 2 * 16000)
    static let limit: Duration = .milliseconds(300)
    /// A busy three-core CI runner took 3.8 s to come back from a 0.3 s limit; the bound only has to tell a
    /// time-out from a hang.
    static let slack: Duration = .seconds(30)

    @Test func `the product's limits are named`() {
        #expect(SystemSoundClassifier.standardTimeout == .seconds(5))
        #expect(SystemSoundClassifier.probeTimeout == .seconds(15))
        #expect(SystemSoundClassifier().timeout == SystemSoundClassifier.standardTimeout)
    }

    @Test func `a classifier that never answers times out within its limit, resumes once and leaves nothing running`() async {
        let backend = SilentAnalysis()
        let classifier = SystemSoundClassifier(timeout: Self.limit, backend: backend)
        let start = ContinuousClock.now
        await #expect(throws: SoundClassifierError.timedOut) {
            try await classifier.classify(Self.samples, sampleRate: 16000)
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= Self.limit && elapsed < Self.limit + Self.slack)
        // Started once, resumed once by the cancellation, and ended before `classify` returned.
        #expect(backend.snapshot == SilentAnalysis.Counts(started: 1, resumed: 1, ended: 1))
    }

    @Test func `the advisor says nothing rather than wait`() async {
        let backend = SilentAnalysis()
        let classifier = SystemSoundClassifier(timeout: Self.limit, backend: backend)
        let start = ContinuousClock.now
        let note = await InterferenceAdvisor.note(heard: Self.samples, sampleRate: 16000, sweepPlaying: false, classifier: classifier)
        #expect(note == nil)
        #expect(ContinuousClock.now - start < Self.limit + Self.slack)
        #expect(backend.snapshot.ended == 1)
    }

    @Test func `an answer after the limit is dropped, not delivered twice`() async throws {
        let classifier = SystemSoundClassifier(timeout: Self.limit, backend: LateAnalysis(delay: .seconds(1)))
        await #expect(throws: SoundClassifierError.timedOut) {
            try await classifier.classify(Self.samples, sampleRate: 16000)
        }
        // Let the late answer's moment pass: nothing resumes again or traps.
        try await Task.sleep(for: .seconds(1))
    }

    @Test func `an answer within the limit is returned`() async throws {
        let classifier = SystemSoundClassifier(timeout: .seconds(5), backend: LateAnalysis(delay: .milliseconds(50)))
        let labels = try await classifier.classify(Self.samples, sampleRate: 16000)
        #expect(labels.map(\.identifier) == ["speech"])
    }

    @Test func `cancelling the caller of a silent classifier throws at once and resumes once`() async {
        let backend = SilentAnalysis()
        let classifier = SystemSoundClassifier(timeout: .seconds(30), backend: backend)
        let task = Task { try await classifier.classify(Self.samples, sampleRate: 16000) }
        try? await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        let result = await task.result
        #expect(ContinuousClock.now - start < Self.slack)
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(backend.snapshot.resumed <= 1 && backend.snapshot.ended == backend.snapshot.started)
    }

    @Test func `the probe says no for a classifier that never answers, within its limit`() async {
        let start = ContinuousClock.now
        #expect(await SystemSoundClassifier.probe(SystemSoundClassifier(timeout: Self.limit, backend: SilentAnalysis())) == false)
        #expect(ContinuousClock.now - start < Self.limit + Self.slack)
        #expect(await SystemSoundClassifier.probe(SystemSoundClassifier(timeout: .seconds(5), backend: LateAnalysis(delay: .zero))))
    }
}
#endif
