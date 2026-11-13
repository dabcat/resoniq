#if canImport(SoundAnalysis)
import AVFoundation
import Foundation
import SoundAnalysis
import Synchronization

/// Apple's built-in sound classifier (`SNClassifierIdentifier.version1`, 303 labels) over a buffer, on the device.
///
/// **Window and overlap.** 1.5 s windows overlapping by half, so a label lands every 0.75 s. The classifier allows
/// 0.5 to 15 s (its default is 3 s). A paused stretch or a noise-floor listen lasts a few seconds, and a dog's bark
/// or a door is shorter than 3 s, so a 3 s window would dilute it with the quiet around it; under 1 s the classifier
/// has too little to go on. Audio shorter than one window gives no classification, not an error.
///
/// **What is returned.** For each window, its `labelsPerWindow` most confident labels. Classifying 4 s at 48 kHz
/// took about 0.03 s on an Apple-silicon Mac in a release build (`SoundClassifierTests` prints the debug figure);
/// the first call also loads the model.
///
/// **It always returns.** The analysis races `timeout`: when the system classifier has not answered by then,
/// `classify` throws `SoundClassifierError.timedOut` and the analysis is cancelled (`InterferenceAdvisor` reads that
/// as "nothing heard"). The analyzer runs on a background queue, never on the caller's thread or the Swift
/// concurrency pool; the caller is resumed exactly once, when the request completes, fails, times out or the task is
/// cancelled (cancellation throws `CancellationError`). A callback after that is ignored.
public struct SystemSoundClassifier: SoundClassifying {
    public static let windowDuration: Double = 1.5
    public static let overlapFactor: Double = 0.5
    public static let labelsPerWindow = 10
    /// How long `classify` waits for the system classifier. **First guess**: 5 s. The paused screen asks about a few
    /// seconds of audio, which took 0.07–0.15 s in a debug build on a Mac and about 0.8 s on first use (model load);
    /// longer than this, the line under "It got noisy" would come too late to help.
    public static let standardTimeout: Duration = .seconds(5)
    /// How long `isWorking()` waits for its trial classification, model load included. **First guess**: 15 s, for a
    /// slow first load on a busy or virtual machine.
    public static let probeTimeout: Duration = .seconds(15)

    /// This classifier's limit (`standardTimeout` by default).
    public let timeout: Duration
    let backend: any SoundAnalysisBackend

    public init(timeout: Duration = standardTimeout) {
        self.init(timeout: timeout, backend: SystemSoundAnalysis())
    }

    /// A classifier over another analysis, for tests: a backend that never answers shows the timeout.
    init(timeout: Duration, backend: any SoundAnalysisBackend) {
        self.timeout = timeout
        self.backend = backend
    }

    /// Whether the system classifier's request can be created here. Synchronous and unbounded (it may load the
    /// model on the calling thread); `isWorking()` is the bounded answer.
    public static var isAvailable: Bool {
        (try? SNClassifySoundRequest(classifierIdentifier: .version1)) != nil
    }

    /// **Whether the system classifier answers here**, decided once per process: a trial classification of 2 s of
    /// quiet noise with `probeTimeout`. False where the classifier cannot be created, fails, or does not answer in
    /// time (a headless machine without the model, say). Never longer than `probeTimeout` plus scheduling.
    public static func isWorking() async -> Bool {
        await probeResult.value
    }

    private static let probeResult = Task<Bool, Never> {
        await probe(SystemSoundClassifier(timeout: probeTimeout))
    }

    /// One trial classification with `classifier`'s timeout: true when it returns labels.
    static func probe(_ classifier: SystemSoundClassifier) async -> Bool {
        let sampleRate = 16000.0
        var state: UInt32 = 0x9E37_79B9
        let samples = (0..<Int(2 * sampleRate)).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.02
        }
        guard let labels = try? await classifier.classify(samples, sampleRate: sampleRate) else { return false }
        return !labels.isEmpty
    }

    /// Whether `sampleRate` can be the analyzer's time scale: a positive whole number of hertz that fits a
    /// `CMTimeScale`.
    static func isUsable(sampleRate: Double) -> Bool {
        sampleRate.isFinite && sampleRate > 0 && sampleRate.rounded() == sampleRate && sampleRate <= Double(CMTimeScale.max)
    }

    /// Every label identifier the system classifier knows.
    public static func knownLabels() throws -> [String] {
        try SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications
    }

    /// No classification (not an error) for audio shorter than a window, or at a sample rate the analyzer's time
    /// scale cannot hold: not a whole number of hertz, or beyond `CMTimeScale`. Throws `SoundClassifierError.timedOut`
    /// when the analysis has not answered within `timeout`.
    public func classify(_ samples: [Float], sampleRate: Double) async throws -> [SoundClassification] {
        guard Self.isUsable(sampleRate: sampleRate), Double(samples.count) / sampleRate >= Self.windowDuration else { return [] }
        try Task.checkCancellation()
        let backend = backend
        let timeout = timeout
        // The loser is cancelled; the group returns once both children have ended, so nothing is left running. The
        // backend must honour cancellation (`SoundAnalysisBackend`), which `SystemSoundAnalysis` does at once.
        return try await withThrowingTaskGroup(of: [SoundClassification]?.self) { group in
            group.addTask { try await backend.analyze(samples, sampleRate: sampleRate) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let labels = first else { throw SoundClassifierError.timedOut }
            return labels
        }
    }
}

/// Runs one analysis of a buffer. `SystemSoundClassifier` bounds it with its timeout.
///
/// Contract: when its task is cancelled, `analyze` returns (or throws) promptly, even if the work behind it is still
/// running; the timeout depends on it.
protocol SoundAnalysisBackend: Sendable {
    func analyze(_ samples: [Float], sampleRate: Double) async throws -> [SoundClassification]
}

/// `SNAudioStreamAnalyzer` with the built-in request, on a background queue, bridged to async.
///
/// Where it could fail to return without the timeout: `SNClassifySoundRequest(classifierIdentifier:)`,
/// `analyze(_:atAudioFramePosition:)` and `completeAnalysis()` are synchronous system calls on the background queue;
/// if one of them never returns (a model that cannot load or run), nothing would resume the caller. Every other path
/// resumes: a thrown error, a failed or completed request, `completeAnalysis` returning without a callback, and
/// cancellation, which resumes at once whatever the queue is doing. A queue thread stuck in such a call keeps its
/// analyzer until the call returns; that cannot be undone from outside.
struct SystemSoundAnalysis: SoundAnalysisBackend {
    func analyze(_ samples: [Float], sampleRate: Double) async throws -> [SoundClassification] {
        try Task.checkCancellation()
        let run = ClassificationRun()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard run.start(continuation) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    run.analyze(samples, sampleRate: sampleRate)
                }
            }
        } onCancel: {
            run.cancel()
        }
    }
}

/// One classification: the observer, the gathered results and the continuation, behind one lock.
private final class ClassificationRun: NSObject, SNResultsObserving, Sendable {
    private struct State {
        var continuation: CheckedContinuation<[SoundClassification], any Error>?
        var results: [SoundClassification] = []
        var cancelled = false
        var finished = false
    }

    private let state = Mutex(State())

    /// Stores the continuation; false (having resumed it with `CancellationError`) when already cancelled.
    func start(_ continuation: CheckedContinuation<[SoundClassification], any Error>) -> Bool {
        let cancelled = state.withLock { state in
            if state.cancelled { state.finished = true; return true }
            state.continuation = continuation
            return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
        return !cancelled
    }

    func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<[SoundClassification], any Error>? in
            state.cancelled = true
            return state.finished ? nil : take(&state)
        }
        continuation?.resume(throwing: CancellationError())
    }

    private var isCancelled: Bool { state.withLock { $0.cancelled } }

    private func take(_ state: inout State) -> CheckedContinuation<[SoundClassification], any Error>? {
        state.finished = true
        defer { state.continuation = nil }
        return state.continuation
    }

    private func finish(_ result: Result<Void, any Error>) {
        let (continuation, results) = state.withLock { state in
            (state.finished ? nil : take(&state), state.results)
        }
        guard let continuation else { return }
        switch result {
        case .success: continuation.resume(returning: results)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    /// Runs on a background queue. The analyzer processes synchronously in `completeAnalysis`.
    func analyze(_ samples: [Float], sampleRate: Double) {
        do {
            if isCancelled { return }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw SoundClassifierError.unsupportedFormat(sampleRate)
            }
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: SystemSoundClassifier.windowDuration, preferredTimescale: CMTimeScale(sampleRate))
            request.overlapFactor = SystemSoundClassifier.overlapFactor
            try analyzer.add(request, withObserver: self)
            let chunk = 8192
            var position = 0
            while position < samples.count {
                if isCancelled { analyzer.removeAllRequests(); return }
                let count = min(chunk, samples.count - position)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0]
                else { throw SoundClassifierError.unsupportedFormat(sampleRate) }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { source in
                    channel.update(from: source.baseAddress! + position, count: count)
                }
                analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(position))
                position += count
            }
            if isCancelled { analyzer.removeAllRequests(); return }
            analyzer.completeAnalysis()
            // `requestDidComplete` normally finishes first; this covers a request that never reports.
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    // MARK: SNResultsObserving

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let start = result.timeRange.start.seconds
        let duration = result.timeRange.duration.seconds
        let labels = result.classifications.prefix(SystemSoundClassifier.labelsPerWindow).map {
            SoundClassification(identifier: $0.identifier, confidence: Float($0.confidence), start: start, duration: duration)
        }
        state.withLock { $0.results.append(contentsOf: labels) }
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        finish(.failure(error))
    }

    func requestDidComplete(_ request: any SNRequest) {
        finish(.success(()))
    }
}

public enum SoundClassifierError: Error, Equatable {
    case unsupportedFormat(Double)
    /// The system classifier did not answer within the classifier's `timeout`.
    case timedOut
}
#endif
