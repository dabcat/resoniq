import ResoniqDSP

/// Where the phone is for one capture of a seat measurement, in the order they are taken: the seat, then 30 cm to
/// the left, then 30 cm to the right ("Seat · Left · Right").
public enum SeatSpot: Int, Sendable, Hashable, CaseIterable {
    case seat
    case left
    case right

    /// 0-based position in the procedure.
    public var index: Int { rawValue }

    /// How far the left and right spots are from the seat, metres: the one definition that the instruction
    /// ("Now move the phone 30 cm to your left.") and the plan's spot markers read. *First guess*: 30 cm, a short
    /// step of the hand at ear height, enough for a room mode to change, too little for the speakers' sound to.
    public static let spacing: Double = 0.30
}

/// One spot's captures.
public struct SeatSpotRecording: Sendable, Equatable {
    public var spot: SeatSpot
    /// One checked recording per channel the measurement plays (`left` and `right` for a pair, `both` for one
    /// speaker). Each recording's `run` is the channel's 1-based place in that order.
    public var recordings: [SpeakerChannel: RunRecording]
    /// Whether the phone moved while any of the spot's sweeps played (`RunRecording.phoneMoved`).
    public var phoneMoved: Bool
    /// Whether the phone was seen to move away from the previous spot before this one was captured. Always true for
    /// the first spot. False when the stillness monitor reported no movement within
    /// `SeatMeasurementSession.movementTimeout` and the spot was captured anyway: it may be the previous position
    /// again.
    public var movementDetected: Bool

    public init(spot: SeatSpot, recordings: [SpeakerChannel: RunRecording], phoneMoved: Bool, movementDetected: Bool) {
        self.spot = spot
        self.recordings = recordings
        self.phoneMoved = phoneMoved
        self.movementDetected = movementDetected
    }

    /// The recording made on `channel`.
    public func recording(for channel: SpeakerChannel) -> RunRecording? { recordings[channel] }
}

/// The outcome of a finished seat measurement: the recordings of every spot captured, and what they were measured
/// against. Fewer than three spots when the user skipped to the result; the analysis then says it is inconclusive.
public struct SeatMeasurementResult: Sendable, Equatable {
    /// The channels played at each spot, in order.
    public var channels: [SpeakerChannel]
    public var sweep: LogSweep
    public var noiseFloor: NoiseFloorReport
    /// In capture order.
    public var spots: [SeatSpotRecording]

    /// Whether every spot was captured.
    public var isComplete: Bool { spots.count == SeatSpot.allCases.count }
}

/// What the Three spots screen shows while a seat measurement runs.
public struct SeatMeasurementProgress: Sendable, Equatable {
    /// The spot being waited for or captured.
    public var spot: SeatSpot
    /// Spots captured so far ("Building the average · 1 of 3 in").
    public var spotsCaptured: Int
    public var spotCount: Int
    /// The channel whose sweep is playing; nil while waiting for the phone to settle.
    public var channel: SpeakerChannel?
    /// The sweep frequency arriving at the microphone now; nil before the sweep has been heard, while paused and
    /// while waiting.
    public var frequency: Double?
    /// How far through the sweep the arriving sound is, 0 to 1; nil when `frequency` is.
    public var sweepFraction: Double?
    /// The room without the sweep ("Room: Quiet · 33 dB" with `SoundLevel.approximateDecibels`).
    public var roomLevel: SoundLevel
    /// The most `roomLevel` may be for a paused measurement to resume; nil before the noise floor is known.
    public var quietEnoughLevel: SoundLevel?
    /// Whether the room is at or under the mark ("Quiet").
    public var isRoomQuiet: Bool
    /// The microphone's level, the sweep included.
    public var inputLevel: SoundLevel
    /// The microphone's peak, dBFS.
    public var inputPeakDecibels: Float
    /// Whether the latest block clipped ("Level: Good" when false).
    public var isClipping: Bool
    /// Whether the phone is held still.
    public var isPhoneSteady: Bool
    /// While waiting for a spot: how much of `SeatMeasurementSession.stillnessHold` the phone has been still for,
    /// 0 to 1. Nil otherwise.
    public var stillness: Double?
    /// While waiting for a spot: where the wait is (waiting for the move, moved and settling, still). Nil otherwise.
    public var wait: SeatWaitPhase? = nil
    /// The route delay estimated so far, seconds.
    public var routeDelay: Double?
}

/// Where the wait for a spot is, so the screen can show one stable instruction for each part of it.
///
/// **Rule.** At the first spot there is no move to wait for: the phone is `settling` while it moves and `still`
/// while it is steady. At every later spot it is `waitingForMove` until the stillness monitor has seen it move away
/// from the previous spot (or the move was never seen and `SeatMeasurementSession.movementTimeout` lets the spot be
/// captured anyway); from then on it never goes back to `waitingForMove`, however the phone settles: `settling` while
/// it moves, `still` while it is steady and the hold is counted.
public enum SeatWaitPhase: String, Sendable, Hashable, CaseIterable {
    /// The phone has not been seen to move to the new spot yet ("Now move the phone 30 cm to your left.").
    case waitingForMove
    /// It has moved (or this is the first spot) and is still moving ("Now hold the phone still.").
    case settling
    /// It is steady; the spot is captured once it has been for `SeatMeasurementSession.stillnessHold`.
    case still

    init(firstSpot: Bool, moved: Bool, steady: Bool) {
        if !firstSpot && !moved {
            self = .waitingForMove
        } else {
            self = steady ? .still : .settling
        }
    }
}

/// A stillness monitor that is told when the seat measurement starts waiting for a spot, so a simulation can act out
/// the user moving the phone there. `MotionStillnessMonitor` does not need it; `SimulatedStillnessMonitor` uses it.
@MainActor
public protocol SpotAwareStillnessMonitor: StillnessMonitor {
    /// The measurement now waits for the phone to settle at `spot` (after moving there, for every spot but the first).
    func willWaitForStillness(at spot: SeatSpot)
}

extension MeasurementConfiguration {
    /// The configuration of a seat measurement: `standard` with a recording tail long enough for the room.
    ///
    /// `ResoniqDSP`'s `Decay` needs, after the sweep, the decay itself plus a stretch of noise (a 1 s bass decay
    /// wants about 2 s), and the room window (`ImpulseResponse.roomPostWindow`) at least 0.5 s. So `minimumTail` is
    /// 2 s, and `maximumDecay` is 3 s so even the longest route delay (`maximumRouteDelay`, 2.5 s) leaves time for
    /// that tail and the `decayHold` before the timeout (`maximumRouteDelay + maximumDecay` after the sweep was
    /// sent). `runCount` is 1: each channel plays once per spot. *First guess* against real rooms,
    /// where a bass decay over 1 s would want more.
    public static let seat = MeasurementConfiguration(runCount: 1, minimumTail: 2, maximumDecay: 3)
}
