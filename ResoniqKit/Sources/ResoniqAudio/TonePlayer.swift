import Foundation
import ResoniqDSP

/// "Hold to hear": a steady sine on one channel at the safe level, faded in and out so it never clicks.
///
/// The tone is a loop of a whole number of periods (`TestSignal.sine`), so it repeats seamlessly for as long as it is
/// held: a fade-in segment, the loop, and on `stop()` a fade-out segment that takes over at the loop's next point.
/// The frequency is moved by at most a fraction of a percent so that a whole number of periods fits the loop.
///
/// The IO is started for the tone and stopped once the fade out has played. The microphone runs with it (the IO is
/// duplex); its blocks are only used as the clock and are not kept.
@MainActor
@Observable
public final class TonePlayer {
    /// The fade at each end, seconds. 20 ms, the sweep's own.
    nonisolated public static let fadeDuration = 0.02
    /// Shortest and longest loop, seconds. Longer loops fit a whole number of periods closer to the frequency asked;
    /// shorter ones stop sooner after `stop()`.
    nonisolated public static let loopDurations: ClosedRange<Double> = 0.1...0.25

    /// The frequency actually playing, hertz; nil when silent.
    public private(set) var frequency: Double?
    public private(set) var isPlaying = false

    @ObservationIgnored private let io: any AudioIO
    @ObservationIgnored private var loop: [Float] = []
    @ObservationIgnored private var fadeOut: [Float] = []
    @ObservationIgnored private var drain: Task<Void, Never>?
    @ObservationIgnored private var fadeOutEnd: Int64?
    @ObservationIgnored private var channel: SpeakerChannel = .both
    @ObservationIgnored private var sampleRate = 48000.0

    public init(io: any AudioIO) {
        self.io = io
    }

    /// Starts the tone, or moves it to a new frequency or channel if one is playing.
    public func start(frequency requested: Double, on channel: SpeakerChannel) async throws {
        if isPlaying { await stopAndWait() }
        let stream = try await io.start()
        let sampleRate = stream.sampleRate
        self.sampleRate = sampleRate
        self.channel = channel
        let tone = Self.segments(frequency: requested, sampleRate: sampleRate)
        loop = tone.loop
        fadeOut = tone.fadeOut
        do {
            _ = try io.schedule(tone.fadeIn, on: channel, mode: .once)
            _ = try io.schedule(tone.loop, on: channel, mode: .loop)
        } catch {
            await io.stop()
            throw error
        }
        frequency = tone.frequency
        isPlaying = true
        fadeOutEnd = nil
        drain = Task { [weak self] in
            do {
                for try await block in stream.blocks {
                    guard let self else { return }
                    // A little past the fade's last sample, so the output's own buffer has played it.
                    if let end = self.fadeOutEnd, block.position >= end + Int64(0.1 * sampleRate) { break }
                }
            } catch {}
            await self?.finish()
        }
    }

    /// Fades the tone out at the loop's next point; the audio is released once the fade has played.
    public func stop() {
        guard isPlaying, fadeOutEnd == nil, !fadeOut.isEmpty else { return }
        if let start = try? io.schedule(fadeOut, on: channel, mode: .afterLoop) {
            fadeOutEnd = start + Int64(fadeOut.count)
        } else {
            io.stopPlayback()
            fadeOutEnd = 0
        }
    }

    /// Stops and waits until the audio has been released.
    public func stopAndWait() async {
        stop()
        await drain?.value
    }

    private func finish() async {
        io.stopPlayback()
        await io.stop()
        isPlaying = false
        frequency = nil
        drain = nil
        fadeOutEnd = nil
    }

    /// The three pieces of a tone near `frequency`: a loop of whole periods, the same loop faded in, and its first
    /// `fadeDuration` faded out. Each starts at phase zero and the loop ends one sample before it, so any of them can
    /// follow the loop without a seam.
    nonisolated static func segments(
        frequency: Double,
        sampleRate: Double
    ) -> (frequency: Double, fadeIn: [Float], loop: [Float], fadeOut: [Float]) {
        let (length, exact) = loop(for: frequency, sampleRate: sampleRate)
        let loop = TestSignal.sine(frequency: exact, duration: Double(length) / sampleRate, sampleRate: sampleRate, fadeDuration: 0)
        let fade = min(Int((fadeDuration * sampleRate).rounded()), loop.count)
        var fadeOut = Array(loop[0..<fade])
        for index in fadeOut.indices {
            fadeOut[index] *= Float(0.5 * (1 + cos(Double.pi * Double(index) / Double(fade))))
        }
        return (exact, SweepSplicer.fadedIn(loop[...], length: fade), loop, fadeOut)
    }

    /// The loop length in samples and the frequency that fits it a whole number of times, closest to `frequency`.
    nonisolated static func loop(for frequency: Double, sampleRate: Double) -> (length: Int, frequency: Double) {
        let nyquist = sampleRate / 2
        let target = min(max(frequency, 1), nyquist * 0.98)
        let shortest = Int(loopDurations.lowerBound * sampleRate)
        let longest = Int(loopDurations.upperBound * sampleRate)
        var best = (length: shortest, frequency: target, error: Double.infinity)
        for length in shortest...longest {
            let periods = max(1, (target * Double(length) / sampleRate).rounded())
            let exact = periods * sampleRate / Double(length)
            let error = abs(exact - target) / target
            if error < best.error { best = (length, exact, error) }
            if error < 1e-6 { break }
        }
        return (best.length, best.frequency)
    }
}
