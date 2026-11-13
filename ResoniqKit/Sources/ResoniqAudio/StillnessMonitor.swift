#if os(iOS)
import CoreMotion
#endif
import Foundation

/// Whether the phone is held still. A phone that moves during a run changes the path from the speaker to the
/// microphone halfway through the sweep; the session records that on the run and does not fail it.
///
/// Main-actor isolated: the session reads it once per block on the main actor, and Core Motion delivers to the main
/// queue.
@MainActor
public protocol StillnessMonitor: AnyObject {
    func start()
    func stop()
    var isSteady: Bool { get }
}

/// A monitor whose answer is set by hand: for tests, previews, the simulator and the Mac.
@MainActor
public final class ConstantStillnessMonitor: StillnessMonitor {
    public var isSteady: Bool
    public private(set) var isStarted = false

    public init(isSteady: Bool = true) {
        self.isSteady = isSteady
    }

    public func start() { isStarted = true }
    public func stop() { isStarted = false }
}

#if os(iOS)
/// Stillness from Core Motion's device motion: steady when the rotation rate and the user acceleration have both
/// stayed under their limits for `steadyWindow`.
@MainActor
public final class MotionStillnessMonitor: StillnessMonitor {
    /// Rotation faster than this, in radians a second, is movement. *First guess for a hand-held phone*, not yet
    /// checked on a device: 0.2 rad/s (about 11°/s); a hand holding a phone still trembles at a few hundredths.
    public static let maximumRotationRate = 0.2
    /// User acceleration above this, in g, is movement. *First guess for a hand-held phone*, not yet checked on a
    /// device: 0.05 g.
    public static let maximumUserAcceleration = 0.05
    /// How long both must stay under their limits, in seconds, before the phone counts as steady again.
    /// *First guess for a hand-held phone*: 0.5 s.
    public static let steadyWindow = 0.5
    /// Updates a second. *First guess*: 50, enough to catch a jolt between two 100 ms blocks.
    public static let updateRate = 50.0

    private let manager = CMMotionManager()
    private var lastMovement: TimeInterval?
    private var startedAt: TimeInterval = 0

    public init() {}

    /// False until `steadyWindow` has passed since `start()` or since the last movement; true when device motion is
    /// unavailable, so a phone without it is never reported as moving.
    public private(set) var isSteady = true

    public func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1 / Self.updateRate
        startedAt = ProcessInfo.processInfo.systemUptime
        lastMovement = nil
        isSteady = false
        // Delivered on the main queue, so the handler runs on the main actor.
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let rotation = motion.rotationRate
            let acceleration = motion.userAcceleration
            let rate = (rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z).squareRoot()
            let force = (acceleration.x * acceleration.x + acceleration.y * acceleration.y
                + acceleration.z * acceleration.z).squareRoot()
            let time = motion.timestamp
            MainActor.assumeIsolated {
                self?.update(rotationRate: rate, acceleration: force, time: time)
            }
        }
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
        isSteady = true
    }

    private func update(rotationRate: Double, acceleration: Double, time: TimeInterval) {
        if rotationRate > Self.maximumRotationRate || acceleration > Self.maximumUserAcceleration {
            lastMovement = time
        }
        let since = lastMovement ?? min(startedAt, time)
        isSteady = time - since >= Self.steadyWindow
    }
}
#endif
