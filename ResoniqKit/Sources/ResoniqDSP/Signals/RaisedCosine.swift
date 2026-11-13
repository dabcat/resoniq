import Accelerate

/// The one raised-cosine fade in the module: the ends of `LogSweep` and `TestSignal.sine`, and the tapers of the
/// impulse-response windows.
enum RaisedCosine {
    /// Half a cosine rising from 0 at `position` 0 to 1 at `length`: `0.5·(1 − cos(π·position/length))`, held at
    /// 0 below and at 1 beyond. A `length` of 0 or less is a step at 0.
    static func rise(_ position: Double, over length: Double) -> Double {
        guard length > 0 else { return position > 0 ? 1 : 0 }
        let fraction = min(max(position / length, 0), 1)
        return 0.5 * (1 - cos(Double.pi * fraction))
    }

    /// The gain at `index` of a `count`-sample signal that fades in over its first `fadeSamples` samples and out
    /// over its last. The first and last samples are always 0, even when `fadeSamples` is 0, so a signal cut
    /// from these gains starts and stops without a step.
    static func edgeGain(index: Int, count: Int, fadeSamples: Int) -> Double {
        let distance = min(index, count - 1 - index)
        return rise(Double(distance), over: Double(max(fadeSamples, 1)))
    }

    /// `wave` times `peak`, faded in and out over `fadeSamples` at each end by `edgeGain`, as Float samples. Only
    /// the faded ends are touched one by one.
    static func faded(_ wave: [Double], peak: Double, fadeSamples: Int) -> [Float] {
        var samples = vDSP.multiply(peak, wave)
        let count = samples.count
        let fade = min(max(fadeSamples, 1), count)
        for index in Array(0..<fade) + Array(max(count - fade, fade)..<count) {
            samples[index] *= edgeGain(index: index, count: count, fadeSamples: fadeSamples)
        }
        return vDSP.doubleToFloat(samples)
    }

    /// `fadeDuration` seconds made safe for a signal of `duration` seconds: a missing (NaN) fade is the default, and
    /// the result is at least `LogSweep.minimumFadeDuration` and at most half the signal.
    static func safeFade(_ fadeDuration: Double, duration: Double) -> Double {
        let fade = fadeDuration.isNaN ? LogSweep.defaultFadeDuration : fadeDuration
        return min(max(fade, LogSweep.minimumFadeDuration), duration / 2)
    }

    /// The number of samples a fade of `duration` seconds spans at `sampleRate`.
    static func sampleCount(of duration: Double, sampleRate: Double) -> Int {
        Int((duration * sampleRate).rounded())
    }
}
