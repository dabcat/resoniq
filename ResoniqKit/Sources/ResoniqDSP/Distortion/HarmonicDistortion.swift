import Foundation

/// Harmonic distortion against frequency, from one sweep measurement.
///
/// All curves share the fundamental's frequency axis (hertz, the transform's linear grid within the sweep's range):
/// a point at `f` describes what the speaker did while the sweep was playing `f`.
public struct SweepDistortion: Sendable, Equatable {
    /// The linear response, in dB re the sweep, windowed exactly as `ImpulseResponse.frequencyResponse()` does
    /// with its defaults.
    public let fundamental: MagnitudeResponse
    /// For each order `n`, the level of the `n`-th harmonic produced while the sweep played `f`, in dB on the same
    /// scale as `fundamental` (so `harmonics[n] − fundamental` is the harmonic relative to the fundamental).
    /// Harmonic `n` is reported only up to `HarmonicDistortion.upperFrequency(order:sweep:)`, just under
    /// `endFrequency / n`: above that it fell outside the sweep's range and there is nothing to measure. Where a speaker adds no
    /// harmonic, the curve is the noise floor of the measurement, not zero.
    public let harmonics: [Int: MagnitudeResponse]
    /// Total harmonic distortion in dB relative to the fundamental, `10·log10(Σ hₙ² / h₁²)`, from the lowest
    /// requested order's upper frequency down. At each `f` it sums only the orders that exist there, so above
    /// the third harmonic's upper frequency it is the second harmonic alone. It includes the noise floor's share in each harmonic,
    /// so a clean speaker reads as a floor, never as zero. The floor rises with frequency, about 3 dB an octave of
    /// the harmonics', because a log sweep puts less energy into each hertz as it rises.
    public let thd: MagnitudeResponse

    /// THD at `frequency` hertz as a percentage of the fundamental, interpolated in log frequency; held at the
    /// edge value outside `thd`'s range.
    public func thdPercent(at frequency: Float) -> Float {
        100 * Decibels.toAmplitude(thd.decibels(at: frequency))
    }
}

/// Farina's method: a nonlinear system driven by an exponential sweep leaves, after deconvolution, one impulse
/// response per harmonic order, each arriving `LogSweep.harmonicAdvance(order:)` before the linear one. Windowing
/// each out and transforming it gives that harmonic's level against *its* frequency `n·f`, which maps back to the
/// fundamental `f` that produced it.
///
/// What it cannot tell you: the distortion of a stimulus other than a sine (music adds intermodulation, which a
/// sweep does not show), which component of the chain distorted (speaker, amplifier, microphone), or anything
/// non-harmonic such as rattles (see `ToneDistortion`). Each harmonic window is limited to the gap between
/// neighbouring harmonics, so short sweeps resolve the higher orders coarsely in frequency. Within about an
/// octave of the sweep's start the harmonic chirp's own abrupt start (at `n · startFrequency`) ripples its
/// spectrum: on a 2 s sweep from 20 Hz the second harmonic reads 0.6 dB high at 50 Hz and is exact from 100 Hz.
public enum HarmonicDistortion {
    /// The orders analysed unless told otherwise.
    public static let defaultOrders = [2, 3, 4, 5]
    /// Seconds kept before each harmonic's arrival, capped at half the gap to the next higher order.
    public static let preWindow: Double = 0.005

    /// Octaves below the sweep's end frequency that no harmonic is read from. The deconvolution's sharp edge at
    /// the sweep's end rings into negative time, where the harmonic windows are; in the top 1/14 octave that
    /// ringing reaches the level of a few per cent distortion, and 1/6 octave below it is under −100 dB.
    public static let topEdgeMargin: Double = 1.0 / 6

    /// The highest fundamental, in hertz, at which harmonic `order` is reported: the sweep's end, less
    /// `topEdgeMargin`, over `order`. Above `endFrequency / order` the harmonic fell outside the sweep and there is
    /// nothing to measure.
    public static func upperFrequency(order: Int, sweep: LogSweep) -> Double {
        sweep.endFrequency * pow(2, -topEdgeMargin) / Double(order)
    }

    /// Analyses an impulse response deconvolved from `sweep` (see `Deconvolution`).
    ///
    /// Harmonic `n` is windowed from `preWindow` before its arrival to just short of the next lower order's
    /// window (at most `ImpulseResponse.defaultPostWindow`), with the same tapers as the linear response.
    public static func analyze(
        impulseResponse: ImpulseResponse,
        sweep: LogSweep,
        orders: [Int] = defaultOrders
    ) -> SweepDistortion {
        precondition(impulseResponse.sampleRate == sweep.sampleRate, "the response and the sweep differ in sample rate")
        let orders = Array(Set(orders)).sorted()
        precondition(orders.first.map { $0 >= 2 } ?? false, "orders start at 2, the second harmonic")
        let sampleRate = sweep.sampleRate
        func samples(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

        // Windows: (centre index, samples before, samples after); the fundamental first.
        let linearPre = samples(ImpulseResponse.defaultPreWindow)
        let linearPost = samples(ImpulseResponse.defaultPostWindow)
        var windows: [Int: (centre: Int, pre: Int, post: Int)] = [1: (impulseResponse.peakIndex, linearPre, linearPost)]
        for order in orders {
            let advance = sweep.harmonicAdvance(order: order)
            let gapBelow = advance - sweep.harmonicAdvance(order: order - 1)
            let gapAbove = sweep.harmonicAdvance(order: order + 1) - advance
            let pre = min(preWindow, gapAbove / 2)
            let lowerPre = order == 2 ? ImpulseResponse.defaultPreWindow : min(preWindow, gapBelow / 2)
            let post = min(ImpulseResponse.defaultPostWindow, gapBelow - lowerPre)
            precondition(post > 0, "the sweep is too short to separate harmonic \(order)")
            windows[order] = (impulseResponse.index(atOffset: -advance), samples(pre), samples(post))
        }
        let longest = windows.values.map { $0.pre + $0.post }.max() ?? 1
        let size = max(ImpulseResponse.minimumTransformSize, FFT.nextPowerOfTwo(longest))
        let magnitudes = windows.mapValues {
            impulseResponse.windowedMagnitudes(around: $0.centre, pre: $0.pre, post: $0.post, size: size)
        }

        let bins = impulseResponse.binRange(size: size, upTo: sweep.endFrequency)
        // The highest bin a harmonic may be read from (harmonic n at fundamental bin k is bin n·k).
        let topBin = Int((upperFrequency(order: 1, sweep: sweep) * Double(size) / sampleRate).rounded(.down))
        func frequency(_ bin: Int) -> Float { Float(FFT.frequency(ofBin: bin, size: size, sampleRate: sampleRate)) }
        let fundamentalMagnitudes = magnitudes[1] ?? []
        let fundamental = MagnitudeResponse(
            frequencies: bins.map(frequency),
            decibels: bins.map { Decibels.fromAmplitude(fundamentalMagnitudes[$0]) }
        )

        var harmonics: [Int: MagnitudeResponse] = [:]
        for order in orders {
            let valid = bins.filter { $0 * order <= topBin }
            let harmonicMagnitudes = magnitudes[order] ?? []
            harmonics[order] = MagnitudeResponse(
                frequencies: valid.map(frequency),
                decibels: valid.map { Decibels.fromAmplitude(harmonicMagnitudes[$0 * order]) }
            )
        }

        let lowestOrder = orders[0]
        let thdBins = bins.filter { $0 * lowestOrder <= topBin }
        let thd = MagnitudeResponse(
            frequencies: thdBins.map(frequency),
            decibels: thdBins.map { bin in
                let harmonicPower = orders
                    .filter { bin * $0 <= topBin }
                    .reduce(Float(0)) { sum, order in
                        let magnitude = magnitudes[order]?[bin * order] ?? 0
                        return sum + magnitude * magnitude
                    }
                let fundamentalPower = fundamentalMagnitudes[bin] * fundamentalMagnitudes[bin]
                return fundamentalPower > 0 ? Decibels.fromPower(harmonicPower / fundamentalPower) : Decibels.floor
            }
        )
        return SweepDistortion(fundamental: fundamental, harmonics: harmonics, thd: thd)
    }
}
