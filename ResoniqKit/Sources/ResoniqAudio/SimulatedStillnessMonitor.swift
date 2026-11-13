import Foundation

/// A stillness monitor that acts out the seat measurement's moves: each time the measurement starts waiting for a
/// spot after the first, the simulated phone moves (unsteady for a while), calls `onMove` so the simulated audio can
/// put the microphone at the new spot, and then holds still. For tests, previews and running the whole seat flow in
/// the iOS simulator unattended.
///
/// Wire it to the audio with `onMove`: `monitor.onMove = { io.moveToSpot($0.index) }`. The session knows nothing
/// of either simulation.
///
/// With `.immediate` pacing a move lasts `movingReads` reads of `isSteady` (the session reads it once a block); with
/// `.realTime` it lasts `moveDuration` seconds of wall-clock time.
@MainActor
public final class SimulatedStillnessMonitor: SpotAwareStillnessMonitor {
    public enum Pacing: Sendable, Hashable {
        case realTime
        case immediate
    }

    public let pacing: Pacing
    /// Reads of `isSteady` a move lasts with `.immediate` pacing.
    public var movingReads: Int
    /// Seconds a move lasts with `.realTime` pacing.
    public var moveDuration: Double
    /// False to act out a phone whose movement the sensors miss: `isSteady` stays true through every move (the
    /// microphone still moves, through `onMove`).
    public var detectsMovement: Bool
    /// Called when the simulated phone leaves for `spot`.
    public var onMove: ((SeatSpot) -> Void)?

    public private(set) var isStarted = false
    /// The spots moved to, in order.
    public private(set) var moves: [SeatSpot] = []

    private var readsLeft = 0
    private var moveEnds: ContinuousClock.Instant?

    public init(pacing: Pacing = .realTime, movingReads: Int = 5, moveDuration: Double = 2, detectsMovement: Bool = true) {
        self.pacing = pacing
        self.movingReads = movingReads
        self.moveDuration = moveDuration
        self.detectsMovement = detectsMovement
    }

    /// False while a move is under way (when movement is detected). With `.immediate` pacing every read counts down
    /// the move.
    public var isSteady: Bool {
        guard detectsMovement else { return true }
        switch pacing {
        case .immediate:
            guard readsLeft > 0 else { return true }
            readsLeft -= 1
            return false
        case .realTime:
            guard let moveEnds else { return true }
            return ContinuousClock.now >= moveEnds
        }
    }

    public func start() { isStarted = true }

    public func stop() {
        isStarted = false
        readsLeft = 0
        moveEnds = nil
    }

    public func willWaitForStillness(at spot: SeatSpot) {
        guard spot.index > 0 else { return }
        moves.append(spot)
        readsLeft = movingReads
        moveEnds = ContinuousClock.now + .seconds(moveDuration)
        onMove?(spot)
    }
}
