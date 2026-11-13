#if os(iOS)
import AVFAudio
import Synchronization

/// The real `AudioIO`: `AVAudioSession` set up for measurement, an `AVAudioEngine` with a player node for the test
/// signals and a tap on the microphone.
///
/// **Session.** Category `.playAndRecord`, mode `.measurement`, options `.allowBluetoothA2DP` and `.allowAirPlay`:
/// - `.playAndRecord` because the sweep plays while the microphone records.
/// - `.measurement` turns off the input's automatic gain, equalisation and other processing the other modes apply;
///   voice processing (echo cancellation) is off on the input node and is never turned on.
/// - `.allowBluetoothA2DP` and `.allowAirPlay` so the user's own speakers, on Bluetooth or AirPlay, can be the output
///   while the iPhone's microphone records. Hands-free Bluetooth (HFP) is deliberately not allowed: it would move the
///   microphone to the headset and drop the output to telephone quality.
/// - `.defaultToSpeaker` is deliberately not set: the output is whatever route the user chose. With nothing connected,
///   `.playAndRecord` plays through the receiver; the app should say that its speakers are not connected.
/// - The preferred sample rate is 48 kHz; the stream reports the rate the hardware settled on.
/// - System alerts are asked not to interrupt (`setPrefersNoInterruptionsFromSystemAlerts`).
/// - The system volume is never read or changed; the engine's mixer stays at unity.
///
/// **Interruptions and route changes end the stream** with `AudioIOError.interrupted` or `.routeChanged`: a run
/// whose output moved or whose engine restarted has no reliable timeline to continue on.
///
/// **Timeline.** A capture position is the input's sample time counted from its first tapped block. Buffers are
/// scheduled at explicit sample times on the player's own timeline, and the player's "now" is mapped to a capture
/// position through the host clock: the latest tapped block's (position, host time) against the player's last render
/// (sample time, host time). Input and output latencies are constant for one route and the same for every buffer in
/// a run, so they cancel when two takes are spliced; the route delay itself is measured from the recording.
///
/// **Threads.** None of this module's code runs on the real-time render thread: the player renders buffers prepared
/// before they were scheduled. The tap block runs on AVAudioEngine's tap thread (not the render thread). It copies the
/// samples into an array, publishes the newest (position, host time) through an `Atomic<WordPair>` (lock free), and
/// yields the block into an `AsyncThrowingStream` continuation, which is the hand-off to the session. The tap never
/// takes the `Mutex` that guards the engine; that lock is held only by `start`, `schedule`, `stopPlayback` and `stop`.
public final class EngineAudioIO: AudioIO {
    /// Hertz asked of the hardware.
    public static let preferredSampleRate = 48000.0
    /// Frames asked of each tap block (100 ms at 48 kHz). The engine may deliver other sizes; the session re-blocks.
    public static let tapBufferSize: AVAudioFrameCount = 4800
    /// How far ahead of the player's current render time a buffer is scheduled on an idle output. *First guess*:
    /// 100 ms, several render cycles, so a buffer is never scheduled in the past.
    public static let schedulingLead = 0.1

    private let state = Mutex(EngineState())

    public init() {}

    public func start() async throws -> CaptureStream {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP, .allowAirPlay])
            try session.setPreferredSampleRate(Self.preferredSampleRate)
            try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
            try session.setActive(true)
        } catch {
            throw AudioIOError.unavailable("audio session: \(error)")
        }

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: CapturedBlock.self, throwing: (any Error).self)
        let sampleRate = try state.withLock { state throws(AudioIOError) -> Double in
            guard state.engine == nil else { throw .unavailable("already running") }
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else { throw .unavailable("no microphone") }
            let sampleRate = inputFormat.sampleRate
            guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
                throw .unavailable("no output format at \(sampleRate) Hz")
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
            engine.mainMixerNode.outputVolume = 1

            let tap = TapContext(continuation: continuation)
            input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat, block: Self.tapBlock(tap))
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw .unavailable("engine: \(error)")
            }
            player.play()

            state = EngineState(
                engine: engine,
                player: player,
                outputFormat: outputFormat,
                tap: tap,
                observers: Self.observe(engine: engine, continuation: continuation)
            )
            return sampleRate
        }
        return CaptureStream(sampleRate: sampleRate, blocks: stream)
    }

    /// The session's current output, from `AVAudioSession.currentRoute`. With nothing connected `.playAndRecord`
    /// plays through the receiver, which a measurement must refuse. Check on a phone: the port types a car, a dock
    /// and an AirPlay group report.
    public var outputRoute: AudioOutputRoute? {
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return nil }
        let kind: AudioOutputRoute.Kind = switch output.portType {
        case .builtInReceiver: .builtInReceiver
        case .builtInSpeaker: .builtInSpeaker
        case .headphones, .lineOut, .usbAudio, .HDMI: .wired
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: .bluetooth
        case .airPlay: .airPlay
        default: .other
        }
        return AudioOutputRoute(kind: kind, name: output.portName)
    }

    public func schedule(_ samples: [Float], on channel: SpeakerChannel, mode: PlaybackMode) throws -> Int64 {
        try state.withLock { state throws(AudioIOError) in try state.schedule(samples, on: channel, mode: mode) }
    }

    public func stopPlayback() {
        state.withLock { $0.stopPlayback() }
    }

    public func stop() async {
        let running = state.withLock { state -> EngineState in
            let running = state
            state = EngineState()
            return running
        }
        running.engine?.inputNode.removeTap(onBus: 0)
        running.player?.stop()
        running.engine?.stop()
        for observer in running.observers { NotificationCenter.default.removeObserver(observer) }
        running.tap?.continuation.finish()
        if running.engine != nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Tap and notifications

    /// The tap block. Built in a nonisolated static context so it inherits no actor isolation: it is called on the
    /// engine's tap thread.
    private static func tapBlock(_ tap: TapContext) -> AVAudioNodeTapBlock {
        { buffer, when in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0, when.isSampleTimeValid else { return }
            let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            var first = tap.firstSampleTime.load(ordering: .relaxed)
            if first == .min {
                first = when.sampleTime
                tap.firstSampleTime.store(first, ordering: .relaxed)
            }
            let position = when.sampleTime - first
            if when.isHostTimeValid {
                tap.anchor.store(WordPair(first: UInt(bitPattern: Int(position)), second: UInt(when.hostTime)), ordering: .releasing)
            }
            tap.continuation.yield(CapturedBlock(position: position, samples: samples))
        }
    }

    private static func observe(
        engine: AVAudioEngine,
        continuation: AsyncThrowingStream<CapturedBlock, any Error>.Continuation
    ) -> [any NSObjectProtocol] {
        let center = NotificationCenter.default
        return [
            // Any interruption, begun or ended, ends the run: the payload is not needed to know that.
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { _ in
                continuation.finish(throwing: AudioIOError.interrupted)
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
                continuation.finish(throwing: AudioIOError.interrupted)
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { note in
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
                switch reason {
                case .oldDeviceUnavailable, .newDeviceAvailable, .override, .noSuitableRouteForCategory:
                    continuation.finish(throwing: AudioIOError.routeChanged)
                default:
                    // Category changes are this app's own setup; the rest do not move the route.
                    break
                }
            },
            // The engine stops itself when the hardware's format or route changes under it.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
                continuation.finish(throwing: AudioIOError.routeChanged)
            },
        ]
    }
}

/// What the tap thread shares. Sendable: the continuation is, and the rest are atomics.
private final class TapContext: Sendable {
    let continuation: AsyncThrowingStream<CapturedBlock, any Error>.Continuation
    /// The input sample time of the first tapped block; `.min` until then.
    let firstSampleTime = Atomic<Int64>(.min)
    /// The newest block's capture position and host time.
    let anchor = Atomic<WordPair>(WordPair(first: 0, second: 0))

    init(continuation: AsyncThrowingStream<CapturedBlock, any Error>.Continuation) {
        self.continuation = continuation
    }
}

/// The engine and what is queued on it; only touched under `EngineAudioIO.state`'s lock.
private struct EngineState {
    var engine: AVAudioEngine?
    var player: AVAudioPlayerNode?
    var outputFormat: AVAudioFormat?
    var tap: TapContext?
    var observers: [any NSObjectProtocol] = []
    /// The player sample time at which the queue runs dry; nil when nothing is queued.
    var queueEnd: AVAudioFramePosition?
    /// The looping buffer playing, as (player start, length).
    var loop: (start: AVAudioFramePosition, length: AVAudioFramePosition)?

    mutating func schedule(_ samples: [Float], on channel: SpeakerChannel, mode: PlaybackMode) throws(AudioIOError) -> Int64 {
        guard let engine, engine.isRunning, let player, let outputFormat, let tap else { throw .notRunning }
        guard !samples.isEmpty else { throw .unavailable("an empty buffer") }
        guard let renderTime = player.lastRenderTime, renderTime.isHostTimeValid,
              let playerTime = player.playerTime(forNodeTime: renderTime) else {
            throw .unavailable("the player is not rendering yet")
        }
        let anchor = tap.anchor.load(ordering: .acquiring)
        guard anchor.second != 0 else { throw .unavailable("no microphone block yet") }

        let sampleRate = outputFormat.sampleRate
        let lead = AVAudioFramePosition(EngineAudioIO.schedulingLead * sampleRate)
        let now = playerTime.sampleTime
        var start = max(queueEnd ?? now, now + lead)
        var options: AVAudioPlayerNodeBufferOptions = []
        switch mode {
        case .once:
            guard loop == nil else { throw .unavailable("a loop is playing; end it with afterLoop") }
        case .loop:
            guard loop == nil else { throw .unavailable("a loop is already playing") }
            options = .loops
        case .afterLoop:
            guard let loop else { throw .unavailable("no loop is playing") }
            let from = max(now + lead, loop.start)
            start = loop.start + (from - loop.start + loop.length - 1) / loop.length * loop.length
            options = .interruptsAtLoop
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else {
            throw .unavailable("no buffer for \(samples.count) frames")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let left = channel != .right
        let right = channel != .left
        samples.withUnsafeBufferPointer { source in
            for index in 0..<samples.count {
                channels[0][index] = left ? source[index] : 0
                channels[1][index] = right ? source[index] : 0
            }
        }
        // A buffer that takes over at a loop point is placed by the player itself; the rest at an exact time.
        let when = mode == .afterLoop ? nil : AVAudioTime(sampleTime: start, atRate: sampleRate)
        player.scheduleBuffer(buffer, at: when, options: options, completionHandler: nil)

        switch mode {
        case .once: queueEnd = start + AVAudioFramePosition(samples.count)
        case .loop: loop = (start, AVAudioFramePosition(samples.count)); queueEnd = nil
        case .afterLoop: loop = nil; queueEnd = start + AVAudioFramePosition(samples.count)
        }

        // The player's render time on the capture timeline, through the host clock.
        let anchorPosition = Double(Int(bitPattern: anchor.first))
        let hostSeconds = AVAudioTime.seconds(forHostTime: renderTime.hostTime) - AVAudioTime.seconds(forHostTime: UInt64(anchor.second))
        let captureNow = anchorPosition + hostSeconds * sampleRate
        return Int64((captureNow + Double(start - now)).rounded())
    }

    mutating func stopPlayback() {
        guard let player else { return }
        // Stopping drops every queued buffer and resets the player's timeline; playing again starts a new one.
        player.stop()
        player.play()
        queueEnd = nil
        loop = nil
    }
}
#endif
