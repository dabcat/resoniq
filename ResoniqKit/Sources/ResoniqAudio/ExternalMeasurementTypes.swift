import ResoniqDSP

/// Why what was heard of one play of a test sound file is not enough, so the file must be played again.
public enum ExternalPlayProblem: Sendable, Equatable {
    /// A sweep was heard but its recording is unusable (`RecordingQuality.assess`: clipped, too quiet, too noisy,
    /// silent, corrupt) or does not hold the whole sweep (`didNotArrive`).
    case run(RunProblem)
    /// The timing of what was heard is another file's (`TestSoundFile.kind(forSpacing:)`,
    /// `TestSoundFile.identify(secondsAfterTone:)`): `heard` is the kind it matched. A file is recognised by its
    /// timing, never by the speaker the sound came from: one microphone cannot tell left from right.
    case wrongFile(heard: TestSoundFile.Kind)
    /// The play ended before every sweep needed was heard, or a sweep was heard without the clock tone or another
    /// sweep of the play, so which sweep of which file it was cannot be told.
    case missedSweeps
    /// Sweeps were heard but the clock tone at the start of the file was not, and no earlier play gave the player's
    /// clock; a run is never analysed uncorrected (`SweepFinder`).
    case clockUnknown
}

/// Why a listening session ended without a result.
public enum ExternalMeasurementFailure: Error, Sendable, Equatable {
    /// A failure a normal test can also end with: `permissionDenied`, `interrupted`, `routeChanged`,
    /// `audioUnavailable`, `tooNoisy` (no floor), `phoneNeverStill` (seat), `cancelled`.
    case measurement(MeasurementFailure)
    /// Nothing at all was heard above the room for `ExternalListening.nothingHeardLimit` after "Press play".
    case nothingHeard
    /// For `ExternalListening.nothingHeardLimit` sound was heard, at least `ExternalListening.unrecognisedSoundMinimum`
    /// of it, but none of it was the test sound: another file or music, a copy converted on the way, or a speaker that
    /// plays only under 150 Hz (a subwoofer alone, which this mode cannot test).
    case soundNotRecognised
    /// The player's clock is further off than `SweepFinder.maximumClockOffset` (`ratio`): something resamples the file
    /// wrongly, so its sound is pitch-shifted and cannot be measured.
    case playerClockOff(ratio: Double)
    /// The session listened for `ExternalListening.maximumListeningTime` without enough usable runs; `lastProblem` is
    /// why the latest play fell short.
    case listeningTimeUp(lastProblem: ExternalPlayProblem?)
}

/// The numbers every listening session shares. Times are seconds; values marked *first guess* are to be tuned on a
/// device with real players.
public enum ExternalListening {
    /// After "Press play" (or the latest sound heard), how long silence lasts before the progress says so
    /// (`ExternalMeasurementProgress.isSilenceLong`), so the screen can list what to check. *First guess*: 15 s,
    /// longer than a file's lead-in and clock tone.
    public static let nothingHeardHint: Double = 15
    /// How long silence lasts before the session ends as `ExternalMeasurementFailure.nothingHeard`.
    /// *First guess*: 60 s.
    public static let nothingHeardLimit: Double = 60
    /// The longest a session listens after its noise floor, plays and replays together, before it ends as
    /// `listeningTimeUp`. *First guess*: 5 minutes, about ten plays of the longest file.
    public static let maximumListeningTime: Double = 300
    /// Recording kept before a sweep's first sample, seconds: as `MeasurementConfiguration.leadIn`.
    static func leadIn(_ configuration: MeasurementConfiguration) -> Double { configuration.leadIn }
    /// How long after the latest thing heard of a play (the tone's end or a sweep's end) a play is over when nothing
    /// more comes: the longest wait a file has between two sounds (the tone to its first sweep, 6 s for a seat file
    /// of one speaker) plus the time the follower takes to recognise a sweep (about 2.5 s) and a second.
    public static let playTimeout: Double = 9.5
    /// Audio kept for cutting runs from, seconds: a sweep, its tail and the time it takes to recognise, with room.
    static let bufferHorizon: Double = 30
    /// Seconds of sound louder than the room, none of it recognised, after which the progress says the sound heard is
    /// not the test sound (`ExternalHearing.notTheTestSound`), and the session ends as `soundNotRecognised` rather
    /// than `nothingHeard`. "Louder" is `QualityThresholds.pauseMarginDecibels` over the floor, the pause rule's
    /// margin. *First guess*: 2 s.
    public static let unrecognisedSoundMinimum: Double = 2
}

/// What the phone hears while it waits for the test sound, so the screen can tell the three cases apart.
public enum ExternalHearing: Sendable, Equatable {
    /// Nothing louder than the room: the file is not playing, the volume is down or the amplifier is on another input.
    case nothing
    /// Sound louder than the room, but not the test sound: music or another file, a copy converted on the way (a
    /// lossy format), or a speaker that plays only the deep bass. Also the latest play when it was another of the
    /// test sound files (`ExternalPlayProblem.wrongFile`).
    case notTheTestSound
    /// The test sound is being heard: its tone, a sweep, or the silence between them.
    case testSound
    /// The latest play was the test sound, but too quiet or partly missing: a run too quiet, sweeps missed or cut
    /// short, or the tone missed.
    case testSoundIncomplete
}

/// What the listening screens show while a speaker test listens to another device.
public struct ExternalMeasurementProgress: Sendable, Equatable {
    /// Valid runs in hand ("2 of 3"), and how many the test needs.
    public var runsInHand: Int
    public var runsNeeded: Int
    /// The run being heard now (1-based), while a sweep is arriving; nil otherwise.
    public var hearingRun: Int?
    /// The sweep frequency arriving now, so the portrait can fill; nil when no sweep is arriving.
    public var frequency: Double?
    /// How far through the sweep the arriving sound is, 0 to 1; nil when `frequency` is.
    public var sweepFraction: Double?
    /// Whether the clock tone at the start of the file is being heard: the player has started.
    public var isHearingTone: Bool
    /// The player's clock offset measured so far, parts per million (positive: it runs fast); nil until known.
    public var clockOffsetPPM: Double?
    /// The room's level: before the sound, the block's; while a sweep plays, the same block (there is no sweep to
    /// take out, since its timing is not known in advance).
    public var roomLevel: SoundLevel
    /// The "quiet enough" mark; nil before the noise floor is known.
    public var quietEnoughLevel: SoundLevel?
    /// Whether the room is at or under the mark.
    public var isRoomQuiet: Bool
    /// The microphone's level and peak, dBFS.
    public var inputLevel: SoundLevel
    public var inputPeakDecibels: Float
    /// Whether the latest block clipped.
    public var isClipping: Bool
    public var isPhoneSteady: Bool
    /// Seconds since "Press play" or since the latest sound of the file was heard, while waiting for it; nil while
    /// something is being heard and before the floor is known.
    public var silentFor: Double?
    /// Whether `silentFor` has passed `ExternalListening.nothingHeardHint`: the screen lists what to check (the
    /// volume, the right file, the right input on the amplifier).
    public var isSilenceLong: Bool
    /// What is heard: nothing, sound that is not the test sound, the test sound, or the latest play heard but too
    /// quiet or partly missing. Each has its sentence (`ExternalSessionText.hearingLine(_:file:)`).
    public var hearing: ExternalHearing
}

/// What the Three spots screens show while a seat measurement listens to another device.
public struct ExternalSeatMeasurementProgress: Sendable, Equatable {
    public var spot: SeatSpot
    public var spotsCaptured: Int
    public var spotCount: Int
    /// The channel whose sweep is arriving, when it is known (from the file's timing); nil otherwise.
    public var channel: SpeakerChannel?
    public var frequency: Double?
    public var sweepFraction: Double?
    public var isHearingTone: Bool
    public var clockOffsetPPM: Double?
    public var roomLevel: SoundLevel
    public var quietEnoughLevel: SoundLevel?
    public var isRoomQuiet: Bool
    public var inputLevel: SoundLevel
    public var inputPeakDecibels: Float
    public var isClipping: Bool
    public var isPhoneSteady: Bool
    /// While waiting for a spot: how much of `SeatMeasurementSession.stillnessHold` the phone has been still for, 0 to
    /// 1, and where the wait is. Nil otherwise.
    public var stillness: Double?
    public var wait: SeatWaitPhase?
    /// As `ExternalMeasurementProgress`.
    public var silentFor: Double?
    public var isSilenceLong: Bool
    public var hearing: ExternalHearing
}
