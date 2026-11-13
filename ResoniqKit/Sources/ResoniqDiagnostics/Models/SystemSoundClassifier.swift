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
/// The analyzer runs on a background queue; the results are gathered behind a lock and the caller resumed exactly
/// once, when the request completes, fails or the task is cancelled (cancellation throws `CancellationError`).
public struct SystemSoundClassifier: SoundClassifying {
    public static let windowDuration: Double = 1.5
    public static let overlapFactor: Double = 0.5
    public static let labelsPerWindow = 10

    public init() {}

    /// Whether the system classifier can be created here.
    public static var isAvailable: Bool {
        (try? SNClassifySoundRequest(classifierIdentifier: .version1)) != nil
    }

    /// Every label identifier the system classifier knows.
    public static func knownLabels() throws -> [String] {
        try SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications
    }

    public func classify(_ samples: [Float], sampleRate: Double) async throws -> [SoundClassification] {
        guard sampleRate > 0, Double(samples.count) / sampleRate >= Self.windowDuration else { return [] }
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
}
#endif
