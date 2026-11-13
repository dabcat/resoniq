import Foundation

/// Which of the user's speakers a test signal is played on.
public enum SpeakerChannel: Sendable, Hashable, CaseIterable {
    case left
    case right
    /// Both channels at once: the "Only one" speaker, or a mono system.
    case both
}

/// How a scheduled buffer plays.
public enum PlaybackMode: Sendable, Hashable {
    /// Once, right after whatever is already queued (or after a short lead when nothing is).
    case once
    /// Repeats until a buffer scheduled with `afterLoop` takes over, or playback stops. For steady tones.
    case loop
    /// Once, taking over from a looping buffer at its next loop point, so a tone ends on a whole period.
    case afterLoop
}

/// A run of microphone samples and where it sits on the capture timeline.
public struct CapturedBlock: Sendable, Equatable {
    /// The capture-timeline position of `samples[0]`: samples counted from the start of capture. Consecutive blocks
    /// are contiguous; a block whose position is not the previous block's end means samples were lost, and every
    /// position measured across the gap is unreliable.
    public var position: Int64
    /// Mono, linear, full scale 1.
    public var samples: [Float]

    public init(position: Int64, samples: [Float]) {
        self.position = position
        self.samples = samples
    }

    /// The position just after the last sample.
    public var end: Int64 { position + Int64(samples.count) }
}

/// A running duplex stream: the sample rate it settled on and the microphone blocks as they arrive.
public struct CaptureStream: Sendable {
    /// Hertz; the same for playback and capture, fixed until `AudioIO.stop()`.
    public var sampleRate: Double
    /// Microphone blocks in order. The stream ends with an `AudioIOError` when the audio is interrupted or the route
    /// changes, and without one when `stop()` is called or the consuming task is cancelled.
    public var blocks: AsyncThrowingStream<CapturedBlock, any Error>

    public init(sampleRate: Double, blocks: AsyncThrowingStream<CapturedBlock, any Error>) {
        self.sampleRate = sampleRate
        self.blocks = blocks
    }
}

/// Why the audio stopped under a measurement.
public enum AudioIOError: Error, Sendable, Equatable {
    /// A call, an alarm, Siri or another app took the audio.
    case interrupted
    /// The output or input changed (a speaker disconnected, headphones plugged in), so the timeline and the route
    /// a measurement depends on are gone.
    case routeChanged
    /// The audio could not be started or a buffer could not be scheduled; the text is for the log, not the screen.
    case unavailable(String)
    /// `schedule` was called while the stream was not running.
    case notRunning
}

/// The seam between a measurement and the hardware: a duplex stream that plays buffers on a speaker channel and
/// delivers the microphone, with both on one sample timeline.
///
/// The one promise that matters is the timeline: `schedule` returns the capture-timeline position at which the
/// buffer's first sample is sent to the output. The route then adds its own delay (tens of milliseconds for a cable,
/// up to about two seconds for AirPlay) before the sound reaches the microphone; that delay is unknown to the IO and
/// is measured from the recording. What must hold is that the positions of two buffers scheduled in one stream are
/// exact relative to each other, so a constant device latency cancels when two takes are spliced.
public protocol AudioIO: AnyObject, Sendable {
    /// Starts capture and playback. Throws `AudioIOError.unavailable` when the audio cannot start.
    func start() async throws -> CaptureStream

    /// Queues `samples` (mono, linear) for `channel` and returns the capture-timeline position of its first sample.
    /// The samples must already be at a safe level; the IO plays them as given and never touches the system volume.
    func schedule(_ samples: [Float], on channel: SpeakerChannel, mode: PlaybackMode) throws -> Int64

    /// Drops everything queued and silences the output at once. Capture continues.
    func stopPlayback()

    /// Stops playback and capture, ends the stream, and releases the audio for other apps.
    func stop() async
}
