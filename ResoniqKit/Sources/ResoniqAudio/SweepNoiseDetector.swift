import Accelerate
import ResoniqDSP

/// Tells room noise from the sweep in a block recorded while the sweep plays.
///
/// `NoiseGate` compares a block's broadband level with the room's floor, which only works when nothing plays: a block
/// with the sweep in it is 40 to 60 dB above the floor however quiet the room. The sweep's level at the microphone
/// cannot be predicted either, because it is what is being measured (a speaker's dip or peak moves it by 10 dB within
/// a fraction of an octave), and the route delay that says which frequency is arriving is unknown at first.
///
/// What is known is that at any moment the sweep is one tone. So the block's spectrum is searched for its strongest
/// tone against the floor's spectrum, and that tone is taken out: a band around it as wide as the sweep travels in
/// one block, wider below it for the room's reverberation of the frequencies just played, and the same band around
/// its harmonics, which a distorting speaker adds. What remains is the room. Its level is compared with the floor's
/// level over exactly the same bins, and the rise is held against `QualityThresholds`' pause margin and ceiling, the
/// numbers `NoiseGate` uses. No delay estimate is needed.
///
/// What it cannot tell: a noise that is itself one steady tone near the sweep (it is taken out with the sweep), noise
/// below `analysisLowFrequency` (rumble is ignored, as the iPhone microphone barely hears it), and a speaker that
/// buzzes or rattles off its harmonics: that buzz is not a harmonic and counts as noise, so a badly rattling speaker
/// can pause a test.
public struct SweepNoiseDetector: Sendable {
    /// The lowest frequency whose noise is watched, hertz. *First guess*: 100 Hz.
    public static let analysisLowFrequency = 100.0
    /// The highest frequency whose noise is watched, hertz (or 0.95 × Nyquist). *First guess*: 12 kHz; above it a
    /// phone microphone's floor is mostly its own hiss.
    public static let analysisHighFrequency = 12000.0
    /// Harmonics of the sweep taken out with it, the fundamental included. *First guess*: 5.
    public static let excludedHarmonics = 5
    /// Seconds of sweep below the strongest tone taken out for the room's reverberation. *First guess*: 0.3 s.
    public static let reverberationAllowance = 0.3
    /// Bins added on each side of every excluded band: the Blackman–Harris main lobe is 4 bins each side.
    public static let mainLobeBins = 6
    /// The strongest tone must stand this far above the floor in its band to count as the sweep. *First guess*: 10 dB.
    public static let presenceMarginDecibels: Float = 10

    /// What one block held.
    public struct Assessment: Sendable, Equatable {
        /// The whole block's RMS.
        public var blockLevel: SoundLevel
        /// The room without the sweep: the floor's broadband level raised by as much as the remaining bins rose above
        /// the floor's same bins. Equal to `blockLevel` when no sweep was found.
        public var roomLevel: SoundLevel
        /// How far the remaining bins rose above the floor's, dB.
        public var riseDecibels: Float
        /// The strongest tone's frequency when it stood out as the sweep, hertz.
        public var sweepFrequency: Double?
        /// The strongest tone's band over the floor's same band, dB.
        public var sweepPresenceDecibels: Float
        /// Whether the room is too loud to carry on: `riseDecibels` above the pause margin or `roomLevel` above the
        /// pause ceiling.
        public var isTooNoisy: Bool
    }

    public let blockLength: Int
    public let sampleRate: Double
    let transformSize: Int
    let window: [Float]
    let floorPower: [Float]
    let floorDecibels: Float
    let analysisBins: ClosedRange<Int>
    let searchBins: ClosedRange<Int>
    /// Octaves excluded above and below the strongest tone.
    let octavesAbove: Double
    let octavesBelow: Double
    let thresholds: QualityThresholds

    /// - Parameters:
    ///   - noiseFloor: The room recorded with nothing playing, at least one block long.
    ///   - sweep: The sweep that will play; its range bounds the search and its rate sets the excluded band.
    ///   - blockLength: The samples in every block `assess` is given.
    public init(noiseFloor: [Float], sweep: LogSweep, blockLength: Int, thresholds: QualityThresholds = .standard) {
        precondition(blockLength > 1 && noiseFloor.count >= blockLength, "the floor must hold at least one block")
        self.blockLength = blockLength
        self.sampleRate = sweep.sampleRate
        self.thresholds = thresholds
        transformSize = FFT.nextPowerOfTwo(blockLength)
        window = Window.blackmanHarris.samples(count: blockLength)

        let binWidth = sweep.sampleRate / Double(transformSize)
        let top = transformSize / 2 - 1
        let high = min(Self.analysisHighFrequency, 0.95 * sweep.sampleRate / 2)
        analysisBins = max(1, Int((Self.analysisLowFrequency / binWidth).rounded(.up)))...min(top, Int(high / binWidth))
        searchBins = max(1, Int(sweep.startFrequency * 0.8 / binWidth))...min(top, Int((sweep.endFrequency * 1.05 / binWidth).rounded(.up)))

        let octavesPerSecond = log2(sweep.endFrequency / sweep.startFrequency) / sweep.duration
        let blockSeconds = Double(blockLength) / sweep.sampleRate
        octavesAbove = octavesPerSecond * blockSeconds
        octavesBelow = octavesPerSecond * (blockSeconds + Self.reverberationAllowance)

        // Welch average of the floor with the same window and hop of half a block.
        var sum = [Float](repeating: 0, count: transformSize / 2)
        var frames = 0
        let hop = max(blockLength / 2, 1)
        var start = 0
        let spectrum = Self.power(window: window, size: transformSize)
        while start + blockLength <= noiseFloor.count {
            sum = vDSP.add(sum, spectrum(Array(noiseFloor[start..<(start + blockLength)])))
            frames += 1
            start += hop
        }
        // A floor of exact zeros (a muted simulator) would make every ratio infinite.
        floorPower = sum.map { max($0 / Float(frames), Float.leastNormalMagnitude) }
        floorDecibels = LevelMeter.measure(noiseFloor).rmsDecibels
    }

    /// Splits `block` into sweep and room and decides whether the room is too loud. `block` should be `blockLength`
    /// samples; a shorter one is padded with zeros and a longer one cut.
    public func assess(_ block: [Float]) -> Assessment {
        var samples = Array(block.prefix(blockLength))
        if samples.count < blockLength { samples += [Float](repeating: 0, count: blockLength - samples.count) }
        let power = Self.power(window: window, size: transformSize)(samples)
        let blockLevel = SoundLevel(of: samples)
        let binWidth = sampleRate / Double(transformSize)

        // The strongest tone against the floor.
        var peak = searchBins.lowerBound
        var best: Float = -1
        for bin in searchBins {
            let ratio = power[bin] / floorPower[bin]
            if ratio > best { best = ratio; peak = bin }
        }
        let lobe = max(searchBins.lowerBound, peak - 4)...min(searchBins.upperBound, peak + 4)
        let presence = Decibels.fromPower(vDSP.sum(power[lobe])) - Decibels.fromPower(vDSP.sum(floorPower[lobe]))

        var excluded = [Bool](repeating: false, count: power.count)
        var frequency: Double?
        if presence >= Self.presenceMarginDecibels {
            let found = Self.interpolatedBin(power, at: peak) * binWidth
            frequency = found
            for harmonic in 1...Self.excludedHarmonics {
                let centre = found * Double(harmonic)
                let low = Int(centre * pow(2, -octavesBelow) / binWidth) - Self.mainLobeBins
                let high = Int((centre * pow(2, octavesAbove) / binWidth).rounded(.up)) + Self.mainLobeBins
                guard low < power.count else { break }
                for bin in max(0, low)...min(power.count - 1, high) { excluded[bin] = true }
            }
        }

        var room: Float = 0
        var floor: Float = 0
        for bin in analysisBins where !excluded[bin] {
            room += power[bin]
            floor += floorPower[bin]
        }
        let rise = room > 0 && floor > 0 ? Decibels.fromPower(room) - Decibels.fromPower(floor) : 0
        let roomLevel = frequency == nil ? blockLevel : SoundLevel(dBFS: floorDecibels + rise)
        return Assessment(
            blockLevel: blockLevel,
            roomLevel: roomLevel,
            riseDecibels: rise,
            sweepFrequency: frequency,
            sweepPresenceDecibels: presence,
            isTooNoisy: rise > thresholds.pauseMarginDecibels || roomLevel.dBFS > thresholds.pauseCeilingDecibels
        )
    }

    /// |X|² of the windowed frame for bins 0..<size/2.
    static func power(window: [Float], size: Int) -> @Sendable ([Float]) -> [Float] {
        { frame in
            let spectrum = FFT.forward(vDSP.multiply(frame, window), size: size)
            let half = size / 2
            return vDSP.add(vDSP.square(spectrum.real[0..<half]), vDSP.square(spectrum.imaginary[0..<half]))
        }
    }

    /// The peak's position between bins, from a parabola through the log power of it and its neighbours. The peak is
    /// chosen by its rise over the floor, so it need not be a local maximum of the power: it is first moved to the
    /// local maximum within the main lobe (4 bins), and the vertex is kept within half a bin of that, since a
    /// parabola through bins that do not straddle a maximum puts its vertex anywhere.
    static func interpolatedBin(_ power: [Float], at start: Int) -> Double {
        var peak = start
        while peak > 0, peak < power.count - 1, abs(peak - start) < 4 {
            if power[peak + 1] > power[peak], power[peak + 1] >= power[peak - 1] {
                peak += 1
            } else if power[peak - 1] > power[peak] {
                peak -= 1
            } else {
                break
            }
        }
        guard peak > 0, peak < power.count - 1 else { return Double(peak) }
        let before = Double(Decibels.fromPower(power[peak - 1]))
        let centre = Double(Decibels.fromPower(power[peak]))
        let after = Double(Decibels.fromPower(power[peak + 1]))
        let curvature = before - 2 * centre + after
        guard curvature < 0, centre >= before, centre >= after else { return Double(peak) }
        return Double(peak) + min(max(0.5 * (before - after) / curvature, -0.5), 0.5)
    }
}
