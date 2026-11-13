#if os(iOS)
import AVFAudio
import Darwin
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
///   `.playAndRecord` plays through the receiver; `outputRoute` reports it and the sessions refuse to measure it.
/// - The preferred sample rate is 48 kHz; the stream reports the rate the hardware settled on.
/// - System alerts are asked not to interrupt (`setPrefersNoInterruptionsFromSystemAlerts`).
/// - The system volume is never read or changed; the engine's mixer stays at unity.
/// - **One owner.** Activation and deactivation go through one lock with a generation count: a `stop()` deactivates
///   only if no newer `start()` has activated since, so an old IO's late deactivation cannot silence a new run. A
///   start that fails deactivates again.
///
/// **Interruptions and route changes end the stream** with `AudioIOError.interrupted` or `.routeChanged`: a run
/// whose output moved has no reliable timeline to continue on. An engine configuration change that leaves the route
/// and the format as they were restarts the engine instead; the capture positions then jump forward, which the
/// sessions see as lost samples and answer by starting the run over.
///
/// **Timeline.** A capture position is the input's sample time counted from its first tapped block. "Now" on the
/// capture timeline comes from the host clock: the latest tapped block's (position, host time) and the current host
/// time. A buffer on an idle output is scheduled at a host time `schedulingLead` ahead, and one that follows queued
/// audio is appended to it sample for sample, so nothing depends on the player's own timeline (which restarts, and
/// is briefly unknown, every time the player is stopped). Input and output latencies are constant for one route and
/// the same for every buffer in a run, so they cancel when two takes are spliced; the route delay itself is measured
/// from the recording, and the sessions compare two takes before splicing them.
///
/// **Threads.** None of this module's code runs on the real-time render thread: the player renders buffers prepared
/// before they were scheduled. The tap block runs on AVAudioEngine's tap thread (not the render thread). It copies the
/// samples into an array, publishes the newest (position, host time) through an `Atomic<WordPair>` (lock free), and
/// yields the block into an `AsyncThrowingStream` continuation, which is the hand-off to the session. The tap never
/// takes the `Mutex` that guards the engine; that lock is held only by `start`, `schedule`, `stopPlayback`, `stop`
/// and a configuration change.
public final class EngineAudioIO: AudioIO {
    /// Hertz asked of the hardware.
    public static let preferredSampleRate = 48000.0
    /// Frames asked of each tap block (100 ms at 48 kHz). The engine may deliver other sizes; the session re-blocks.
    public static let tapBufferSize: AVAudioFrameCount = 4800
    /// How far ahead of now a buffer is scheduled on an idle output. *First guess*: 100 ms, several render cycles, so
    /// a buffer is never scheduled in the past.
    public static let schedulingLead = 0.1
    /// The fade before playback is cut, seconds, so a pause or a cancel does not click. *First guess*: 6 ms in four
    /// steps of the player's volume. Check on a phone: the volume applies per render cycle (about 5–10 ms), so the
    /// steps may land as one or two; a click left over would want a fade rendered into the signal instead.
    public static let stopFade = 0.006

    /// The activation generation: incremented by every `start()` that activates the session.
    private static let activation = Mutex<UInt64>(0)

    private let state = Mutex(EngineState())

    public init() {}

    public func start() async throws -> CaptureStream {
        let session = AVAudioSession.sharedInstance()
        let token = try Self.activation.withLock { generation throws(AudioIOError) -> UInt64 in
            do {
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP, .allowAirPlay])
                try session.setPreferredSampleRate(Self.preferredSampleRate)
                try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
                try session.setActive(true)
            } catch {
                throw .unavailable("audio session: \(error)")
            }
            generation += 1
            return generation
        }

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: CapturedBlock.self, throwing: (any Error).self)
        do {
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
                    observers: Self.observe(engine: engine, continuation: continuation) { [weak self] in
                        self?.restartIfUnchanged() ?? false
                    },
                    token: token,
                    inputFormat: Self.signature(of: inputFormat),
                    routeOutputs: Self.currentOutputs()
                )
                return sampleRate
            }
            return CaptureStream(sampleRate: sampleRate, blocks: stream)
        } catch {
            // A failed start leaves nothing active behind it.
            continuation.finish()
            Self.deactivate(token: token)
            throw error
        }
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
        if let player = running.player { EngineState.fadeOut(player) }
        running.engine?.inputNode.removeTap(onBus: 0)
        running.player?.stop()
        running.engine?.stop()
        for observer in running.observers { NotificationCenter.default.removeObserver(observer) }
        running.tap?.continuation.finish()
        if running.engine != nil { Self.deactivate(token: running.token) }
    }

    /// Deactivates the session unless a newer `start()` has activated it since `token`.
    private static func deactivate(token: UInt64) {
        activation.withLock { generation in
            guard generation == token else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Configuration changes

    private static func signature(of format: AVAudioFormat) -> FormatSignature {
        FormatSignature(sampleRate: format.sampleRate, channels: format.channelCount)
    }

    private static func currentOutputs() -> [String] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.uid)
    }

    /// After an engine configuration change: when the route and the input format are what they were, restarts the
    /// engine and the player and returns true; otherwise false (the stream then ends with `.routeChanged`). Check on a
    /// phone: which changes arrive shortly after the first start, and that the restarted tap's sample times are
    /// handled by the tap's rebasing (`TapContext.nextPosition`).
    private func restartIfUnchanged() -> Bool {
        state.withLock { state in
            guard let engine = state.engine, let player = state.player,
                  Self.signature(of: engine.inputNode.outputFormat(forBus: 0)) == state.inputFormat,
                  Self.currentOutputs() == state.routeOutputs
            else { return false }
            do {
                try engine.start()
            } catch {
                return false
            }
            player.play()
            state.queueEnd = nil
            state.loop = nil
            return true
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
            var position = when.sampleTime - first
            // A restarted engine may start its sample time again: positions must never go back, so rebase one sample
            // past the last block, which the session sees as a gap.
            let next = tap.nextPosition.load(ordering: .relaxed)
            if position < next {
                first = when.sampleTime - (next + 1)
                tap.firstSampleTime.store(first, ordering: .relaxed)
                position = next + 1
            }
            tap.nextPosition.store(position + Int64(buffer.frameLength), ordering: .relaxed)
            if when.isHostTimeValid {
                tap.anchor.store(WordPair(first: UInt(bitPattern: Int(position)), second: UInt(when.hostTime)), ordering: .releasing)
            }
            tap.continuation.yield(CapturedBlock(position: position, samples: samples))
        }
    }

    private static func observe(
        engine: AVAudioEngine,
        continuation: AsyncThrowingStream<CapturedBlock, any Error>.Continuation,
        restartIfUnchanged: @escaping @Sendable () -> Bool
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
            // The engine stops itself when the hardware's format or route changes under it. A change that alters
            // neither (seen shortly after a first start) restarts it rather than ending run 1.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
                if !restartIfUnchanged() {
                    continuation.finish(throwing: AudioIOError.routeChanged)
                }
            },
        ]
    }
}

/// What the tap thread shares. Sendable: the continuation is, and the rest are atomics.
private final class TapContext: Sendable {
    let continuation: AsyncThrowingStream<CapturedBlock, any Error>.Continuation
    /// The input sample time of the first tapped block (rebased after a restart); `.min` until then.
    let firstSampleTime = Atomic<Int64>(.min)
    /// The capture position just after the newest block.
    let nextPosition = Atomic<Int64>(0)
    /// The newest block's capture position and host time.
    let anchor = Atomic<WordPair>(WordPair(first: 0, second: 0))

    init(continuation: AsyncThrowingStream<CapturedBlock, any Error>.Continuation) {
        self.continuation = continuation
    }
}

/// The input format's rate and channels, to tell a configuration change that changed nothing.
private struct FormatSignature: Equatable {
    var sampleRate: Double
    var channels: AVAudioChannelCount
}

/// The engine and what is queued on it; only touched under `EngineAudioIO.state`'s lock.
private struct EngineState {
    var engine: AVAudioEngine?
    var player: AVAudioPlayerNode?
    var outputFormat: AVAudioFormat?
    var tap: TapContext?
    var observers: [any NSObjectProtocol] = []
    /// The activation generation this IO's `start()` got.
    var token: UInt64 = 0
    /// The input format and the route's outputs at start.
    var inputFormat: FormatSignature?
    var routeOutputs: [String] = []
    /// The capture position at which the queue runs dry; nil when nothing is queued.
    var queueEnd: Int64?
    /// The looping buffer playing, as (capture position of its start, length).
    var loop: (start: Int64, length: Int64)?

    /// Schedules `samples` and returns the capture position of their first sample.
    ///
    /// "Now" on the capture timeline is the latest tapped block's position plus the host time since it. On an idle
    /// output the buffer starts `schedulingLead` from now, at the matching host time; after queued audio it is
    /// appended (`at: nil`), so a fade in and its loop join sample for sample. Neither needs the player's own
    /// timeline, which is unknown for a render cycle after every `stopPlayback()`. Check on a phone: that a buffer
    /// scheduled at a host time starts within a sample of where this says (the splice check would show it), and that
    /// appending after a buffer placed at a host time is seamless.
    mutating func schedule(_ samples: [Float], on channel: SpeakerChannel, mode: PlaybackMode) throws(AudioIOError) -> Int64 {
        guard let engine, engine.isRunning, let player, let outputFormat, let tap else { throw .notRunning }
        guard !samples.isEmpty else { throw .unavailable("an empty buffer") }
        let anchor = tap.anchor.load(ordering: .acquiring)
        guard anchor.second != 0 else { throw .unavailable("no microphone block yet") }

        let sampleRate = outputFormat.sampleRate
        let anchorPosition = Double(Int(bitPattern: anchor.first))
        let anchorSeconds = AVAudioTime.seconds(forHostTime: UInt64(anchor.second))
        let captureNow = anchorPosition + (AVAudioTime.seconds(forHostTime: mach_absolute_time()) - anchorSeconds) * sampleRate
        let earliest = Int64(captureNow.rounded()) + Int64(EngineAudioIO.schedulingLead * sampleRate)
        func hostTime(at position: Int64) -> AVAudioTime {
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: anchorSeconds + (Double(position) - anchorPosition) / sampleRate))
        }

        let start: Int64
        var when: AVAudioTime?
        var options: AVAudioPlayerNodeBufferOptions = []
        switch mode {
        case .once, .loop:
            guard loop == nil else { throw .unavailable("a loop is playing; end it with afterLoop") }
            if let queueEnd, queueEnd >= earliest {
                start = queueEnd
            } else {
                start = earliest
                when = hostTime(at: start)
            }
            if mode == .loop { options = .loops }
        case .afterLoop:
            guard let loop else { throw .unavailable("no loop is playing") }
            let from = max(earliest, loop.start)
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
        player.scheduleBuffer(buffer, at: when, options: options, completionHandler: nil)

        switch mode {
        case .once: queueEnd = start + Int64(samples.count)
        case .loop: loop = (start, Int64(samples.count)); queueEnd = nil
        case .afterLoop: loop = nil; queueEnd = start + Int64(samples.count)
        }
        return start
    }

    mutating func stopPlayback() {
        guard let player else { return }
        Self.fadeOut(player)
        // Stopping drops every queued buffer and resets the player's timeline; nothing here depends on it.
        player.stop()
        player.volume = 1
        player.play()
        queueEnd = nil
        loop = nil
    }

    /// Steps the player's volume down over `EngineAudioIO.stopFade` before it is stopped, so the cut does not click.
    static func fadeOut(_ player: AVAudioPlayerNode) {
        let steps = 4
        for step in stride(from: steps - 1, through: 0, by: -1) {
            player.volume = Float(step) / Float(steps)
            usleep(useconds_t(EngineAudioIO.stopFade / Double(steps) * 1_000_000))
        }
    }
}
#endif
