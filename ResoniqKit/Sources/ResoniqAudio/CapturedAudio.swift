/// Audio a session kept so the app can name what made the room noisy (`InterferenceAdvisor` in the diagnostics
/// module classifies it; this module does not depend on that one).
public struct CapturedAudio: Sendable, Equatable {
    /// Mono, as captured, oldest first.
    public var samples: [Float]
    public var sampleRate: Double
    /// Whether the sweep was playing in it: a recording judged too noisy. False for the audio kept while a run was
    /// paused, when nothing played.
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
}

/// What both sessions keep of a pause for noise: the latest `CapturedAudio.pausedDuration` of it.
struct PausedAudioKeeper {
    let sampleRate: Double
    private var ring: AudioRing

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        ring = AudioRing(capacity: max(1, Int((CapturedAudio.pausedDuration * sampleRate).rounded())))
    }

    /// A new pause began: what an earlier one held is not this noise.
    mutating func pauseBegan() { ring.reset() }

    mutating func keep(_ samples: [Float]) { ring.append(samples) }

    /// Nil when nothing has been kept.
    var audio: CapturedAudio? {
        ring.isEmpty ? nil : CapturedAudio(samples: ring.contents, sampleRate: sampleRate, sweepPlaying: false)
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
