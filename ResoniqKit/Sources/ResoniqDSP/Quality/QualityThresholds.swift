import Foundation

/// Every number that decides whether a recording is fit to analyse, in one place.
///
/// Levels are dBFS: decibels relative to the digital full scale of the iPhone microphone's samples. The microphone
/// is not calibrated, so none of these is a sound pressure level, and the same room reads differently on two
/// phone models. Values marked *first guess* are reasoned starting points that must be tuned on a device.
public struct QualityThresholds: Sendable, Equatable {
    // MARK: Clipping

    /// A sample at or beyond this magnitude is at digital full scale.
    ///
    /// 32767/32768, the largest 16-bit sample, so a converter that clips at 16 bits or wider is caught. Consequence:
    /// a clean sine below about 150 Hz whose crest lies within 0.0003 dB of full scale counts as clipped, since at
    /// that level the two cannot be told apart.
    public var fullScaleLevel: Float

    /// Consecutive full-scale samples that make a hard clip. Two, because one full-scale sample is a crest that
    /// happened to land on full scale, while a clipped 8 kHz tone (six samples a period) shows flat tops only two
    /// samples long.
    public var fullScaleRun: Int

    /// The fewest consecutive samples at the buffer's own extreme value that can make a flat top, the mark of an
    /// input limiter clipping below full scale. *First guess*: 8 samples (0.17 ms at 48 kHz). A longer run is a flat
    /// top only if a clean sine of its level and frequency could not hold it (`ClippingDetector`): the crest of a
    /// 20 Hz sine quantised to 16 bits repeats one value for eight samples or more and is not clipping. Mild limiting
    /// of a high tone gives shorter flat tops than this and is missed.
    public var flatTopRun: Int

    /// How close to the extreme a sample must be to count as on the flat top, as a fraction of the extreme.
    /// 10⁻⁵ (0.0001 dB): a limiter's output repeats one value, a clean crest moves by more than this between
    /// samples at any frequency the sweep plays. *First guess* for limiters that add ripple.
    public var flatTopTolerance: Float

    /// The buffer's extreme must reach this amplitude before flat tops are looked for (0.1, −20 dBFS), so a quiet
    /// or silent buffer, whose flat stretches are not a limiter, is not called clipped. *First guess*: input
    /// limiters act near full scale, a few dB below it at most.
    public var flatTopMinimumLevel: Float

    // MARK: Verdict

    /// A recording whose peak is at or below this is silent: the microphone delivered nothing. −90 dBFS is one
    /// 16-bit step (−90.3 dBFS); a working iPhone microphone's self-noise sits well above it.
    public var silencePeakDecibels: Float

    /// A recording whose peak is below this is too quiet to analyse, whatever the room. *First guess*: −40 dBFS,
    /// which leaves the sweep (played at −12 dBFS) 28 dB of loss between the speaker and the phone.
    public var minimumPeakDecibels: Float

    /// The least broadband signal-to-noise ratio, recording RMS over noise-floor RMS, a valid recording has.
    /// *First guess*: 20 dB. Sweep deconvolution recovers much more than this, but the broadband figure is
    /// dominated by low-frequency rumble, where the sweep's advantage is smallest.
    ///
    /// It is a gate for the frequency response, not for distortion. With white noise 20 dB under a sweep
    /// recording the response is within 0.06 dB once smoothed to a sixth of an octave (0.5 dB in a single bin),
    /// while sweep THD reads 2 to 5 % from the noise alone. That is why it was not raised: whether a THD figure is
    /// a measurement is decided per frequency by `SweepDistortion.isMeasurable(at:)`, against a floor measured on
    /// the recording itself, and a higher broadband gate would reject recordings whose response is fine.
    public var minimumSignalToNoiseDecibels: Float

    // MARK: Noise floor

    /// The length of the blocks a quiet recording is cut into to judge whether its level is steady, in seconds.
    /// 100 ms, the block the live gate watches.
    public var steadinessBlockDuration: Double

    /// The most the loudest block may exceed the median block for the floor to count as steady. *First guess*:
    /// 6 dB. White noise varies by a few tenths of a dB a block; a voice or a door adds 10 to 30 dB.
    public var maximumNoiseFluctuationDecibels: Float

    // MARK: Live gate

    /// A block more than this far above the baseline pauses the measurement. *First guess*: 10 dB.
    public var pauseMarginDecibels: Float

    /// A block must fall to no more than this above the baseline before the measurement resumes. *First guess*:
    /// 6 dB, 4 dB under the pause margin so the gate does not chatter around one value.
    public var resumeMarginDecibels: Float

    /// A room-only block above this pauses the measurement whatever the baseline: a room this loud is not usable
    /// even if it was this loud from the start. *First guess*: −30 dBFS. Uncalibrated; on one phone it may mean
    /// a loud conversation, on another a vacuum cleaner.
    public var pauseCeilingDecibels: Float

    /// A room-only block must fall below this before the measurement resumes. *First guess*: −34 dBFS, 4 dB under
    /// the pause ceiling for the same reason as the margins.
    public var resumeCeilingDecibels: Float

    public init(
        fullScaleLevel: Float,
        fullScaleRun: Int,
        flatTopRun: Int,
        flatTopTolerance: Float,
        flatTopMinimumLevel: Float,
        silencePeakDecibels: Float,
        minimumPeakDecibels: Float,
        minimumSignalToNoiseDecibels: Float,
        steadinessBlockDuration: Double,
        maximumNoiseFluctuationDecibels: Float,
        pauseMarginDecibels: Float,
        resumeMarginDecibels: Float,
        pauseCeilingDecibels: Float,
        resumeCeilingDecibels: Float
    ) {
        self.fullScaleLevel = fullScaleLevel
        self.fullScaleRun = fullScaleRun
        self.flatTopRun = flatTopRun
        self.flatTopTolerance = flatTopTolerance
        self.flatTopMinimumLevel = flatTopMinimumLevel
        self.silencePeakDecibels = silencePeakDecibels
        self.minimumPeakDecibels = minimumPeakDecibels
        self.minimumSignalToNoiseDecibels = minimumSignalToNoiseDecibels
        self.steadinessBlockDuration = steadinessBlockDuration
        self.maximumNoiseFluctuationDecibels = maximumNoiseFluctuationDecibels
        self.pauseMarginDecibels = pauseMarginDecibels
        self.resumeMarginDecibels = resumeMarginDecibels
        self.pauseCeilingDecibels = pauseCeilingDecibels
        self.resumeCeilingDecibels = resumeCeilingDecibels
    }

    /// The defaults every caller uses unless a test or a tuning session says otherwise. Each value's source is in
    /// its property's documentation.
    public static let standard = QualityThresholds(
        fullScaleLevel: 32767.0 / 32768.0,
        fullScaleRun: 2,
        flatTopRun: 8,
        flatTopTolerance: 1e-5,
        flatTopMinimumLevel: 0.1,
        silencePeakDecibels: -90,
        minimumPeakDecibels: -40,
        minimumSignalToNoiseDecibels: 20,
        steadinessBlockDuration: 0.1,
        maximumNoiseFluctuationDecibels: 6,
        pauseMarginDecibels: 10,
        resumeMarginDecibels: 6,
        pauseCeilingDecibels: -30,
        resumeCeilingDecibels: -34
    )
}
