/// Audio a session kept so the app can name what made the room noisy (`InterferenceAdvisor` in the diagnostics
/// module classifies it; this module does not depend on that one).
public struct CapturedAudio: Sendable, Equatable {
    /// Mono, as captured, oldest first.
    public var samples: [Float]
    public var sampleRate: Double
    /// Whether the sweep was playing in it: a recording judged too noisy. False for the audio kept while a run was
    /// paused, which starts only once the sweep stopped at the speakers can no longer be arriving or dying away
    /// (`PausedAudioKeeper.sweepArrival`).
    public var sweepPlaying: Bool

    public init(samples: [Float], sampleRate: Double, sweepPlaying: Bool) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.sweepPlaying = sweepPlaying
    }

    /// Seconds.
    public var duration: Double { Double(samples.count) / sampleRate }

    /// The most audio kept while a run is paused for noise, seconds: the latest stretch, older audio is dropped.
    /// *First guess*: 4 s, four of the sound classifier's 1.5 s windows at half overlap, enough to name a voice or an
    /// appliance, and no more memory than a fifth of a run's recording.
    public static let pausedDuration: Double = 4

    /// The least audio of a pause offered for naming the noise, seconds: 1.5, one window of the sound classifier
    /// (`SystemSoundClassifier.windowDuration`, which classifies nothing shorter). Less is not offered at all.
    public static let minimumDuration: Double = 1.5

    /// After the sweep's sound has arrived, how long the room takes to let it die away, seconds: 0.5, the room
    /// window the seat reads a response with (`ImpulseResponse.roomPostWindow`), by which a living room's
    /// reverberation has fallen well under the noise that paused the run. *First guess*.
    public static let sweepDecayAllowance: Double = 0.5
}

/// What both sessions keep of a pause for noise: the latest `CapturedAudio.pausedDuration` of it, from the moment the
/// sweep can no longer be heard.
///
/// **Why it skips the start of a pause.** Playback stops at the speakers' end, but what was already sent keeps
/// arriving for the route's delay (up to about two seconds over AirPlay) and then rings in the room. Classified as if
/// nothing played, the app's own sweep is named "music or a TV". So the first `sweepArrival` samples of a pause (the
/// block in which noise was heard, the delay, and `CapturedAudio.sweepDecayAllowance`) are not kept, and nothing is
/// offered until at least `CapturedAudio.minimumDuration` has been.
struct PausedAudioKeeper {
    let sampleRate: Double
    private var ring: AudioRing
    private var skipRemaining = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        ring = AudioRing(capacity: max(1, Int((CapturedAudio.pausedDuration * sampleRate).rounded())))
    }

    /// Samples from the start of a pause's first block until the sweep can no longer be heard: that block, the
    /// route's delay (`delay` in samples; `maximumRouteDelay` when it is not known) and the decay allowance.
    static func sweepArrival(delay: Int?, blockLength: Int, configuration: MeasurementConfiguration, sampleRate: Double) -> Int {
        blockLength
            + (delay ?? configuration.samples(configuration.maximumRouteDelay, at: sampleRate))
            + configuration.samples(CapturedAudio.sweepDecayAllowance, at: sampleRate)
    }

    /// A new pause began with the block about to be kept: what an earlier one held is not this noise, and the first
    /// `skipping` samples may still hold the sweep.
    mutating func pauseBegan(skipping: Int = 0) {
        ring.reset()
        skipRemaining = max(skipping, 0)
    }

    mutating func keep(_ samples: [Float]) {
        guard skipRemaining < samples.count else {
            skipRemaining -= samples.count
            return
        }
        ring.append(skipRemaining == 0 ? samples : Array(samples[skipRemaining...]))
        skipRemaining = 0
    }

    /// Nil until `CapturedAudio.minimumDuration` has been kept.
    var audio: CapturedAudio? {
        guard Double(ring.count) >= CapturedAudio.minimumDuration * sampleRate else { return nil }
        return CapturedAudio(samples: ring.contents, sampleRate: sampleRate, sweepPlaying: false)
    }
}

/// A bounded ring of the latest samples.
struct AudioRing {
    let capacity: Int
    private var storage: [Float]
    private var next = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0, "a ring holds at least one sample")
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    var isEmpty: Bool { count == 0 }

    mutating func reset() {
        next = 0
        count = 0
    }

    mutating func append(_ samples: [Float]) {
        // Only the last `capacity` samples can stay.
        let kept = samples.count > capacity ? samples[(samples.count - capacity)...] : samples[...]
        for sample in kept {
            storage[next] = sample
            next = (next + 1) % capacity
        }
        count = min(count + kept.count, capacity)
    }

    /// Oldest first.
    var contents: [Float] {
        guard count == capacity else { return Array(storage[0..<count]) }
        return Array(storage[next...] + storage[..<next])
    }
}
