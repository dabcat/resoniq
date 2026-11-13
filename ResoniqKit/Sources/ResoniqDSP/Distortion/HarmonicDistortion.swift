import Foundation

/// Harmonic distortion against frequency, from one sweep measurement.
///
/// All curves share the fundamental's frequency axis (hertz, the transform's linear grid): a point at `f` describes
/// what the speaker did while the sweep was playing `f`. Each curve covers only the band where it is accurate.
public struct SweepDistortion: Sendable, Equatable {
    /// How far, in dB, THD must read above `noiseFloor` to count as measured: 10 dB. At that margin a reading made
    /// of noise alone is about a one-in-twenty-thousand event at any one frequency, even where THD is a single
    /// harmonic (a bin's noise power is exponentially distributed: P(> 10× its mean) = e⁻¹⁰). A measured value
    /// still carries the noise: on average it reads `√(THD² + floor²)`, 0.4 dB high at the margin, and a single
    /// point scatters by up to `floor / THD` in amplitude, which a third-octave average removes. The same margin
    /// applies to `ToneDistortion`.
    public static let measurableMarginDecibels: Float = 10

    /// The linear response, in dB re the sweep, windowed exactly as `ImpulseResponse.frequencyResponse()` does with
    /// its defaults, over the response's `trustedBand`.
    public let fundamental: MagnitudeResponse
    /// For each order `n`, the level of the `n`-th harmonic produced while the sweep played `f`, in dB on the same
    /// scale as `fundamental` (so `harmonics[n] − fundamental` is the harmonic relative to the fundamental), over
    /// `HarmonicDistortion.trustedBand(order:sweep:)` within the response's trusted band. Where a speaker adds no
    /// harmonic, the curve is the noise the window collected, not zero.
    public let harmonics: [Int: MagnitudeResponse]
    /// Total harmonic distortion in dB relative to the fundamental, `10·log10(Σ hₙ² / h₁²)`, over the lowest
    /// requested order's trusted band. At each `f` it sums only the orders trusted there, so near the top it is the
    /// second harmonic alone. **Gross**: it includes the noise the harmonic windows collected, so a clean speaker
    /// reads as the floor, never as zero; read it with `noiseFloor` and `isMeasurable(at:)`. (`ToneDistortion`'s THD
    /// is net of noise instead.)
    public let thd: MagnitudeResponse
    /// What `thd` would read if the speaker added no harmonic: the noise collected by windows of exactly the
    /// harmonic windows' shapes, placed on a stretch of the response after the linear response that holds only
    /// noise, read at the same bins and smoothed over a third of an octave. Same grid as `thd`, dB re the
    /// fundamental. Nil when the recording ended too soon after the sweep to leave such a stretch
    /// (`HarmonicDistortion.minimumTail`), or for a response built by hand; then nothing is measurable.
    public let noiseFloor: MagnitudeResponse?

    public init(
        fundamental: MagnitudeResponse,
        harmonics: [Int: MagnitudeResponse],
        thd: MagnitudeResponse,
        noiseFloor: MagnitudeResponse?
    ) {
        self.fundamental = fundamental
        self.harmonics = harmonics
        self.thd = thd
        self.noiseFloor = noiseFloor
    }

    /// THD at `frequency` hertz as a percentage of the fundamental, interpolated in log frequency; NaN outside
    /// `thd`'s band, where nothing was measured.
    public func thdPercent(at frequency: Float) -> Float {
        guard Self.covers(thd, frequency) else { return .nan }
        return 100 * Decibels.toAmplitude(thd.decibels(at: frequency))
    }

    /// What noise alone reads as THD at `frequency`, as a percentage; nil where there is no floor. A THD that is not
    /// measurable there is reported as "below this plus the margin", not as a number.
    public func noiseFloorPercent(at frequency: Float) -> Float? {
        guard let noiseFloor, Self.covers(noiseFloor, frequency) else { return nil }
        return 100 * Decibels.toAmplitude(noiseFloor.decibels(at: frequency))
    }

    /// Whether THD at `frequency` is a measurement: inside `thd`'s band and at least `measurableMarginDecibels`
    /// above `noiseFloor` there. False where there is no floor. When false, all that is known is that THD is below
    /// `noiseFloorPercent(at:)` raised by the margin.
    public func isMeasurable(at frequency: Float) -> Bool {
        guard let noiseFloor, Self.covers(thd, frequency), Self.covers(noiseFloor, frequency) else { return false }
        return thd.decibels(at: frequency) - noiseFloor.decibels(at: frequency) >= Self.measurableMarginDecibels
    }

    private static func covers(_ curve: MagnitudeResponse, _ frequency: Float) -> Bool {
        guard let first = curve.frequencies.first, let last = curve.frequencies.last else { return false }
        return frequency >= first && frequency <= last
    }
}

/// Farina's method: a nonlinear system driven by an exponential sweep leaves, after deconvolution, one impulse
/// response per harmonic order, each arriving `LogSweep.harmonicAdvance(order:)` before the linear one. Windowing
/// each out and transforming it gives that harmonic's level against *its* frequency `n·f`, which maps back to the
/// fundamental `f` that produced it.
///
/// Accuracy, for a sweep of at least `minimumAccurateDuration`: a harmonic inside its `trustedBand` reads within
/// 3 % of its value (0.25 dB) on a noiseless system; THD likewise.
///
/// What it cannot tell you: the distortion of a stimulus other than a sine (music adds intermodulation, which a
/// sweep does not show), which component of the chain distorted (speaker, amplifier, microphone), or anything
/// non-harmonic such as rattles (see `ToneDistortion`). Each harmonic window is limited to the gap between
/// neighbouring harmonics, so short sweeps resolve the higher orders coarsely in frequency. Near the sweep's start
/// the harmonic chirp's own abrupt start (at `n · startFrequency`) ripples its spectrum, which is why the trusted
/// band starts `trustedStartRatio` above it.
public enum HarmonicDistortion {
    /// The orders analysed unless told otherwise.
    public static let defaultOrders = [2, 3, 4, 5]
    /// Seconds kept before each harmonic's arrival, capped at half the gap to the next higher order.
    public static let preWindow: Double = 0.005

    /// Octaves below the sweep's end frequency that no harmonic is read from. The deconvolution's sharp edge at
    /// the sweep's end rings into negative time, where the harmonic windows are; in the top 1/14 octave that
    /// ringing reaches the level of a few per cent distortion, and 1/6 octave below it is under −100 dB.
    public static let topEdgeMargin: Double = 1.0 / 6

    /// How far above the sweep's start a harmonic is trusted, as a ratio of frequencies: six (2.6 octaves). Below
    /// it the ripple of the harmonic chirp's abrupt start, which the windows cannot smooth away, reads the
    /// harmonic up to 10 % low.
    public static let trustedStartRatio: Double = 6
    /// The lowest fundamental, in hertz, at which a harmonic is trusted whatever the sweep: 80 Hz, eight times the
    /// resolution of the 100 ms windows. A sweep from 10 Hz reads the second harmonic 4–6 % low at 60–70 Hz.
    public static let minimumTrustedFrequency: Double = 80

    /// The shortest sweep, in seconds, for which the accuracy above holds: 3 s. The start ripple narrows as the
    /// sweep slows down, so a 2 s sweep reads the second harmonic 5 % low at six times its start.
    public static let minimumAccurateDuration: Double = 3

    /// The least time, in seconds, the recording must run past the sweep's end plus the route's delay for the
    /// noise floor to be measured: the linear window (`ImpulseResponse.defaultPostWindow`) plus the longest
    /// harmonic window, about 0.2 s. A recording that stops sooner has no `noiseFloor`.
    public static var minimumTail: Double { ImpulseResponse.defaultPostWindow + preWindow + ImpulseResponse.defaultPostWindow }

    /// The highest fundamental, in hertz, at which harmonic `order` is reported: the sweep's end less
    /// `topEdgeMargin` and less the octaves its fade-out spans, over `order`. Above `endFrequency / order` the
    /// harmonic fell outside the sweep and there is nothing to measure; inside the fade-out the sweep's level drops
    /// and the harmonic would read high.
    public static func upperFrequency(order: Int, sweep: LogSweep) -> Double {
        let fadeOctaves = sweep.fadeDuration / sweep.duration * log2(sweep.endFrequency / sweep.startFrequency)
        return sweep.endFrequency * pow(2, -(topEdgeMargin + fadeOctaves)) / Double(order)
    }

    /// The fundamentals, in hertz, over which harmonic `order` measured with `sweep` is accurate: from
    /// `trustedStartRatio` times the start (and at least `minimumTrustedFrequency`) to
    /// `upperFrequency(order:sweep:)`. Nil when that leaves nothing. For `LogSweep.measurement` the second
    /// harmonic's band is 80 Hz to 9.4 kHz.
    public static func trustedBand(order: Int, sweep: LogSweep) -> ClosedRange<Double>? {
        let lower = max(sweep.startFrequency * trustedStartRatio, minimumTrustedFrequency)
        let upper = upperFrequency(order: order, sweep: sweep)
        return lower < upper ? lower...upper : nil
    }

    /// Analyses an impulse response deconvolved from `sweep` (see `Deconvolution`).
    ///
    /// Harmonic `n` is windowed from `preWindow` before its arrival to just short of the next lower order's window
    /// (at most `ImpulseResponse.defaultPostWindow`), with the same tapers as the linear response. Every curve is
    /// limited to the response's `trustedBand`, so a response that captured nothing gives empty curves.
    public static func analyze(
        impulseResponse response: ImpulseResponse,
        sweep: LogSweep,
        orders: [Int] = defaultOrders
    ) -> SweepDistortion {
        precondition(response.sampleRate == sweep.sampleRate, "the response and the sweep differ in sample rate")
        let orders = Array(Set(orders)).sorted()
        precondition(orders.first.map { $0 >= 2 } ?? false, "orders start at 2, the second harmonic")
        let empty = SweepDistortion(
            fundamental: MagnitudeResponse(frequencies: [], decibels: []),
            harmonics: Dictionary(uniqueKeysWithValues: orders.map { ($0, MagnitudeResponse(frequencies: [], decibels: [])) }),
            thd: MagnitudeResponse(frequencies: [], decibels: []),
            noiseFloor: nil
        )
        guard let trusted = response.trustedBand,
              let linear = response.fitted(
                  pre: response.seconds(ImpulseResponse.defaultPreWindow),
                  post: response.seconds(ImpulseResponse.defaultPostWindow)
              )
        else { return empty }

        // Window shapes, (samples before, samples after); the fundamental is order 1.
        var shapes: [Int: (pre: Int, post: Int)] = [1: linear]
        for order in orders {
            let advance = sweep.harmonicAdvance(order: order)
            let gapBelow = advance - sweep.harmonicAdvance(order: order - 1)
            let gapAbove = sweep.harmonicAdvance(order: order + 1) - advance
            let pre = min(preWindow, gapAbove / 2)
            let lowerPre = order == 2 ? ImpulseResponse.defaultPreWindow : min(preWindow, gapBelow / 2)
            let post = min(ImpulseResponse.defaultPostWindow, gapBelow - lowerPre)
            precondition(post > 0, "the sweep is too short to separate harmonic \(order)")
            guard let shape = response.fitted(pre: response.seconds(pre), post: response.seconds(post)) else { return empty }
            shapes[order] = shape
        }
        let longest = shapes.values.map { $0.pre + $0.post }.max() ?? 1
        let size = max(ImpulseResponse.minimumTransformSize, FFT.nextPowerOfTwo(longest))
        let plan = FFT.Plan(size: size, inverse: false)
        guard let bins = response.bins(size: size, in: trusted) else { return empty }

        func magnitudes(_ order: Int, centre: Int) -> [Float] {
            let shape = shapes[order] ?? linear
            return response.windowedMagnitudes(around: centre, pre: shape.pre, post: shape.post, plan: plan)
        }
        let fundamentalMagnitudes = magnitudes(1, centre: response.peakIndex)
        var harmonicMagnitudes: [Int: [Float]] = [:]
        for order in orders {
            harmonicMagnitudes[order] = magnitudes(order, centre: response.index(atOffset: -sweep.harmonicAdvance(order: order)))
        }
        let noiseMagnitudes = noiseWindows(response: response, sweep: sweep, orders: orders, shapes: shapes) {
            magnitudes($0, centre: $1)
        }

        func frequency(_ bin: Int) -> Float { Float(FFT.frequency(ofBin: bin, size: size, sampleRate: sweep.sampleRate)) }
        // The bins at which harmonic `order` is read: inside its trusted band, with its own bin below Nyquist.
        func harmonicBins(_ order: Int) -> [Int] {
            guard let band = trustedBand(order: order, sweep: sweep) else { return [] }
            return bins.filter { band.contains(Double(frequency($0))) && $0 * order <= size / 2 }
        }
        let fundamental = MagnitudeResponse(
            frequencies: bins.map(frequency),
            decibels: bins.map { Decibels.fromAmplitude(fundamentalMagnitudes[$0]) }
        )
        var harmonics: [Int: MagnitudeResponse] = [:]
        var trustedOrders: [Int: Set<Int>] = [:]
        for order in orders {
            let valid = harmonicBins(order)
            trustedOrders[order] = Set(valid)
            let levels = harmonicMagnitudes[order] ?? []
            harmonics[order] = MagnitudeResponse(
                frequencies: valid.map(frequency),
                decibels: valid.map { Decibels.fromAmplitude(levels[$0 * order]) }
            )
        }

        /// Σ |window(n)[n·k]|² over the orders trusted at bin k, over |fundamental[k]|², in dB.
        func ratio(at bin: Int, of windows: [Int: [Float]]) -> Float {
            let power = orders
                .filter { trustedOrders[$0]?.contains(bin) ?? false }
                .reduce(Float(0)) { sum, order in
                    let magnitude = windows[order]?[bin * order] ?? 0
                    return sum + magnitude * magnitude
                }
            let fundamentalPower = fundamentalMagnitudes[bin] * fundamentalMagnitudes[bin]
            return fundamentalPower > 0 ? Decibels.fromPower(power / fundamentalPower) : Decibels.floor
        }
        let thdBins = harmonicBins(orders[0])
        let thd = MagnitudeResponse(frequencies: thdBins.map(frequency), decibels: thdBins.map { ratio(at: $0, of: harmonicMagnitudes) })
        let noiseFloor = noiseMagnitudes.map { noise in
            Smoothing.fractionalOctave(
                MagnitudeResponse(frequencies: thd.frequencies, decibels: thdBins.map { ratio(at: $0, of: noise) }),
                fraction: 3
            )
        }
        return SweepDistortion(fundamental: fundamental, harmonics: harmonics, thd: thd, noiseFloor: noiseFloor)
    }

    /// For each order, the magnitude spectrum of a window of that order's shape placed on noise: ending at the last
    /// instant whose every frequency maps into the recording (the recording's end less the sweep's length) and
    /// starting after the linear response's window. Nil when the recording's tail is too short for that, or its
    /// length is unknown.
    ///
    /// Why there: the response at time τ and frequency F comes from the recording at τ + (when the sweep played F),
    /// so only τ from 0 to `recordingDuration − duration` holds the recording's noise at every frequency, as the
    /// harmonic windows do.
    private static func noiseWindows(
        response: ImpulseResponse,
        sweep: LogSweep,
        orders: [Int],
        shapes: [Int: (pre: Int, post: Int)],
        magnitudes: (Int, Int) -> [Float]
    ) -> [Int: [Float]]? {
        guard let recordingDuration = response.recordingDuration, let linear = shapes[1] else { return nil }
        let end = response.seconds(recordingDuration - sweep.duration)
        let linearEnd = response.seconds(response.delay) + linear.post
        var windows: [Int: [Float]] = [:]
        for order in orders {
            guard let shape = shapes[order], end - shape.pre - shape.post >= linearEnd else { return nil }
            let centre = response.index(atTime: Double(end - shape.post) / response.sampleRate)
            windows[order] = magnitudes(order, centre)
        }
        return windows
    }
}
