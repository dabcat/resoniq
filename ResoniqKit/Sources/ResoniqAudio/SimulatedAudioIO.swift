import Foundation
import Synchronization

/// A filter section of a simulated speaker, designed at the stream's sample rate (RBJ cookbook).
public enum SimulatedFilter: Sendable, Hashable {
    /// Second-order high-pass: a speaker's bass roll-off.
    case highPass(frequency: Double, q: Double)
    /// Second-order low-pass: a tweeter's top end.
    case lowPass(frequency: Double, q: Double)
    /// A bell: a resonance (positive gain) or a dip (negative), in dB.
    case peaking(frequency: Double, q: Double, gain: Double)

    /// The section's coefficients at `sampleRate`.
    func biquad(sampleRate: Double) -> Biquad {
        switch self {
        case .highPass(let frequency, let q):
            let (w, alpha) = Biquad.prewarp(frequency, q, sampleRate)
            let a0 = 1 + alpha
            return Biquad(b0: (1 + cos(w)) / 2 / a0, b1: -(1 + cos(w)) / a0, b2: (1 + cos(w)) / 2 / a0,
                          a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
        case .lowPass(let frequency, let q):
            let (w, alpha) = Biquad.prewarp(frequency, q, sampleRate)
            let a0 = 1 + alpha
            return Biquad(b0: (1 - cos(w)) / 2 / a0, b1: (1 - cos(w)) / a0, b2: (1 - cos(w)) / 2 / a0,
                          a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
        case .peaking(let frequency, let q, let gain):
            let (w, alpha) = Biquad.prewarp(frequency, q, sampleRate)
            let a = pow(10, gain / 40)
            let a0 = 1 + alpha / a
            return Biquad(b0: (1 + alpha * a) / a0, b1: -2 * cos(w) / a0, b2: (1 - alpha * a) / a0,
                          a1: -2 * cos(w) / a0, a2: (1 - alpha / a) / a0)
        }
    }

    /// |H| at `frequency` hertz for a section designed at `sampleRate`.
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        biquad(sampleRate: sampleRate).magnitude(at: frequency, sampleRate: sampleRate)
    }
}

/// A loudspeaker in the simulator: a gain, linear filters, and optionally a defect that distorts in one band.
public struct SimulatedSpeaker: Sendable, Hashable {
    /// A cubic nonlinearity acting on the band-passed signal only, `y += cubic · b³`: a driver that distorts at the
    /// frequencies of `band` and nowhere else, as a loose voice coil or a rubbing cone would.
    public struct Defect: Sendable, Hashable {
        public var band: ClosedRange<Double>
        public var cubic: Double

        public init(band: ClosedRange<Double>, cubic: Double) {
            self.band = band
            self.cubic = cubic
        }
    }

    /// A rattle: noise that is not a harmonic, made while the signal is inside `band` and in proportion to it,
    /// `y += level · |b| · n` with `b` the band-passed signal and `n` white noise. A loose panel or a buzzing grille:
    /// it follows the sweep's position, so pausing for it and resuming meets it again at the same frequency.
    public struct Rattle: Sendable, Hashable {
        public var band: ClosedRange<Double>
        /// Relative to the band-passed signal: 0.01 is 40 dB under it.
        public var level: Double

        public init(band: ClosedRange<Double>, level: Double) {
            self.band = band
            self.level = level
        }
    }

    /// Linear gain from the samples played to the microphone. 1 puts the sweep's −12 dBFS peak at the microphone
    /// before the filters.
    public var gain: Double
    public var filters: [SimulatedFilter]
    public var defect: Defect?
    public var rattle: Rattle?

    public init(gain: Double = 1, filters: [SimulatedFilter] = [], defect: Defect? = nil, rattle: Rattle? = nil) {
        self.gain = gain
        self.filters = filters
        self.defect = defect
        self.rattle = rattle
    }

    /// A small bookshelf speaker: rolls off below 70 Hz and above 18 kHz, with a mild presence peak.
    public static let bookshelf = SimulatedSpeaker(
        gain: 0.5,
        filters: [
            .highPass(frequency: 70, q: 0.707),
            .peaking(frequency: 2500, q: 1.2, gain: 3),
            .lowPass(frequency: 18000, q: 0.707),
        ]
    )

    /// |H(f)| of the linear part, gain included.
    public func linearGain(at frequency: Double, sampleRate: Double) -> Double {
        filters.reduce(gain) { $0 * $1.magnitude(at: frequency, sampleRate: sampleRate) }
    }
}

/// A burst of white noise at the microphone.
public struct NoiseBurst: Sendable, Hashable {
    public enum Start: Sendable, Hashable {
        /// Seconds after capture began.
        case at(Double)
        /// Seconds after the scheduled start of the buffer scheduled `buffer`-th (0 is the first).
        case afterScheduling(buffer: Int, offset: Double)
    }

    public var start: Start
    /// Seconds; nil for a noise that never stops.
    public var duration: Double?
    /// RMS, linear.
    public var rms: Double

    public init(start: Start, duration: Double?, rms: Double) {
        self.start = start
        self.duration = duration
        self.rms = rms
    }
}

/// An `AudioIO` with no hardware: it "plays" scheduled buffers through simulated speakers, delays them by a route
/// delay, adds room noise and bursts, clips at full scale like a converter, and delivers the result as microphone
/// blocks. For the simulator and previews, where there is no loop from a speaker to the microphone, and for tests.
///
/// Blocks are produced on demand, when the consumer asks for the next one, so everything scheduled before that moment
/// is in it, exactly as on hardware. With `.realTime` pacing each block waits until its time has come; with
/// `.immediate` it is produced at once, so a test of a minute of audio takes as long as the arithmetic.
///
/// Thread safety: all state is behind one `Mutex`, held only for the arithmetic of one call. No audio thread.
public final class SimulatedAudioIO: AudioIO {
    public enum Pacing: Sendable, Hashable {
        case realTime
        case immediate
    }

    public struct Configuration: Sendable, Hashable {
        public var sampleRate: Double
        /// Samples per delivered block; need not match the session's block.
        public var blockSize: Int
        /// Seconds from a sample being sent to the output to its sound reaching the microphone.
        public var routeDelay: Double
        /// The room's steady noise, RMS linear (1e-4 is −80 dBFS).
        public var noiseRMS: Double
        public var bursts: [NoiseBurst]
        public var left: SimulatedSpeaker
        public var right: SimulatedSpeaker
        /// How far ahead of the current position a buffer scheduled on an idle output starts, seconds.
        public var schedulingLead: Double
        public var pacing: Pacing
        public var seed: UInt64
        /// The room between the speakers and the microphone, or nil for none (the speakers straight into the
        /// microphone). With a room, `SimulatedAudioIO.moveToSpot(_:)` says where the microphone is.
        public var room: SimulatedRoom?
        /// The output route the IO reports.
        public var outputRoute: AudioOutputRoute

        public init(
            sampleRate: Double = 48000,
            blockSize: Int = 4800,
            routeDelay: Double = 0.02,
            noiseRMS: Double = 1e-4,
            bursts: [NoiseBurst] = [],
            left: SimulatedSpeaker = .bookshelf,
            right: SimulatedSpeaker = .bookshelf,
            schedulingLead: Double = 0.05,
            pacing: Pacing = .realTime,
            seed: UInt64 = 1,
            room: SimulatedRoom? = nil,
            outputRoute: AudioOutputRoute = .simulatedSpeakers
        ) {
            self.sampleRate = sampleRate
            self.blockSize = blockSize
            self.routeDelay = routeDelay
            self.noiseRMS = noiseRMS
            self.bursts = bursts
            self.left = left
            self.right = right
            self.schedulingLead = schedulingLead
            self.pacing = pacing
            self.seed = seed
            self.room = room
            self.outputRoute = outputRoute
        }
    }

    /// Waits until an instant on the continuous clock; injected so a test of real-time pacing need not sleep.
    typealias Sleeper = @Sendable (ContinuousClock.Instant) async throws -> Void

    public let configuration: Configuration
    private let state: Mutex<SimulationState>
    private let sleep: Sleeper

    public convenience init(configuration: Configuration = Configuration()) {
        self.init(configuration: configuration, sleep: { try await Task.sleep(until: $0, clock: .continuous) })
    }

    /// With real-time pacing, each block waits by calling `sleep` with the instant its time has come.
    init(configuration: Configuration, sleep: @escaping Sleeper) {
        self.configuration = configuration
        self.sleep = sleep
        state = Mutex(SimulationState(configuration: configuration))
    }

    // MARK: What a test can see

    /// Whether the stream is running.
    public var isRunning: Bool { state.withLock { $0.running } }
    /// Whether anything scheduled is still to be sent to the output.
    public var isPlaying: Bool { state.withLock { $0.isPlaying } }
    /// Buffers scheduled since the IO was made.
    public var scheduledBufferCount: Int { state.withLock { $0.scheduledCount } }
    /// Times the stream was started.
    public var startCount: Int { state.withLock { $0.startCount } }

    /// Ends the running stream with `error` at its next block, as an interruption or a route change would.
    public func fail(with error: AudioIOError) {
        state.withLock { $0.pendingError = error }
    }

    /// Changes the route delay from the next sample on: a route that drifts (Bluetooth, AirPlay). For tests; change
    /// it while nothing plays, or the sound in flight jumps.
    public func setRouteDelay(_ seconds: Double) {
        state.withLock { $0.delay = Int64((seconds * configuration.sampleRate).rounded()) }
    }

    /// The spot of `configuration.room` the microphone is at, 0-based; 0 when the stream starts.
    public var currentSpot: Int { state.withLock { $0.spot } }

    /// Moves the microphone to spot `index` of `configuration.room` (clamped to the room's spots) from the next
    /// sample on. A test or the app's simulated stillness monitor calls it when the simulated phone moves; nothing in
    /// a session does.
    public func moveToSpot(_ index: Int) {
        state.withLock { $0.spot = max(0, min(index, (configuration.room?.spotCount ?? 1) - 1)) }
    }

    // MARK: AudioIO

    public func start() async throws -> CaptureStream {
        let configuration = configuration
        let blockSeconds = Double(configuration.blockSize) / configuration.sampleRate
        let began = ContinuousClock.now
        state.withLock { $0.begin() }
        let blocks = AsyncThrowingStream<CapturedBlock, any Error>(unfolding: { [self] in
            if Task.isCancelled { return nil }
            if configuration.pacing == .realTime {
                let index = self.state.withLock { $0.deliveredBlocks }
                do {
                    try await self.sleep(began + .seconds(blockSeconds * Double(index + 1)))
                } catch {
                    return nil
                }
            }
            return try self.state.withLock { state throws(AudioIOError) in try state.nextBlock() }
        })
        return CaptureStream(sampleRate: configuration.sampleRate, blocks: blocks)
    }

    public func schedule(_ samples: [Float], on channel: SpeakerChannel, mode: PlaybackMode) throws -> Int64 {
        try state.withLock { state throws(AudioIOError) in try state.schedule(samples, on: channel, mode: mode) }
    }

    public func stopPlayback() {
        state.withLock { $0.stopPlayback() }
    }

    public func stop() async {
        state.withLock { $0.end() }
    }

    public var outputRoute: AudioOutputRoute? { configuration.outputRoute }
}

// MARK: - The simulation

/// A second-order section in direct form I, double precision.
struct Biquad: Sendable, Hashable {
    var b0, b1, b2, a1, a2: Double

    static func prewarp(_ frequency: Double, _ q: Double, _ sampleRate: Double) -> (w: Double, alpha: Double) {
        let w = 2 * Double.pi * frequency / sampleRate
        return (w, sin(w) / (2 * q))
    }

    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        func evaluate(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let real = c0 + c1 * cos(w) + c2 * cos(2 * w)
            let imaginary = -c1 * sin(w) - c2 * sin(2 * w)
            return (real * real + imaginary * imaginary).squareRoot()
        }
        return evaluate(b0, b1, b2) / evaluate(1, a1, a2)
    }

    /// The filter with its memory.
    struct Running: Sendable {
        let section: Biquad
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = section.b0 * x + section.b1 * x1 + section.b2 * x2 - section.a1 * y1 - section.a2 * y2
            (x2, x1, y2, y1) = (x1, x, y1, y)
            return y
        }
    }

    /// A band-pass with 0 dB at its centre, for a band from `low` to `high` hertz (constant peak gain).
    static func bandPass(_ band: ClosedRange<Double>, sampleRate: Double) -> Biquad {
        let centre = (band.lowerBound * band.upperBound).squareRoot()
        let q = centre / max(band.upperBound - band.lowerBound, 1)
        let (w, alpha) = prewarp(centre, q, sampleRate)
        let a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
    }
}

/// One speaker's signal chain with its memory.
struct SpeakerChain: Sendable {
    let gain: Double
    var filters: [Biquad.Running]
    var defectFilter: Biquad.Running?
    let cubic: Double
    var rattleFilter: Biquad.Running?
    let rattleLevel: Double

    init(_ speaker: SimulatedSpeaker, sampleRate: Double) {
        gain = speaker.gain
        filters = speaker.filters.map { Biquad.Running(section: $0.biquad(sampleRate: sampleRate)) }
        defectFilter = speaker.defect.map { Biquad.Running(section: Biquad.bandPass($0.band, sampleRate: sampleRate)) }
        cubic = speaker.defect?.cubic ?? 0
        rattleFilter = speaker.rattle.map { Biquad.Running(section: Biquad.bandPass($0.band, sampleRate: sampleRate)) }
        rattleLevel = speaker.rattle?.level ?? 0
    }

    /// One sample through the speaker. `random` is drawn from only when the speaker rattles, so a speaker without a
    /// rattle leaves the room's noise exactly as it was.
    mutating func process(_ input: Double, random: inout SplitMix) -> Double {
        var y = gain * input
        for index in filters.indices { y = filters[index].process(y) }
        if defectFilter != nil {
            let band = defectFilter!.process(y)
            y += cubic * band * band * band
        }
        if rattleFilter != nil {
            let band = rattleFilter!.process(y)
            y += rattleLevel * abs(band) * random.gaussian()
        }
        return y
    }
}

/// A deterministic generator (SplitMix64) and Gaussian noise from it.
struct SplitMix: Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal (Box–Muller).
    mutating func gaussian() -> Double {
        let u = (Double(next() >> 11) + 0.5) / 9_007_199_254_740_992
        let v = Double(next() >> 11) / 9_007_199_254_740_992
        return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
    }
}

struct SimulationState: Sendable {
    struct Item: Sendable {
        var start: Int64
        var samples: [Float]
        var channel: SpeakerChannel
        var loops: Bool
        /// Nothing at or after this position is sent.
        var cutoff: Int64?

        var end: Int64 {
            let natural = loops ? Int64.max : start + Int64(samples.count)
            return min(natural, cutoff ?? .max)
        }

        func sample(at position: Int64) -> Float {
            guard position >= start, position < end else { return 0 }
            let offset = Int(position - start)
            return loops ? samples[offset % samples.count] : samples[offset]
        }
    }

    struct ResolvedBurst: Sendable {
        var start: Int64
        var end: Int64
        var rms: Double
    }

    let configuration: Configuration
    var delay: Int64
    let lead: Int64
    var running = false
    var position: Int64 = 0
    var deliveredBlocks = 0
    var items: [Item] = []
    var queueEnd: Int64 = 0
    var scheduledCount = 0
    var startCount = 0
    var bursts: [ResolvedBurst] = []
    var pendingError: AudioIOError?
    var left: SpeakerChain
    var right: SpeakerChain
    var room: RoomChain?
    var spot = 0
    var random: SplitMix

    typealias Configuration = SimulatedAudioIO.Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
        delay = Int64((configuration.routeDelay * configuration.sampleRate).rounded())
        lead = Int64((configuration.schedulingLead * configuration.sampleRate).rounded())
        left = SpeakerChain(configuration.left, sampleRate: configuration.sampleRate)
        right = SpeakerChain(configuration.right, sampleRate: configuration.sampleRate)
        room = configuration.room.map { RoomChain($0, sampleRate: configuration.sampleRate) }
        random = SplitMix(state: configuration.seed)
    }

    var isPlaying: Bool {
        running && items.contains { $0.end > position }
    }

    mutating func begin() {
        running = true
        startCount += 1
        position = 0
        deliveredBlocks = 0
        items = []
        queueEnd = 0
        pendingError = nil
        left = SpeakerChain(configuration.left, sampleRate: configuration.sampleRate)
        right = SpeakerChain(configuration.right, sampleRate: configuration.sampleRate)
        room = configuration.room.map { RoomChain($0, sampleRate: configuration.sampleRate) }
        spot = 0
        bursts = configuration.bursts.compactMap { burst in
            guard case .at(let seconds) = burst.start else { return nil }
            return resolve(burst, from: Int64((seconds * configuration.sampleRate).rounded()))
        }
    }

    mutating func end() {
        running = false
        items = []
    }

    func resolve(_ burst: NoiseBurst, from start: Int64) -> ResolvedBurst {
        let end = burst.duration.map { start + Int64(($0 * configuration.sampleRate).rounded()) } ?? .max
        return ResolvedBurst(start: start, end: end, rms: burst.rms)
    }

    mutating func schedule(_ samples: [Float], on channel: SpeakerChannel, mode: PlaybackMode) throws(AudioIOError) -> Int64 {
        guard running else { throw .notRunning }
        // As `EngineAudioIO`: positions are only known once the microphone has delivered a block.
        guard deliveredBlocks > 0 else { throw .unavailable("no microphone block yet") }
        guard !samples.isEmpty else { throw .unavailable("an empty buffer") }
        let loopIndex = items.lastIndex { $0.loops && $0.end == .max }
        switch mode {
        case .once, .loop:
            guard loopIndex == nil else { throw .unavailable("a loop is playing; end it with afterLoop") }
        case .afterLoop:
            guard loopIndex != nil else { throw .unavailable("no loop is playing") }
        }
        var start = max(queueEnd, position + lead)
        if mode == .afterLoop, let index = loopIndex {
            let loop = items[index]
            let length = Int64(loop.samples.count)
            let from = max(position + lead, loop.start)
            start = loop.start + (from - loop.start + length - 1) / length * length
            items[index].cutoff = start
        }
        items.append(Item(start: start, samples: samples, channel: channel, loops: mode == .loop, cutoff: nil))
        queueEnd = mode == .loop ? .max : start + Int64(samples.count)
        for burst in configuration.bursts {
            if case .afterScheduling(let buffer, let offset) = burst.start, buffer == scheduledCount {
                bursts.append(resolve(burst, from: start + Int64((offset * configuration.sampleRate).rounded())))
            }
        }
        scheduledCount += 1
        // Forget what has finished.
        items.removeAll { $0.end <= position - delay }
        return start
    }

    mutating func stopPlayback() {
        for index in items.indices {
            items[index].cutoff = min(items[index].cutoff ?? .max, position)
        }
        queueEnd = position
    }

    mutating func nextBlock() throws(AudioIOError) -> CapturedBlock? {
        guard running else { return nil }
        if let error = pendingError {
            pendingError = nil
            running = false
            throw error
        }
        let count = configuration.blockSize
        var samples = [Float](repeating: 0, count: count)
        for offset in 0..<count {
            let capture = position + Int64(offset)
            let sent = capture - delay
            var leftInput: Float = 0
            var rightInput: Float = 0
            for item in items where sent >= item.start && sent < item.end {
                let value = item.sample(at: sent)
                switch item.channel {
                case .left: leftInput += value
                case .right: rightInput += value
                case .both: leftInput += value; rightInput += value
                }
            }
            var value: Double
            if room != nil {
                let direct = room!.path(left.process(Double(leftInput), random: &random), spot: spot, right: false)
                    + room!.path(right.process(Double(rightInput), random: &random), spot: spot, right: true)
                value = room!.tail(direct)
            } else {
                value = left.process(Double(leftInput), random: &random) + right.process(Double(rightInput), random: &random)
            }
            if configuration.noiseRMS > 0 { value += configuration.noiseRMS * random.gaussian() }
            for burst in bursts where capture >= burst.start && capture < burst.end {
                value += burst.rms * random.gaussian()
            }
            // The converter clips at full scale.
            samples[offset] = Float(min(max(value, -1), 1))
        }
        let block = CapturedBlock(position: position, samples: samples)
        position += Int64(count)
        deliveredBlocks += 1
        return block
    }
}
