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
    /// Seconds kept after the peak to read the response at a listening seat, where the room is the subject: 0.5.
    /// Its flat 450 ms (the fade is `maximumPostTaper`) holds a room's reflections and most of a bass mode's ring: a
    /// +12 dB mode at 45 Hz of Q 10, which takes 1 s to fall 60 dB, reads within 0.1 dB of its true level at each
    /// point, where the default window reads it nearly 3 dB low. It resolves about 2 Hz (`1 / postWindow`), on a
    /// 1.5 Hz grid at 48 kHz, which can itself miss a mode's summit by half a decibel. The cost is
    /// noise: the window is six times the default's in energy, so about 8 dB more of the recording's noise in every
    /// point. Smooth the result before reading it, and record at least this long after the sweep, or the late part
    /// of the window holds no treble.
    public static let roomPostWindow: Double = 0.5
    /// The fraction of the post window, at its end, over which it fades out (half a Hann window), up to
    /// `maximumPostTaper`.
    public static let postTaperFraction: Double = 0.5
    /// The longest fade at the end of a post window, in seconds: 50 ms, the default window's own (half of 100 ms),
    /// one period of 20 Hz. Enough to end without a step; a longer window keeps the rest of its length flat, so what
    /// it was made longer to hold is not faded away. No window up to the default is changed by it.
    public static let maximumPostTaper: Double = 0.05
    /// The smallest transform used to turn a windowed response into a spectrum, so short windows still give a
    /// finely sampled curve (2.9 Hz per point at 48 kHz).
    public static let minimumTransformSize = 16384

    public let samples: [Float]
    /// Hertz.
    public let sampleRate: Double
    /// The arrival of the linear response: the sample of largest magnitude.
    public let peakIndex: Int
    /// The frequencies, in hertz, the sweep played: its range. Outside it the deconvolution suppresses everything.
    public let band: ClosedRange<Double>
    /// The part of `band` whose stretch of the sweep the recording actually holds, in hertz; nil when it holds none
    /// of it (an empty, all-zero or corrupt recording, or one that ends before the sweep reached the speaker).
    /// Narrower than `band` when the recording started after the sweep (the bass is missing) or stopped before the
    /// sweep's end plus the route's delay (the treble is missing). Nothing can be concluded about a frequency
    /// outside it: it was never recorded.
    public let capturedBand: ClosedRange<Double>?
    /// The frequencies, in hertz, `frequencyResponse` reports: where the response is accurate. The sweep's
    /// `LogSweep.trustedBand`, narrowed further where the recording was cut (`Deconvolution` documents how far);
    /// nil when nothing is. Equal to `band` for a response built by hand.
    public let trustedBand: ClosedRange<Double>?
    /// Seconds of recording the response was deconvolved from, counted from time zero; nil when built by hand. The
    /// harmonic analysis uses it to find a stretch of the response that holds only noise.
    public let recordingDuration: Double?

    /// A response built by hand: everything in `band` counts as captured and trusted.
    ///
    /// - Parameters:
    ///   - peakIndex: The linear arrival; the sample of largest magnitude when nil.
    ///   - band: Hertz; from 0 to the Nyquist frequency when nil.
    public init(samples: [Float], sampleRate: Double, peakIndex: Int? = nil, band: ClosedRange<Double>? = nil) {
        let band = band ?? 0...(sampleRate / 2)
        self.init(
            samples: samples, sampleRate: sampleRate, peakIndex: peakIndex,
            band: band, capturedBand: band, trustedBand: band, recordingDuration: nil
        )
    }

    /// Every field given, as `Deconvolution` builds it or a test fixture needs it.
    public init(
        samples: [Float],
        sampleRate: Double,
        peakIndex: Int?,
        band: ClosedRange<Double>,
        capturedBand: ClosedRange<Double>?,
        trustedBand: ClosedRange<Double>?,
        recordingDuration: Double?
    ) {
        precondition(!samples.isEmpty, "an impulse response needs samples")
        precondition(sampleRate > 0, "sample rate must be positive")
        self.samples = samples
        self.sampleRate = sampleRate
        self.peakIndex = peakIndex ?? Int(vDSP.indexOfMaximum(vDSP.absolute(samples)).0)
        self.band = band
        self.capturedBand = capturedBand
        self.trustedBand = trustedBand
        self.recordingDuration = recordingDuration
        precondition(samples.indices.contains(self.peakIndex), "peak index outside the buffer")
    }

    public var count: Int { samples.count }

    /// Whether the recording held the whole sweep, from its first sample to its last.
    public var capturesWholeSweep: Bool { capturedBand == band }

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
    /// back unchanged), on the transform's linear frequency grid restricted to `trustedBand`. Empty when nothing
    /// is trusted: an empty or corrupt recording, or one that missed the sweep.
    ///
    /// The window rises over `preWindow` seconds before the peak (half a Hann window) and stays flat after it,
    /// fading over the last `postTaperFraction` of `postWindow` (at most `maximumPostTaper`); on a response shorter
    /// than that it is cut to fit. Nothing below about `1 / postWindow` hertz is resolved, and the accuracy
    /// `LogSweep.trustedBand` states is for the default window (it holds for `roomPostWindow` too); whatever arrives
    /// within the window (reflections included) is part of the result. Use the default for the speaker,
    /// `roomPostWindow` for the seat, and a window shorter than the first reflection for a reflection-free reading.
    public func frequencyResponse(
        preWindow: Double = ImpulseResponse.defaultPreWindow,
        postWindow: Double = ImpulseResponse.defaultPostWindow
    ) -> MagnitudeResponse {
        let window = fitted(pre: seconds(preWindow), post: seconds(postWindow))
        guard let trustedBand, let window else { return MagnitudeResponse(frequencies: [], decibels: []) }
        let size = max(Self.minimumTransformSize, FFT.nextPowerOfTwo(window.pre + window.post))
        guard let bins = bins(size: size, in: trustedBand) else { return MagnitudeResponse(frequencies: [], decibels: []) }
        let magnitudes = windowedMagnitudes(around: peakIndex, pre: window.pre, post: window.post, plan: FFT.Plan(size: size, inverse: false))
        return MagnitudeResponse(
            frequencies: bins.map { Float(FFT.frequency(ofBin: $0, size: size, sampleRate: sampleRate)) },
            decibels: bins.map { Decibels.fromAmplitude(magnitudes[$0]) }
        )
    }

    // MARK: - Shared with the distortion analysis

    /// `seconds` as a whole number of samples.
    func seconds(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

    /// A window of `pre` samples before its centre and `post` after it, cut to fit the buffer: `pre` first kept
    /// below half the buffer, then `post` to the rest. Nil when no sample after the centre is left.
    func fitted(pre: Int, post: Int) -> (pre: Int, post: Int)? {
        let pre = min(max(pre, 0), count / 2)
        let post = min(post, count - pre)
        return post > 0 ? (pre, post) : nil
    }

    /// The magnitude spectrum (all `plan.size` bins) of the samples from `pre` before `centre` to `post` after it,
    /// windowed as `frequencyResponse` describes.
    func windowedMagnitudes(around centre: Int, pre: Int, post: Int, plan: FFT.Plan) -> [Float] {
        precondition(pre >= 0 && post > 0 && pre + post <= min(count, plan.size), "window does not fit the response")
        let taper = max(1, min(Int(Double(post) * Self.postTaperFraction), seconds(Self.maximumPostTaper)))
        var segment = [Float](repeating: 0, count: pre + post)
        for offset in 0..<(pre + post) {
            let weight = offset < pre
                ? RaisedCosine.rise(Double(offset), over: Double(pre))
                : RaisedCosine.rise(Double(pre + post - offset), over: Double(taper))
            segment[offset] = Float(weight) * samples[wrap(centre - pre + offset)]
        }
        return plan.forward(segment).magnitudes
    }

    /// The bins of a `size`-point transform whose frequencies lie in `range` (never bin 0, never past Nyquist);
    /// nil when there are none.
    func bins(size: Int, in range: ClosedRange<Double>) -> ClosedRange<Int>? {
        let low = max(1, Int((range.lowerBound * Double(size) / sampleRate).rounded(.up)))
        let high = min(size / 2, Int((range.upperBound * Double(size) / sampleRate).rounded(.down)))
        return high >= low ? low...high : nil
    }

    private func wrap(_ index: Int) -> Int {
        let remainder = index % count
        return remainder < 0 ? remainder + count : remainder
    }
}
