import ResoniqDSP

/// What is wrong with one run's recording.
public enum RunProblem: Sendable, Equatable {
    /// `RecordingQuality.assess` judged it unfit (clipped, too quiet, too noisy, silent, or corrupt: samples that
    /// were not finite numbers).
    case unusable(RecordingVerdict)
    /// The recording does not hold the whole sweep: the route's delay was longer than the timeout, nothing was heard
    /// at all, or the recording stopped before the sweep's end arrived (`ImpulseResponse.capturesWholeSweep` on the
    /// finished recording).
    case didNotArrive
    /// Noise kept stopping the run so early that it had to start over `MeasurementConfiguration.maximumRestarts`
    /// times.
    case interruptedRepeatedly
}

/// Something the screen should say about the run being played.
public enum RunNote: Sendable, Equatable {
    /// The run is played again because its first recording was unusable.
    case repeating(RunProblem)
    /// The run started again from the beginning instead of resuming where it stopped.
    case restarted(RestartReason)
}

/// Why a test ended without a result.
public enum MeasurementFailure: Error, Sendable, Equatable {
    /// Microphone access was denied; nothing was played.
    case permissionDenied
    /// A call, alarm or another app took the audio.
    case interrupted
    /// The speakers or the microphone changed under the test.
    case routeChanged
    /// A run's recording was unusable twice.
    case recordingUnusable(RunProblem)
    /// The user stopped the test.
    case cancelled
    /// The audio could not be started; the text is for the log.
    case audioUnavailable(String)
    /// The room stayed too loud to resume for `MeasurementConfiguration.maximumPauseWait`, or gave no steady, quiet
    /// enough floor for `MeasurementConfiguration.maximumFloorWait`.
    case tooNoisy
    /// The phone never held still for `SeatMeasurementSession.stillnessHold` within
    /// `SeatMeasurementSession.maximumStillnessWait` while a spot was waited for; nothing was played at that spot.
    /// Seat measurement only.
    case phoneNeverStill
    /// The sound would come out of the phone itself (`route`), not the user's speakers; nothing was played. The
    /// screen explains how to connect the speakers.
    case speakersNotConnected(AudioOutputRoute)
}

/// One run's recording, ready for `RunAnalyzer`.
public struct RunRecording: Sendable, Equatable {
    /// 1-based.
    public var run: Int
    /// Mono, starting `leadIn` samples before the sweep's scheduled first sample and ending after its decay. Spliced
    /// takes are already joined; the recording is what one uninterrupted take would have given.
    public var samples: [Float]
    public var sampleRate: Double
    /// Samples before the sweep's scheduled first sample. A deconvolved response's delay includes it.
    public var leadIn: Int
    /// Seconds from the recording's first sample to the sweep's arrival, estimated live from the tone in each block
    /// (good to a fraction of a block; the deconvolved impulse response gives the exact figure).
    public var arrivalDelay: Double?
    /// `RecordingQuality.assess` on `samples` against the test's noise floor. Always `.valid` in a finished test.
    public var verdict: RecordingVerdict
    /// Times noise paused the run and the takes were spliced.
    public var spliceCount: Int
    /// Whether the phone moved while the sweep played. The run is kept; the analysis may weigh it.
    public var phoneMoved: Bool
    /// 1 for the first recording of the run, 2 when the first was unusable.
    public var attempt: Int
    /// Where in the sweep, in hertz, sound tied to the sweep was heard: noise that came back at the same frequency
    /// after the run paused for it and resumed, so a rattle or the room's reverberation rather than the room's
    /// background. The run did not pause for it again. Nil when there was none.
    public var sweepTiedSound: ClosedRange<Double>? = nil
    /// For each spliced take, how far its sound lay from the take before it where they overlap, samples (positive:
    /// later). Under `MeasurementConfiguration.maximumSpliceMisalignment` by construction; empty when not spliced.
    public var takeOffsets: [Double] = []
    /// Seconds from the recording's first sample to the deconvolved response's peak: the route's delay plus
    /// `leadIn`, exact where `arrivalDelay` is a live estimate. Nil when it was not measured.
    public var measuredDelay: Double? = nil
    /// When the sound was played by another device: its clock against the phone's (above 1: it ran fast), which
    /// `samples` have already been corrected for (`SweepFinder.corrected(_:ratio:)`). Nil when the phone played it.
    public var clockRatio: Double? = nil
    /// Where `clockRatio` came from; nil when the phone played the sound.
    public var clockSource: ClockSource? = nil
    /// When both the clock tone and the spacing of the play's sweeps gave the clock, how far apart they were, parts
    /// per million; nil otherwise. More than `ExternalListening.clockAgreementPPM` and the spacing was used: the phone
    /// probably moved while the tone played.
    public var clockDisagreementPPM: Double? = nil
}

/// Where a run played by another device got its clock from.
public enum ClockSource: Sendable, Hashable {
    /// The clock tone at the start of its play (`SweepFinder.clockRatio(ofTone:sampleRate:)`).
    case tone
    /// The spacing of its play's sweeps (`SweepFinder.clockFit(starts:expectedSpacing:sampleRate:)`): when there was
    /// no tone, or when the tone disagreed with it.
    case sweepSpacing
    /// The tone of an earlier play, when its own play gave neither.
    case earlierPlay
}

/// What played the test sound.
public enum PlaybackSource: Sendable, Hashable {
    /// The phone, through the user's speakers: the normal test.
    case thisPhone
    /// Another device playing a `TestSoundFile` while the phone listened (`ExternalMeasurementSession`).
    case anotherDevice
}

/// The outcome of a finished test: every run's recording, and what they were measured against.
public struct MeasurementResult: Sendable, Equatable {
    public var channel: SpeakerChannel
    public var sweep: LogSweep
    public var noiseFloor: NoiseFloorReport
    public var runs: [RunRecording]
    /// What played the sound; the runs' `clockRatio` says how far another device's clock was off.
    public var source: PlaybackSource = .thisPhone
}

/// What the Listening and Paused screens show while a test runs.
public struct MeasurementProgress: Sendable, Equatable {
    /// 1-based ("run 2 of 3").
    public var run: Int
    public var runCount: Int
    /// The sweep frequency arriving at the microphone now ("Playing now 1.02 kHz"): the frequency being sent,
    /// shifted by the route delay. Nil before the sweep has been heard, while paused, and after it has ended.
    public var frequency: Double?
    /// How far through the sweep the arriving sound is, 0 to 1; nil when `frequency` is.
    public var sweepFraction: Double?
    /// The room without the sweep: while the sweep plays, the noise left when it is taken out
    /// (`SweepNoiseDetector`); otherwise the block's level.
    public var roomLevel: SoundLevel
    /// The "quiet enough" mark: the most `roomLevel` may be for a paused test to resume. Nil before the noise floor
    /// is known.
    public var quietEnoughLevel: SoundLevel?
    /// Whether the room is at or under the mark.
    public var isRoomQuiet: Bool
    /// The microphone's level, the sweep included.
    public var inputLevel: SoundLevel
    /// The microphone's peak, dBFS.
    public var inputPeakDecibels: Float
    /// Whether the latest block clipped ("Level: Good, no clipping" when false).
    public var isClipping: Bool
    /// "Phone: Steady".
    public var isPhoneSteady: Bool
    /// The route delay estimated so far, seconds.
    public var routeDelay: Double?
}
