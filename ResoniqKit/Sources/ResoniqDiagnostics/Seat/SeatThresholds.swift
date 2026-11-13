import Foundation

/// Every number that turns a seat measurement into a result, and two seat measurements into a comparison.
///
/// Values marked **first guess** are reasoned starting points checked only against the simulated room in the tests;
/// they must be tuned in real rooms before a result based on them is trusted. Levels are relative (dB against the
/// seat curve's own middle, or between two curves), never sound pressure: the microphone is not calibrated.
public struct SeatThresholds: Sendable, Equatable {
    // MARK: The room curve

    /// Above the bass, a recording's room response is smoothed to 1/`smoothingFraction` octave: 3, the plan's and the
    /// mockup's 1/3 octave, close to the ear's critical bands and wide enough to iron out the comb a room's
    /// reflections lay over the response at a seat.
    public var smoothingFraction: Int

    /// In the bass, to 1/`bassSmoothingFraction` octave: 12. A room mode is narrow (Q 5 to 15, a tenth to a fifth of an
    /// octave wide); a third-octave average would take several decibels off a +9 dB mode and could hide a dip
    /// altogether. Under 200 Hz the 0.5 s room window already limits the resolution to about 2 Hz. **First guess.**
    public var bassSmoothingFraction: Int

    /// Where the room curve passes from the bass smoothing to the third-octave one, in hertz: 200, the top of the
    /// bass (`bassUpperFrequency`). The two are blended over an octave centred on it (a raised cosine in log
    /// frequency), so the curve has no step.
    public var smoothingCrossoverFrequency: Float

    // MARK: Evenness

    /// The seat curve's middle level is its median over this band, in hertz: 200 Hz to 4 kHz, above the room's modes
    /// and below the top octaves where the phone's angle and the room's absorption tilt the curve. 0 dB on every
    /// curve the report gives is this level.
    public var middleBand: FrequencyRange

    /// How far from the middle the seat curve may go and still be "even", in dB: ±3, the design system's even band
    /// (the response curve's `panelRaised` band, `DiagnosisThresholds.edgeDecibels`).
    public var evenBandDecibels: Float

    /// Extremes are looked for from this frequency, in hertz. **First guess**: 30 Hz. Below it most speakers and the
    /// phone's microphone roll off; a dip that runs into this edge is that roll-off, not the room, and is ignored.
    public var lowerFrequency: Float

    /// …up to this one, in hertz. **First guess**: 10 kHz. Above it the phone's angle and the room's absorption bend
    /// the curve more than the system does (`DiagnosisThresholds.topEndFrequency` is 14 kHz at 30 cm; at the seat
    /// the treble arrives weaker and more off axis).
    public var upperFrequency: Float

    /// The top of the bass, in hertz: 200, roughly the Schroeder frequency of a living room, under which the room's
    /// modes rather than its reflections shape the response, and moving a speaker can change it. **First guess.**
    public var bassUpperFrequency: Float

    /// Where "voices" end and "treble" begins in the words, in hertz: 3 kHz, the crossover `DriverBand` uses.
    public var trebleLowerFrequency: Float

    /// The narrowest extreme reported, in octaves, between where it leaves and re-enters the even band: 1/24, half
    /// the bass smoothing's width. Anything narrower is the comb of a reflection or noise.
    public var minimumExtremeOctaves: Float

    /// A bass dip at least this deep, in dB, "nearly vanishes"; a shallower one is "quiet". The same depth splits a
    /// boom that is "strong" from one that is "a little strong". **First guess**: 8 dB, a little under half as loud
    /// as its neighbours.
    public var vanishingDipDecibels: Float

    // MARK: Left and right

    /// Left is compared with right from this frequency, in hertz: 200, above the bass, where two speakers in
    /// different places always differ because the room's modes couple to them differently. Up to `upperFrequency`.
    public var leftRightLowerFrequency: Float

    /// Left and right "match" while their curves (each averaged over the spots, not level-matched, so a balance
    /// error counts) stay within this many dB of each other. **First guess**: 3 dB, the even band's half-width; a
    /// 3 dB level difference pulls the stereo image noticeably towards one side.
    public var leftRightDecibels: Float

    // MARK: The cause

    /// A bass extreme is "narrow", as a room mode is, when it leaves the even band over no more than this many
    /// octaves. **First guess**: half an octave; a speaker's own bass bump or a boundary dip is broader.
    public var narrowOctaves: Float

    /// The spots "disagree" at an extreme when the spot-to-spot spread there (`ResponseAverage.spread`) is at least
    /// this, in dB. A speaker's own response does not change over 60 cm; a room's modes and reflections do.
    /// **First guess**: 3 dB, the even band's half-width.
    public var spotDisagreementDecibels: Float

    /// An extreme lies on a room mode when its frequency is within this many octaves of an axial mode computed from
    /// the room's size. **First guess**: 1/24 octave (3 %): a scan's dimensions are good to a few centimetres, and
    /// real walls shift a mode a little; wider, and the modes of a large room would cover the whole bass by chance.
    public var roomModeOctaves: Float

    /// Axial modes are computed up to this frequency, in hertz: `bassUpperFrequency`.
    public var roomModeUpperFrequency: Float

    // MARK: Distortion and decay

    /// The mid frequency distortion is reported at, in hertz: 1 kHz, as the mockup's numbers show.
    public var distortionFrequency: Float

    /// THD is smoothed to 1/`distortionSmoothingFraction` octave before it is read there: 3, so the one figure is
    /// steady.
    public var distortionSmoothingFraction: Int

    /// A seat figure (distortion, decay) is given only when at least this share of the valid recordings has one;
    /// it is then their median. 1/2.
    public var minimumFigureShare: Float

    // MARK: Spots and noise

    /// Valid spots needed for a result: 3, from the plan, so one odd spot cannot decide it.
    public var requiredSpots: Int

    /// A frequency is assessed only where every valid recording's octave band holds at least this much signal over
    /// the room's noise, in dB: `DiagnosisThresholds.minimumBandSignalToNoise`'s 10. **First guess.**
    public var minimumBandSignalToNoise: Float

    // MARK: Comparison

    /// The least change, in dB, that counts as a change between two seat measurements: 1.5. The seat curve is an
    /// average of three spots placed by hand, and placing them again a few centimetres off moves the average by
    /// about this much at a mode even when nothing else changed. **First guess.**
    public var repeatabilityDecibels: Float

    /// Where the spots disagree, the repeatability widens to this share of the two measurements' mean spot-to-spot
    /// spread at the frequency: the more the curve changes over 60 cm, the more it changes when the spots are
    /// re-placed. **First guess**: 1/4.
    public var repeatabilitySpreadShare: Float

    /// A comparison looks for the targeted extreme in the second measurement within this many octaves of where it
    /// was: 1/6, so a mode that moved a little is still the same note.
    public var samePlaceOctaves: Float

    public init(
        smoothingFraction: Int,
        bassSmoothingFraction: Int,
        smoothingCrossoverFrequency: Float,
        middleBand: FrequencyRange,
        evenBandDecibels: Float,
        lowerFrequency: Float,
        upperFrequency: Float,
        bassUpperFrequency: Float,
        trebleLowerFrequency: Float,
        minimumExtremeOctaves: Float,
        vanishingDipDecibels: Float,
        leftRightLowerFrequency: Float,
        leftRightDecibels: Float,
        narrowOctaves: Float,
        spotDisagreementDecibels: Float,
        roomModeOctaves: Float,
        roomModeUpperFrequency: Float,
        distortionFrequency: Float,
        distortionSmoothingFraction: Int,
        minimumFigureShare: Float,
        requiredSpots: Int,
        minimumBandSignalToNoise: Float,
        repeatabilityDecibels: Float,
        repeatabilitySpreadShare: Float,
        samePlaceOctaves: Float
    ) {
        self.smoothingFraction = smoothingFraction
        self.bassSmoothingFraction = bassSmoothingFraction
        self.smoothingCrossoverFrequency = smoothingCrossoverFrequency
        self.middleBand = middleBand
        self.evenBandDecibels = evenBandDecibels
        self.lowerFrequency = lowerFrequency
        self.upperFrequency = upperFrequency
        self.bassUpperFrequency = bassUpperFrequency
        self.trebleLowerFrequency = trebleLowerFrequency
        self.minimumExtremeOctaves = minimumExtremeOctaves
        self.vanishingDipDecibels = vanishingDipDecibels
        self.leftRightLowerFrequency = leftRightLowerFrequency
        self.leftRightDecibels = leftRightDecibels
        self.narrowOctaves = narrowOctaves
        self.spotDisagreementDecibels = spotDisagreementDecibels
        self.roomModeOctaves = roomModeOctaves
        self.roomModeUpperFrequency = roomModeUpperFrequency
        self.distortionFrequency = distortionFrequency
        self.distortionSmoothingFraction = distortionSmoothingFraction
        self.minimumFigureShare = minimumFigureShare
        self.requiredSpots = requiredSpots
        self.minimumBandSignalToNoise = minimumBandSignalToNoise
        self.repeatabilityDecibels = repeatabilityDecibels
        self.repeatabilitySpreadShare = repeatabilitySpreadShare
        self.samePlaceOctaves = samePlaceOctaves
    }

    /// The defaults every caller uses unless a test or a tuning session says otherwise.
    public static let standard = SeatThresholds(
        smoothingFraction: 3,
        bassSmoothingFraction: 12,
        smoothingCrossoverFrequency: 200,
        middleBand: FrequencyRange(lower: 200, upper: 4000),
        evenBandDecibels: 3,
        lowerFrequency: 30,
        upperFrequency: 10000,
        bassUpperFrequency: 200,
        trebleLowerFrequency: 3000,
        minimumExtremeOctaves: 1.0 / 24,
        vanishingDipDecibels: 8,
        leftRightLowerFrequency: 200,
        leftRightDecibels: 3,
        narrowOctaves: 0.5,
        spotDisagreementDecibels: 3,
        roomModeOctaves: 1.0 / 24,
        roomModeUpperFrequency: 200,
        distortionFrequency: 1000,
        distortionSmoothingFraction: 3,
        minimumFigureShare: 0.5,
        requiredSpots: 3,
        minimumBandSignalToNoise: 10,
        repeatabilityDecibels: 1.5,
        repeatabilitySpreadShare: 0.25,
        samePlaceOctaves: 1.0 / 6
    )

    /// The weight of the third-octave curve at `frequency` in the room curve: 0 half an octave under
    /// `smoothingCrossoverFrequency`, 1 half an octave over it, a raised cosine in log frequency between.
    func coarseWeight(at frequency: Float) -> Float {
        let octaves = log2(frequency / smoothingCrossoverFrequency) + 0.5
        guard octaves > 0 else { return 0 }
        guard octaves < 1 else { return 1 }
        return 0.5 * (1 - cos(Float.pi * octaves))
    }
}
