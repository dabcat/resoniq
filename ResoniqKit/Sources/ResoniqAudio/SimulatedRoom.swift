import Foundation

/// A listening room for `SimulatedAudioIO`: a few bass modes whose level changes from spot to spot and between the
/// left and right speaker, and a diffuse reverberant tail with a known decay. Everything about it is known exactly,
/// so a test can say what a seat measurement should find: each spot's response (`magnitude(at:spot:channel:sampleRate:)`)
/// and the decay (`reverberationTime`, and each mode's `decayTime(sampleRate:)`).
///
/// **A mode** is a resonance added to the direct sound, `y = x + g · B(x)`, where `B` is a band-pass of 0 dB peak
/// gain at the mode's frequency with the mode's Q, and `g = 10^(dB/20) − 1` sets its level at that spot: positive
/// decibels a peak, negative a dip. Its poles, and so its decay, do not depend on `g`, as in a real room, where a
/// mode rings for the same time everywhere and only its level changes with position.
///
/// **The tail** is four parallel feedback combs (Schroeder) fed by the sound at the microphone and scaled by
/// `reverberationLevel`; each comb's feedback is set so that it decays by 60 dB in `reverberationTime` at every
/// frequency. It is the same at every spot.
public struct SimulatedRoom: Sendable, Hashable {
    /// One room mode.
    public struct Mode: Sendable, Hashable {
        /// Hertz.
        public var frequency: Double
        /// The resonance's quality factor; with the frequency it fixes the decay (`decayTime(sampleRate:)`).
        public var q: Double
        /// The mode's level at its frequency at each spot, in dB relative to the sound without it: positive a peak,
        /// negative a dip. One entry per spot; the room's spot count is the shortest of these.
        public var decibels: [Double]

        public init(frequency: Double, q: Double, decibels: [Double]) {
            precondition(frequency > 0 && q > 0 && !decibels.isEmpty, "a mode needs a frequency, a Q and a level per spot")
            self.frequency = frequency
            self.q = q
            self.decibels = decibels
        }

        /// Seconds the mode takes to ring down by 60 dB at `sampleRate`, from its poles.
        public func decayTime(sampleRate: Double) -> Double {
            let section = Biquad.resonator(frequency: frequency, q: q, sampleRate: sampleRate)
            return -3 * log(10) / log(section.a2.squareRoot()) / sampleRate
        }

        /// The Q that gives a mode at `frequency` a 60 dB decay of `decayTime` seconds at `sampleRate`.
        public static func q(forDecay decayTime: Double, frequency: Double, sampleRate: Double) -> Double {
            let radius = pow(10, -3 / (decayTime * sampleRate))
            let a2 = radius * radius
            let alpha = (1 - a2) / (1 + a2)
            return sin(2 * Double.pi * frequency / sampleRate) / (2 * alpha)
        }
    }

    /// The comb delays of the tail, seconds: mutually prime-ish lengths around 30–45 ms (Schroeder's).
    public static let combDelays: [Double] = [0.0297, 0.0371, 0.0411, 0.0437]

    public var modes: [Mode]
    /// Added to every mode's level for the right speaker, dB: the two speakers excite the modes a little differently.
    public var rightOffsetDecibels: Double
    /// Seconds for the reverberant tail to decay by 60 dB, at every frequency.
    public var reverberationTime: Double
    /// The linear gain into the tail. 0 removes it.
    public var reverberationLevel: Double

    public init(modes: [Mode], rightOffsetDecibels: Double = 0, reverberationTime: Double = 0.5, reverberationLevel: Double = 0.05) {
        precondition(reverberationTime > 0 && reverberationLevel >= 0, "the tail needs a positive decay")
        self.modes = modes
        self.rightOffsetDecibels = rightOffsetDecibels
        self.reverberationTime = reverberationTime
        self.reverberationLevel = reverberationLevel
    }

    /// The spots the room describes: the fewest levels any mode gives (1 for a room without modes).
    public var spotCount: Int { modes.map(\.decibels.count).min() ?? 1 }

    /// A living room seen from three spots (seat, 30 cm left, 30 cm right): modes at 38, 57 and 85 Hz that ring for
    /// 0.5 s (their Q is set for that at 48 kHz), a tail of 0.5 s at −26 dB, and the right speaker 1 dB stronger in
    /// the modes. The bass decay a seat measurement should find is 0.5 s.
    public static let livingRoom = SimulatedRoom(
        modes: [
            Mode(frequency: 38, q: Mode.q(forDecay: 0.5, frequency: 38, sampleRate: 48000), decibels: [12, 9, 14]),
            Mode(frequency: 57, q: Mode.q(forDecay: 0.5, frequency: 57, sampleRate: 48000), decibels: [-5, 2, -2]),
            Mode(frequency: 85, q: Mode.q(forDecay: 0.5, frequency: 85, sampleRate: 48000), decibels: [5, 7, 1]),
        ],
        rightOffsetDecibels: 1,
        reverberationTime: 0.5,
        reverberationLevel: 0.05
    )

    /// A mode's linear gain `g` for `channel` at `spot`.
    func modeGain(_ mode: Mode, spot: Int, channel: SpeakerChannel) -> Double {
        let level = mode.decibels[min(max(spot, 0), mode.decibels.count - 1)] + (channel == .right ? rightOffsetDecibels : 0)
        return pow(10, level / 20) - 1
    }

    /// Each comb's feedback for the tail's decay at `sampleRate`, with its delay in samples.
    func combs(sampleRate: Double) -> [(delay: Int, feedback: Double)] {
        Self.combDelays.map { seconds in
            let delay = max(1, Int((seconds * sampleRate).rounded()))
            return (delay, pow(10, -3 * Double(delay) / (sampleRate * reverberationTime)))
        }
    }

    /// |H(f)| of the room alone for one speaker (`left` or `right`; `both` reads as `left`) at `spot`: the modes on
    /// that speaker's path, then the tail. Multiply by `SimulatedSpeaker.linearGain(at:sampleRate:)` for what the
    /// microphone hears from that speaker.
    public func magnitude(at frequency: Double, spot: Int, channel: SpeakerChannel, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        var path = Complex(1, 0)
        for mode in modes {
            let band = Biquad.resonator(frequency: mode.frequency, q: mode.q, sampleRate: sampleRate).response(at: w)
            path = path * (Complex(1, 0) + band * modeGain(mode, spot: spot, channel: channel))
        }
        var tail = Complex(0, 0)
        for comb in combs(sampleRate: sampleRate) {
            let delayed = Complex(cos(-w * Double(comb.delay)), sin(-w * Double(comb.delay)))
            tail = tail + delayed / (Complex(1, 0) - delayed * comb.feedback)
        }
        return (path * (Complex(1, 0) + tail * reverberationLevel)).magnitude
    }
}

/// A complex number, for evaluating the simulation's transfer functions.
struct Complex: Sendable {
    var real: Double
    var imaginary: Double

    init(_ real: Double, _ imaginary: Double) {
        self.real = real
        self.imaginary = imaginary
    }

    var magnitude: Double { (real * real + imaginary * imaginary).squareRoot() }

    static func + (a: Complex, b: Complex) -> Complex { Complex(a.real + b.real, a.imaginary + b.imaginary) }
    static func - (a: Complex, b: Complex) -> Complex { Complex(a.real - b.real, a.imaginary - b.imaginary) }
    static func * (a: Complex, b: Complex) -> Complex {
        Complex(a.real * b.real - a.imaginary * b.imaginary, a.real * b.imaginary + a.imaginary * b.real)
    }
    static func * (a: Complex, b: Double) -> Complex { Complex(a.real * b, a.imaginary * b) }
    static func / (a: Complex, b: Complex) -> Complex {
        let denominator = b.real * b.real + b.imaginary * b.imaginary
        return Complex(
            (a.real * b.real + a.imaginary * b.imaginary) / denominator,
            (a.imaginary * b.real - a.real * b.imaginary) / denominator
        )
    }
}

extension Biquad {
    /// A band-pass of 0 dB peak gain at `frequency` (RBJ, constant peak gain): a room mode's resonance.
    static func resonator(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let (w, alpha) = prewarp(frequency, q, sampleRate)
        let a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
    }

    /// H(e^{jw}).
    func response(at w: Double) -> Complex {
        func evaluate(_ c0: Double, _ c1: Double, _ c2: Double) -> Complex {
            Complex(c0 + c1 * cos(w) + c2 * cos(2 * w), -c1 * sin(w) - c2 * sin(2 * w))
        }
        return evaluate(b0, b1, b2) / evaluate(1, a1, a2)
    }
}

/// The room's signal path with its memory: per spot and speaker, the modes; then the shared tail.
struct RoomChain: Sendable {
    struct Mode: Sendable {
        var band: Biquad.Running
        let gain: Double
    }

    struct Comb: Sendable {
        var buffer: [Double]
        var index = 0
        let feedback: Double

        mutating func process(_ x: Double) -> Double {
            let out = buffer[index]
            buffer[index] = x + feedback * out
            index = (index + 1) % buffer.count
            return out
        }
    }

    /// Every path's modes in one flat array, path by path: spot by spot, left then right (`[spot][side][mode]`
    /// flattened, so the per-sample loop does not walk nested arrays).
    var modes: [Mode]
    let modesPerPath: Int
    let spotCount: Int
    var combs: [Comb]
    let level: Double

    init(_ room: SimulatedRoom, sampleRate: Double) {
        modes = (0..<room.spotCount).flatMap { spot in
            [SpeakerChannel.left, .right].flatMap { channel in
                room.modes.map { mode in
                    Mode(
                        band: Biquad.Running(section: .resonator(frequency: mode.frequency, q: mode.q, sampleRate: sampleRate)),
                        gain: room.modeGain(mode, spot: spot, channel: channel)
                    )
                }
            }
        }
        modesPerPath = room.modes.count
        spotCount = room.spotCount
        combs = room.combs(sampleRate: sampleRate).map { Comb(buffer: [Double](repeating: 0, count: $0.delay), feedback: $0.feedback) }
        level = room.reverberationLevel
    }

    /// One speaker's direct sound through its modes at `spot`.
    mutating func path(_ x: Double, spot: Int, right: Bool) -> Double {
        let spot = min(max(spot, 0), spotCount - 1)
        var index = (spot * 2 + (right ? 1 : 0)) * modesPerPath
        let end = index + modesPerPath
        var y = x
        while index < end {
            y += modes[index].gain * modes[index].band.process(y)
            index += 1
        }
        return y
    }

    /// The sound at the microphone with the tail added.
    mutating func tail(_ x: Double) -> Double {
        guard level > 0 else { return x }
        var sum = 0.0
        var index = 0
        while index < combs.count {
            sum += combs[index].process(x)
            index += 1
        }
        return x + level * sum
    }
}
