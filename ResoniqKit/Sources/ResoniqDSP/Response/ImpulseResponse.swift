import Accelerate

/// The response of a loudspeaker (and room, and microphone) to a unit impulse, recovered from a sweep recording by
/// `Deconvolution.impulseResponse(recording:sweep:)`.
///
/// **Layout.** `samples` is one period of a circular buffer. Index 0 is time zero: the instant the sweep's first
/// sample was played, counted from the recording's first sample. Index `i` in the first half is `i / sampleRate`
/// seconds after time zero; index `count − k` is `k / sampleRate` seconds *before* it (negative time wraps to the
/// end). The linear response arrives at `peakIndex`. The harmonic responses of a nonlinear system arrive
/// `LogSweep.harmonicAdvance(order:)` seconds before the peak, which may wrap past index 0. Use
/// `index(atTime:)` and `index(atOffset:)` instead of doing the modular arithmetic by hand.
///
/// **Units.** Dimensionless: recording units per sweep unit. A recording identical to the sweep gives a unit impulse
/// (band-limited to `band`). The absolute level of a real recording is uncalibrated, so only shapes and differences
/// mean anything.
public struct ImpulseResponse: Sendable, Equatable {
    /// Seconds kept before the peak when windowing: room for the response's own onset and the band-limit's
    /// short precursor, short enough to keep the second harmonic's response out.
    public static let defaultPreWindow: Double = 0.002
    /// Seconds kept after the peak when windowing. 100 ms resolves down to about 10 Hz (`1 / postWindow`) and so
    /// keeps the bass of a near-field measurement; at 30 cm in a room it also keeps the early reflections, which
    /// add ripple above a few hundred hertz. A reflection-free (gated) response needs a window shorter than the
    /// first reflection's delay, at the cost of everything below `1 / postWindow`.
    public static let defaultPostWindow: Double = 0.1
    /// The fraction of the post window, at its end, over which it fades out (half a Hann window).
    public static let postTaperFraction: Double = 0.5
    /// The smallest transform used to turn a windowed response into a spectrum, so short windows still give a
    /// finely sampled curve (2.9 Hz per point at 48 kHz).
    public static let minimumTransformSize = 16384

    public let samples: [Float]
    /// Hertz.
    public let sampleRate: Double
    /// The arrival of the linear response: the sample of largest magnitude.
    public let peakIndex: Int
    /// The frequencies, in hertz, the response is valid over: the sweep's range. Outside it the deconvolution
    /// suppresses everything, so a frequency response is only reported inside it.
    public let band: ClosedRange<Double>

    /// - Parameters:
    ///   - peakIndex: The linear arrival; the sample of largest magnitude when nil.
    ///   - band: Hertz; from 0 to the Nyquist frequency when nil.
    public init(samples: [Float], sampleRate: Double, peakIndex: Int? = nil, band: ClosedRange<Double>? = nil) {
        precondition(!samples.isEmpty, "an impulse response needs samples")
        precondition(sampleRate > 0, "sample rate must be positive")
        self.samples = samples
        self.sampleRate = sampleRate
        self.peakIndex = peakIndex ?? Int(vDSP.indexOfMaximum(vDSP.absolute(samples)).0)
        self.band = band ?? 0...(sampleRate / 2)
        precondition(samples.indices.contains(self.peakIndex), "peak index outside the buffer")
    }

    public var count: Int { samples.count }

    /// The buffer index of `time` seconds after time zero (negative: before it), wrapped into the buffer.
    public func index(atTime time: Double) -> Int {
        wrap(Int((time * sampleRate).rounded()))
    }

    /// The buffer index `offset` seconds after the linear peak (negative: before it), wrapped into the buffer.
    public func index(atOffset offset: Double) -> Int {
        wrap(peakIndex + Int((offset * sampleRate).rounded()))
    }

    /// Seconds from time zero to the linear peak, refined between samples by a parabola through the peak and its
    /// neighbours. Negative when the peak lies in the wrapped half (the recording started after the sweep).
    ///
    /// This is the arrival of the response's largest sample, not its first sound: a speaker's own group delay
    /// (a fraction of a millisecond in the treble, more in the bass) is included.
    public var delay: Double {
        let sign: Float = samples[peakIndex] < 0 ? -1 : 1
        let before = sign * samples[wrap(peakIndex - 1)]
        let centre = sign * samples[peakIndex]
        let after = sign * samples[wrap(peakIndex + 1)]
        let curvature = before - 2 * centre + after
        let fraction = curvature < 0 ? Double(0.5 * (before - after) / curvature) : 0
        let signed = peakIndex <= count / 2 ? peakIndex : peakIndex - count
        return (Double(signed) + fraction) / sampleRate
    }

    /// The magnitude of the response windowed around the linear peak, in dB re the sweep (0 dB: the sweep came
    /// back unchanged), on the transform's linear frequency grid restricted to `band`.
    ///
    /// The window rises over `preWindow` seconds before the peak (half a Hann window) and stays flat after it,
    /// fading over the last `postTaperFraction` of `postWindow`. Nothing below about `1 / postWindow` hertz is
    /// resolved; whatever arrives within the window (reflections included) is part of the result. Below twice the
    /// sweep's start frequency the deconvolution's low cut (`Deconvolution.lowCutRatio`) is included.
    public func frequencyResponse(
        preWindow: Double = ImpulseResponse.defaultPreWindow,
        postWindow: Double = ImpulseResponse.defaultPostWindow
    ) -> MagnitudeResponse {
        let pre = Int((preWindow * sampleRate).rounded())
        let post = Int((postWindow * sampleRate).rounded())
        let size = max(Self.minimumTransformSize, FFT.nextPowerOfTwo(pre + post))
        let magnitudes = windowedMagnitudes(around: peakIndex, pre: pre, post: post, size: size)
        let bins = binRange(size: size, upTo: band.upperBound)
        return MagnitudeResponse(
            frequencies: bins.map { Float(FFT.frequency(ofBin: $0, size: size, sampleRate: sampleRate)) },
            decibels: bins.map { Decibels.fromAmplitude(magnitudes[$0]) }
        )
    }

    // MARK: - Shared with the distortion analysis

    /// The magnitude spectrum (all `size` bins) of the samples from `pre` before `centre` to `post` after it,
    /// windowed as `frequencyResponse` describes.
    func windowedMagnitudes(around centre: Int, pre: Int, post: Int, size: Int) -> [Float] {
        precondition(pre >= 0 && post > 0 && pre + post <= min(count, size), "window does not fit the response")
        let taper = max(1, Int(Double(post) * Self.postTaperFraction))
        var segment = [Float](repeating: 0, count: pre + post)
        for offset in 0..<(pre + post) {
            var weight = 1.0
            if offset < pre {
                weight = 0.5 * (1 - cos(Double.pi * Double(offset) / Double(pre)))
            } else {
                let intoTaper = offset - pre - (post - taper)
                if intoTaper >= 0 {
                    weight = 0.5 * (1 + cos(Double.pi * Double(intoTaper) / Double(taper)))
                }
            }
            segment[offset] = Float(weight) * samples[wrap(centre - pre + offset)]
        }
        return FFT.forward(segment, size: size).magnitudes
    }

    /// The bins of a `size`-point transform from the bottom of `band` (at least bin 1) up to `upper` hertz.
    func binRange(size: Int, upTo upper: Double) -> ClosedRange<Int> {
        let low = max(1, Int((band.lowerBound * Double(size) / sampleRate).rounded(.up)))
        let high = min(size / 2, Int((min(upper, band.upperBound) * Double(size) / sampleRate).rounded(.down)))
        precondition(high >= low, "no bins in the band")
        return low...high
    }

    private func wrap(_ index: Int) -> Int {
        let remainder = index % count
        return remainder < 0 ? remainder + count : remainder
    }
}
