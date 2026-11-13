import Accelerate

/// Magnitude spectra of sample buffers.
///
/// Both spectra share the module's one level convention: **dBFS RMS**, the same scale as `Level.rmsDecibels`. A
/// sine of amplitude `A` centred on a bin reads its RMS, `20·log10(A/√2)`, there whatever the window (the window's
/// coherent gain is divided out), so a full-scale sine reads −3.01 dB. A constant (DC) of value `c` reads
/// `20·log10(c)` in bin 0. The bins run from DC to Nyquist inclusive: `size / 2 + 1` of them, bin `k` at
/// `k · sampleRate / size` Hz.
///
/// For noise, the level per bin depends on the bin width and the window: white noise of variance σ² reads
/// `10·log10(2σ² · ENBW / N)` in every bin, where ENBW is `Window.equivalentNoiseBandwidth` and N the frame
/// length. To add bins up into bands, use `OctaveBands.levels`, which divides the window and any zero padding out.
public enum SpectrumAnalyzer {
    /// The spectrum of the whole of `signal`, windowed by `window` (over the signal's own length) and
    /// zero-padded to `size` points (default: the next power of two). `size` must be a power of two of at
    /// least 16 that fits the signal. An empty signal is silence: every bin reads `Decibels.floor`.
    public static func spectrum(
        of signal: [Float],
        sampleRate: Double,
        window: Window = .hann,
        size: Int? = nil
    ) -> MagnitudeResponse {
        let size = size ?? FFT.nextPowerOfTwo(max(signal.count, 16))
        guard !signal.isEmpty else { return silence(size: size, sampleRate: sampleRate) }
        let engine = PowerSpectrumEngine(size: size, frameLength: signal.count, window: window)
        return engine.response(power: engine.power(of: signal[...]), sampleRate: sampleRate)
    }

    /// Welch's averaged spectrum: `signal` cut into `segmentSize`-sample segments that overlap by `overlap`
    /// (a fraction, 0 up to but not including 1), each windowed, transformed and turned into power; the powers
    /// are averaged bin by bin. Same normalisation as `spectrum`, with `segmentSize / 2 + 1` bins.
    ///
    /// A signal shorter than one segment is analysed as a single zero-padded segment. A trailing part shorter
    /// than a segment is left out. The window and the transform are set up once per call, so a 4096-sample
    /// segment costs one FFT and a few vector operations. An empty signal is silence, as for `spectrum`.
    public static func averagedSpectrum(
        of signal: [Float],
        sampleRate: Double,
        segmentSize: Int = 4096,
        overlap: Double = 0.5,
        window: Window = .hann
    ) -> MagnitudeResponse {
        precondition(overlap >= 0 && overlap < 1, "overlap must be at least 0 and below 1")
        guard signal.count > segmentSize else {
            return spectrum(of: signal, sampleRate: sampleRate, window: window, size: segmentSize)
        }
        let engine = PowerSpectrumEngine(size: segmentSize, frameLength: segmentSize, window: window)
        let hop = max(1, Int((Double(segmentSize) * (1 - overlap)).rounded()))
        var total = [Float](repeating: 0, count: segmentSize / 2 + 1)
        var segments = 0
        var start = 0
        while start + segmentSize <= signal.count {
            vDSP.add(total, engine.power(of: signal[start..<(start + segmentSize)]), result: &total)
            segments += 1
            start += hop
        }
        return engine.response(power: vDSP.divide(total, Float(segments)), sampleRate: sampleRate)
    }

    /// The spectrum of nothing: `size / 2 + 1` bins at `Decibels.floor`.
    private static func silence(size: Int, sampleRate: Double) -> MagnitudeResponse {
        precondition(size >= 16 && size == FFT.nextPowerOfTwo(size), "size must be a power of two of at least 16")
        return MagnitudeResponse(
            frequencies: (0...(size / 2)).map { Float(FFT.frequency(ofBin: $0, size: size, sampleRate: sampleRate)) },
            decibels: [Float](repeating: Decibels.floor, count: size / 2 + 1)
        )
    }
}

/// One window and one transform, reused for every frame of an analysis.
private struct PowerSpectrumEngine {
    let size: Int
    let window: [Float]
    let plan: FFT.Plan
    /// Turns |X[k]|² into mean square: 2 / (Σw)² for the bins between DC and Nyquist (a sine's power is split
    /// between a bin and its mirror image, and its mean square is half its peak squared), 1 / (Σw)² for those two.
    let scale: [Float]

    init(size: Int, frameLength: Int, window: Window) {
        precondition(size >= 16 && size == FFT.nextPowerOfTwo(size), "size must be a power of two of at least 16")
        precondition(frameLength > 0 && frameLength <= size, "the frame must fit the transform")
        self.size = size
        self.window = window.samples(count: frameLength)
        self.plan = FFT.Plan(size: size, inverse: false)
        // The window's own sum rather than `count · coherentGain`: equal for any frame of two samples or more,
        // and right for a one-sample frame too.
        let windowSum = vDSP.sum(self.window)
        let edge = 1 / (windowSum * windowSum)
        var scale = [Float](repeating: 2 * edge, count: size / 2 + 1)
        scale[0] = edge
        scale[size / 2] = edge
        self.scale = scale
    }

    /// The mean-square power in bins 0 through `size / 2` of one frame, which must be `window.count` long.
    func power(of frame: ArraySlice<Float>) -> [Float] {
        let output = plan.forward(vDSP.multiply(frame, window))
        let bins = 0...(size / 2)
        let squared = vDSP.add(vDSP.square(output.real[bins]), vDSP.square(output.imaginary[bins]))
        return vDSP.multiply(squared, scale)
    }

    func response(power: [Float], sampleRate: Double) -> MagnitudeResponse {
        MagnitudeResponse(
            frequencies: (0...(size / 2)).map { Float(FFT.frequency(ofBin: $0, size: size, sampleRate: sampleRate)) },
            decibels: power.map(Decibels.fromPower)
        )
    }
}
