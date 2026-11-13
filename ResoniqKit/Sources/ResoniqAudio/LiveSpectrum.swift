import Foundation
import ResoniqDSP

/// "Watch the sound live": third-octave band levels of the microphone, about 15 times a second, smoothed so the bars
/// are readable. Never plays anything.
///
/// `bands()` starts the IO and returns a stream of `MagnitudeResponse`s: one point per third-octave band from 20 Hz
/// to 20 kHz (`OctaveBands`, exact base-ten centres), in dBFS RMS (`SoundLevel.approximateDecibels` turns one into
/// the screen's "dB"). Each update analyses the latest `analysisLength` samples (Hann window, `SpectrumAnalyzer`,
/// then `OctaveBands.levels`), one update per `sampleRate / updateRate` captured samples, so the rate is steady in
/// audio time: blocks of 100 ms bring one or two updates each. Each band then moves towards its new level by an
/// exponential step, fast when rising (`attackTime`) and slow when falling (`releaseTime`).
///
/// **Hand-off.** The analysis runs in a task off the main actor (`pump`, `@concurrent`), which owns the capture
/// stream and every buffer; the only thing that crosses to the consumer is each finished `MagnitudeResponse`, a
/// `Sendable` value, through the `AsyncStream`'s continuation. Only the newest updates are buffered (a slow consumer
/// sees the latest bars, never a backlog). The stream ends, and the IO is stopped, when the consumer stops iterating
/// (the stream's termination cancels the task), when its task is cancelled, or when the audio is interrupted.
public struct LiveSpectrum: Sendable {
    /// Updates a second of captured audio. 15: smooth enough to read as movement, cheap enough to ignore.
    public static let updateRate: Double = 15
    /// Time constant, seconds, of a band's rise. *First guess*: 0.05 s, so a new sound shows within an update or two.
    public static let attackTime: Double = 0.05
    /// Time constant, seconds, of a band's fall. *First guess*: 0.4 s, so the bars sink slowly enough to read.
    public static let releaseTime: Double = 0.4
    /// Samples each update analyses: 16 384 (0.34 s at 48 kHz, bins of 2.9 Hz), enough for every third-octave band
    /// down to 20 Hz (4.6 Hz wide) to hold a bin.
    public static let analysisLength = 16384
    /// The bands' range, hertz.
    public static let bandRange: ClosedRange<Float> = 20...20000
    /// The newest updates kept for a consumer that falls behind.
    static let bufferedUpdates = 2

    public let io: any AudioIO

    public init(io: any AudioIO) {
        self.io = io
    }

    /// Starts the microphone and streams the smoothed band levels until the consumer stops iterating, the task is
    /// cancelled or the audio stops. Ends at once if the audio cannot start.
    public func bands() -> AsyncStream<MagnitudeResponse> {
        let io = io
        return AsyncStream(bufferingPolicy: .bufferingNewest(Self.bufferedUpdates)) { continuation in
            let task = Task { await Self.pump(io: io, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads the IO's blocks and yields updates, off the main actor; stops the IO when done.
    @concurrent private static func pump(io: any AudioIO, into continuation: AsyncStream<MagnitudeResponse>.Continuation) async {
        guard !Task.isCancelled, let stream = try? await io.start() else {
            continuation.finish()
            return
        }
        var analyzer = LiveSpectrumAnalyzer(sampleRate: stream.sampleRate)
        do {
            for try await block in stream.blocks {
                if Task.isCancelled { break }
                for update in analyzer.append(block.samples) {
                    continuation.yield(update)
                }
            }
        } catch {
            // Interrupted or the route changed: the stream simply ends.
        }
        await io.stop()
        continuation.finish()
    }

    /// The step a band takes towards a new level in one update, as a fraction of the distance, for time constant
    /// `time`: `1 − e^(−1 / (updateRate · time))`.
    public static func smoothingCoefficient(time: Double) -> Double {
        1 - exp(-1 / (updateRate * time))
    }

    /// One band's next shown level from its `previous` shown level and its `current` measured one, dB.
    public static func smoothed(previous: Float, current: Float) -> Float {
        let time = current > previous ? attackTime : releaseTime
        return previous + Float(smoothingCoefficient(time: time)) * (current - previous)
    }
}

/// The analysis behind `LiveSpectrum`, sample-counted and free of any stream, so it can be tested exactly.
struct LiveSpectrumAnalyzer {
    let sampleRate: Double
    /// Captured samples between two updates.
    let hop: Int
    private var window: [Float] = []
    private var sinceUpdate = 0
    private var shown: [Float]?

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        hop = max(1, Int((sampleRate / LiveSpectrum.updateRate).rounded()))
        window.reserveCapacity(LiveSpectrum.analysisLength + hop)
    }

    /// Takes the next captured samples; returns the updates they complete, in order.
    mutating func append(_ samples: [Float]) -> [MagnitudeResponse] {
        var updates: [MagnitudeResponse] = []
        var offset = 0
        while offset < samples.count {
            let take = min(hop - sinceUpdate, samples.count - offset)
            window += samples[offset..<(offset + take)]
            if window.count > LiveSpectrum.analysisLength {
                window.removeFirst(window.count - LiveSpectrum.analysisLength)
            }
            sinceUpdate += take
            offset += take
            if sinceUpdate == hop {
                sinceUpdate = 0
                updates.append(update())
            }
        }
        return updates
    }

    /// The band levels of the latest `analysisLength` samples (fewer at the start), smoothed.
    private mutating func update() -> MagnitudeResponse {
        let spectrum = SpectrumAnalyzer.spectrum(of: window, sampleRate: sampleRate, window: .hann, size: LiveSpectrum.analysisLength)
        let measured = OctaveBands.levels(
            of: spectrum,
            fraction: 3,
            from: LiveSpectrum.bandRange.lowerBound,
            to: LiveSpectrum.bandRange.upperBound,
            window: .hann,
            frameLength: window.count
        )
        let next = shown.map { zip($0, measured.decibels).map { LiveSpectrum.smoothed(previous: $0, current: $1) } } ?? measured.decibels
        shown = next
        return MagnitudeResponse(frequencies: measured.frequencies, decibels: next)
    }
}
