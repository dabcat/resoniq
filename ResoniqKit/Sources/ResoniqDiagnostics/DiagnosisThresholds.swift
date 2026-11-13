import Foundation

/// Every number that turns measurements into findings, in one place.
///
/// Values marked **first guess** are reasoned starting points, checked only against simulated speakers; they must be
/// tuned on real speakers before a finding based on them is trusted. Levels are relative (dB against the speaker's
/// own response, or between two responses), never sound pressure: the microphone is not calibrated.
public struct DiagnosisThresholds: Sendable, Equatable {
    // MARK: Response

    /// The response is smoothed to 1/`smoothingFraction` octave before anything is read from it. 3, the plan's
    /// 1/3 octave: close to the ear's critical bands, and wide enough to iron out the comb of reflections a
    /// measurement at 30 cm in a room picks up.
    public var smoothingFraction: Int

    /// The width, in octaves, of the sliding median that gives the response's own trend; a dip or peak is measured
    /// against the trend, so a speaker's tilt or bass roll-off is not a deviation (a straight tilt cancels exactly in
    /// a centred median). **First guess**: 5 octaves, with outlier rejection (`Trend.of`), so a dip with the broad
    /// skirts of a Q = 1 bell still measures at nearly its full depth; 3 octaves measured such a −9 dB dip at −4.6 dB.
    public var trendWindowOctaves: Float

    /// Dips and peaks are looked for from this frequency up, in hertz. **First guess**: 50 Hz. Below it an iPhone
    /// microphone rolls off and the room's modes dominate even at 30 cm.
    public var responseLowerFrequency: Float

    /// Above this frequency a dip is `inconclusive` ("could be the phone's angle"), and peaks are not looked for: a
    /// phone microphone off axis loses the top. 14 kHz, from the plan's rules.
    public var topEndFrequency: Float

    /// How far from the trend a dip or peak must reach, in dB, to be a deviation. **First guess**: 6 dB, twice the
    /// ±3 dB the design system calls "even"; ordinary speakers measured at 30 cm stay within it after 1/3-octave
    /// smoothing.
    public var deviationDecibels: Float

    /// A deviation's edges are where it comes back within this many dB of the trend, and a driver is called "even"
    /// only where its response stays within it: `EvenBand.decibels`, the ±3 dB band the design system calls "even".
    public var edgeDecibels: Float

    /// The narrowest deviation reported, in octaves, measured between its edges. 1/3, the smoothing's own width:
    /// anything narrower is a reflection, not the speaker.
    public var minimumDeviationOctaves: Float

    // MARK: Distortion

    /// THD is smoothed to 1/`distortionSmoothingFraction` octave. 12: enough to steady the curve without blurring
    /// the edges of a buzz a fraction of an octave wide.
    public var distortionSmoothingFraction: Int

    /// Distortion is looked for from this frequency up, in hertz. **First guess**: 40 Hz; below it a healthy woofer
    /// playing loud distorts by design. THD is only read inside the DSP's trusted band for the second harmonic
    /// (`HarmonicDistortion.trustedBand(order:sweep:)`, from 80 Hz for `LogSweep.measurement`), so with the
    /// measurement sweep that band, not this, sets the bottom.
    public var distortionLowerFrequency: Float

    /// THD, in per cent, above which a band counts as buzzing. **First guess**: 10 %. A healthy speaker at a
    /// moderate level stays around 1 % in the mid and a few per cent in the deep bass; a buzzing cone or a rubbing
    /// voice coil reaches tens of per cent. A band counts only where THD is a measurement (clear of the noise floor
    /// by `SweepDistortion.measurableMarginDecibels`); the margin is the DSP's, not restated here.
    public var distortionPercent: Float

    /// The narrowest distortion band reported, in octaves. **First guess**: 1/6 octave.
    public var minimumDistortionOctaves: Float

    // MARK: Repetition

    /// Two runs' deviations are "at the same place" when their ranges overlap once each is widened by this many
    /// octaves. **First guess**: 1/3 octave, the smoothing's width.
    public var samePlaceOctaves: Float

    /// The fewest runs a deviation must appear in to be reported. 2, from the plan: in one run it is dropped.
    public var minimumAgreeingRuns: Int

    /// The fewest valid runs needed to conclude anything. 2, because a deviation needs two runs to be reported.
    public var minimumValidRuns: Int

    /// A deviation in at least this many runs, and in every valid run, is reported with medium confidence;
    /// otherwise low. 3, the plan's "3 of 3 runs". Confidence is never high from one microphone position.
    public var mediumConfidenceRuns: Int

    // MARK: Left and right

    /// How far two speakers' level-matched responses must differ, in dB, to be a left/right difference. **First
    /// guess**: 6 dB, the same as a deviation.
    public var leftRightDecibels: Float

    // MARK: Drivers that could not be heard

    /// A driver is "barely heard" when its median level is at least this many dB under the loudest other driver's, in
    /// at least `minimumAgreeingRuns` runs. **First guess**: 15 dB. A healthy speaker's drivers sit within a few dB
    /// of each other at 30 cm (a small woofer high-passed at 80 Hz is about 1 dB down over 100–300 Hz, a tweeter heard
    /// off axis a few dB down); a dead driver or a broken connection is 30 dB or more down.
    public var quietBandDecibels: Float

    /// The woofer's level is read from this frequency to 300 Hz, in hertz. **First guess**: 100 Hz, above the natural
    /// roll-off of all but the smallest satellites, so a gentle roll-off at the very bottom is never "barely heard".
    /// The middle driver is read over 300 Hz–3 kHz, the tweeter from 3 kHz to `topEndFrequency`.
    public var quietBandLowerFrequency: Float

    // MARK: Bass roll-off

    /// How far, in dB, the response may rise going down within a roll-off: below the knee it must fall steadily, each
    /// grid point no more than this above the next one up. **First guess**: 0.5 dB, above the ripple of a 1/3-octave
    /// smoothed median; a dip that comes back lower down rises by far more and is not a roll-off.
    public var rollOffToleranceDecibels: Float

    /// The highest knee, in hertz, accepted as a natural roll-off: `quietBandLowerFrequency` (100 Hz, **first guess**),
    /// where the quiet-band rule starts reading the woofer's level. The two rules meet there: a knee at or under it is
    /// a roll-off; above it the bass is judged as it is (uneven, or barely heard at 15 dB down), never as both.
    public var rollOffUpperFrequency: Float { quietBandLowerFrequency }

    // MARK: Noise

    /// A frequency is assessed only when its octave band's signal-to-noise ratio (recording over room floor) is at
    /// least this, in dB. **First guess**: 10 dB; the sweep's deconvolution gains a great deal on top of it.
    public var minimumBandSignalToNoise: Float

    public init(
        smoothingFraction: Int,
        trendWindowOctaves: Float,
        responseLowerFrequency: Float,
        topEndFrequency: Float,
        deviationDecibels: Float,
        edgeDecibels: Float,
        minimumDeviationOctaves: Float,
        distortionSmoothingFraction: Int,
        distortionLowerFrequency: Float,
        distortionPercent: Float,
        minimumDistortionOctaves: Float,
        samePlaceOctaves: Float,
        minimumAgreeingRuns: Int,
        minimumValidRuns: Int,
        mediumConfidenceRuns: Int,
        leftRightDecibels: Float,
        minimumBandSignalToNoise: Float,
        quietBandDecibels: Float = 15,
        quietBandLowerFrequency: Float = 100,
        rollOffToleranceDecibels: Float = 0.5
    ) {
        self.rollOffToleranceDecibels = rollOffToleranceDecibels
        self.quietBandDecibels = quietBandDecibels
        self.quietBandLowerFrequency = quietBandLowerFrequency
        self.smoothingFraction = smoothingFraction
        self.trendWindowOctaves = trendWindowOctaves
        self.responseLowerFrequency = responseLowerFrequency
        self.topEndFrequency = topEndFrequency
        self.deviationDecibels = deviationDecibels
        self.edgeDecibels = edgeDecibels
        self.minimumDeviationOctaves = minimumDeviationOctaves
        self.distortionSmoothingFraction = distortionSmoothingFraction
        self.distortionLowerFrequency = distortionLowerFrequency
        self.distortionPercent = distortionPercent
        self.minimumDistortionOctaves = minimumDistortionOctaves
        self.samePlaceOctaves = samePlaceOctaves
        self.minimumAgreeingRuns = minimumAgreeingRuns
        self.minimumValidRuns = minimumValidRuns
        self.mediumConfidenceRuns = mediumConfidenceRuns
        self.leftRightDecibels = leftRightDecibels
        self.minimumBandSignalToNoise = minimumBandSignalToNoise
    }

    /// The defaults every caller uses unless a test or a tuning session says otherwise.
    public static let standard = DiagnosisThresholds(
        smoothingFraction: 3,
        trendWindowOctaves: 5,
        responseLowerFrequency: 50,
        topEndFrequency: 14000,
        deviationDecibels: 6,
        edgeDecibels: EvenBand.decibels,
        minimumDeviationOctaves: 1.0 / 3,
        distortionSmoothingFraction: 12,
        distortionLowerFrequency: 40,
        distortionPercent: 10,
        minimumDistortionOctaves: 1.0 / 6,
        samePlaceOctaves: 1.0 / 3,
        minimumAgreeingRuns: 2,
        minimumValidRuns: 2,
        mediumConfidenceRuns: 3,
        leftRightDecibels: 6,
        minimumBandSignalToNoise: 10,
        quietBandDecibels: 15,
        quietBandLowerFrequency: 100,
        rollOffToleranceDecibels: 0.5
    )
}
