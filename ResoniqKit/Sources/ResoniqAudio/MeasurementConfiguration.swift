import ResoniqDSP

/// Every number that shapes one speaker test, in one place. Times are seconds. Values marked *first guess* are
/// reasoned starting points to be tuned on a device with real speakers.
public struct MeasurementConfiguration: Sendable, Equatable {
    // MARK: The test

    /// Runs of the sweep in one test. Three, because a finding is only "Inferred" when it repeats ("3 of 3 runs").
    /// The sweep itself is not configured here: every run plays `LogSweep.measurement(sampleRate:)`, the one
    /// definition of the measurement sweep (10 Hz to 22 kHz over 4 s, at the safe level).
    public var runCount: Int

    /// The length of the blocks every live decision is made on. 100 ms, the block `NoiseGate` and the noise floor's
    /// steadiness are defined on.
    public var blockDuration: Double

    // MARK: Noise floor

    /// Discarded after the stream starts, while the input settles. *First guess*: 0.2 s.
    public var settleDuration: Double
    /// The quiet recording the floor is measured from. About a second (plan, "How a test works").
    public var noiseFloorDuration: Double
    /// The longest the test listens for a steady, quiet enough floor (after `settleDuration`) before it ends as
    /// `MeasurementFailure.tooNoisy`, so a loud or unsteady room never leaves "Stay quiet while I listen to the room"
    /// up for ever. *First guess*: 30 s, as `maximumPauseWait`.
    public var maximumFloorWait: Double

    // MARK: Recording a run

    /// Recording kept before the sweep's scheduled first sample, so a device latency that puts the scheduled
    /// position a little late cannot cut the sweep's start. The recording's first sample is this long before the
    /// sweep's scheduled start.
    public var leadIn: Double
    /// The longest delay a route to the speakers may add. AirPlay is documented at about two seconds.
    /// *First guess*: 2.5 s.
    public var maximumRouteDelay: Double
    /// After the sweep's end has arrived, the room must be quiet enough for this long before the recording stops.
    /// *First guess*: 0.3 s.
    public var decayHold: Double
    /// Recording kept after the sweep's end arrives, at the least: `HarmonicDistortion.minimumTail` (about 0.2 s, the
    /// response's own window plus the longest harmonic window), so the analysis can measure the noise floor that
    /// decides whether distortion is measurable. Measured from the live arrival estimate, which is good to a fraction
    /// of a block; the `decayHold` that follows normally adds more.
    public var minimumTail: Double
    /// After the sweep has been sent, the recording waits at most `maximumRouteDelay` plus this for the end to
    /// arrive and die away. *First guess*: 1 s.
    public var maximumDecay: Double

    // MARK: Pause and splice

    /// How long the room must stay quiet enough (`NoiseGate.isQuietEnough`) before a paused run resumes.
    /// *First guess*: 0.5 s.
    public var resumeHold: Double
    /// How much earlier than the moment the noise began the resumed take starts in the sweep. Must cover
    /// `noiseGuard + crossfade + fadeIn + delayMargin`. *First guess*: 0.4 s, which also lets a room's reverberation
    /// of the resumed take's first frequencies build up before the splice.
    public var resumeOverlap: Double
    /// The noise is taken to have begun this long before the first block that was too noisy, since it may have
    /// started under the threshold. One block.
    public var noiseGuard: Double
    /// The raised-cosine crossfade between two takes. *First guess*: 20 ms.
    public var crossfade: Double
    /// The resumed take's raised-cosine fade in, so it starts without a click. 20 ms, the sweep's own fade.
    public var fadeIn: Double
    /// How far the route-delay estimate may be off; the splice keeps at least this clear of the resumed take's fade
    /// in. *First guess*: 0.1 s, twice the worst bias of a per-block estimate.
    public var delayMargin: Double
    /// Times one run may start over from the beginning (noise too early, lost samples) before it counts as a bad
    /// recording. *First guess*: 3.
    public var maximumRestarts: Int
    /// Times one run may pause for noise. Past it, noise no longer pauses the run: it is recorded through, and the
    /// recording's check decides. *First guess*: 6.
    public var maximumPauses: Int
    /// The longest a paused run waits for the room to quieten before the test ends as `MeasurementFailure.tooNoisy`.
    /// *First guess*: 30 s; the screen offers "Stop and start over" meanwhile.
    public var maximumPauseWait: Double
    /// Noise that begins again within this much of the sweep (seconds of sweep) of where it paused the run before is
    /// tied to the sweep (a rattle, the room's reverberation), not the room's background: the run no longer pauses for
    /// it there and is marked (`RunRecording.sweepTiedSound`). *First guess*: 0.15 s, one and a half blocks, so the
    /// same sound found a block early or late still counts while speech that happens to start again soon after a
    /// resume rarely does.
    public var sweepTiedTolerance: Double
    /// The most two takes of a run may be out of line where they overlap, seconds, for them to be spliced. A splice
    /// assumes the route's delay did not change between them; a Bluetooth or AirPlay route can drift, and 5 samples at
    /// 48 kHz (0.1 ms) cost 2 dB at 3.2 kHz (1 dB after third-octave smoothing). Takes further apart start the run
    /// over instead. *First guess*: 30 µs, about 1.5 samples at 48 kHz.
    public var maximumSpliceMisalignment: Double

    public init(
        runCount: Int = 3,
        blockDuration: Double = 0.1,
        settleDuration: Double = 0.2,
        noiseFloorDuration: Double = 1,
        leadIn: Double = 0.05,
        maximumRouteDelay: Double = 2.5,
        decayHold: Double = 0.3,
        minimumTail: Double = HarmonicDistortion.minimumTail,
        maximumDecay: Double = 1,
        resumeHold: Double = 0.5,
        resumeOverlap: Double = 0.4,
        noiseGuard: Double = 0.1,
        crossfade: Double = 0.02,
        fadeIn: Double = 0.02,
        delayMargin: Double = 0.1,
        maximumRestarts: Int = 3,
        maximumPauses: Int = 6,
        maximumPauseWait: Double = 30,
        sweepTiedTolerance: Double = 0.15,
        maximumSpliceMisalignment: Double = 0.00003,
        maximumFloorWait: Double = 30
    ) {
        self.maximumFloorWait = maximumFloorWait
        precondition(runCount > 0, "a test needs at least one run")
        precondition(
            resumeOverlap >= noiseGuard + crossfade + fadeIn + delayMargin,
            "the resume overlap must hold the guard, the crossfade, the fade in and the delay margin"
        )
        self.runCount = runCount
        self.blockDuration = blockDuration
        self.settleDuration = settleDuration
        self.noiseFloorDuration = noiseFloorDuration
        self.leadIn = leadIn
        self.maximumRouteDelay = maximumRouteDelay
        self.decayHold = decayHold
        self.minimumTail = minimumTail
        self.maximumDecay = maximumDecay
        self.resumeHold = resumeHold
        self.resumeOverlap = resumeOverlap
        self.noiseGuard = noiseGuard
        self.crossfade = crossfade
        self.fadeIn = fadeIn
        self.delayMargin = delayMargin
        self.maximumRestarts = maximumRestarts
        self.maximumPauses = maximumPauses
        self.maximumPauseWait = maximumPauseWait
        self.sweepTiedTolerance = sweepTiedTolerance
        self.maximumSpliceMisalignment = maximumSpliceMisalignment
    }

    /// The defaults the app uses.
    public static let standard = MeasurementConfiguration()

    /// The lowest stream sample rate a test runs at, hertz: 44.1 kHz, what `LogSweep.measurement(sampleRate:)`
    /// requires (its 22 kHz end must lie under the Nyquist frequency). A route that runs slower (a Bluetooth headset
    /// profile) fails the test with `MeasurementFailure.audioUnavailable` instead of playing a narrower sweep.
    public static let minimumSampleRate: Double = 44100

    /// The sweep every run plays: `LogSweep.measurement(sampleRate:)`. `sampleRate` must be at least
    /// `minimumSampleRate`.
    public func sweep(sampleRate: Double) -> LogSweep {
        LogSweep.measurement(sampleRate: sampleRate)
    }

    /// `seconds` as a whole number of samples at `sampleRate`.
    func samples(_ seconds: Double, at sampleRate: Double) -> Int {
        Int((seconds * sampleRate).rounded())
    }
}
