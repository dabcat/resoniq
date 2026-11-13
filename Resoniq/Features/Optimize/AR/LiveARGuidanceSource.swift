#if !targetEnvironment(simulator)
import ARKit
import os
import ResoniqRoom
import SwiftUI

// ARKit world tracking on a device, ported from RoomScan (docs/reference/iosar-roomplan-arkit.md, "(c) ARKit and
// RealityKit guidance", "Session setup and lifecycle", "Relocalization"; iosar RoomScan/Capture/ARFrameHub.swift,
// RoomScan/Rescan/RescanOverlay.swift, RescanCaptureController.runSession). Compiled out of the simulator build,
// where there is no camera; there the scripted source stands in.

/// The live source: owns the one `ARSession` (world tracking, horizontal planes), and the RealityKit view shares it.
///
/// - **Measured here:** the camera's pose, the tracking state and the reticle's floor point (one raycast at the
///   centre of the screen per poll, against detected plane geometry first and an estimated plane as the fallback).
/// - **Not measured:** where the loudspeaker is or how it is turned. ARKit does not track an arbitrary speaker;
///   the person points the reticle at it (see `ARGuidanceState`).
///
/// Isolation, as RoomScan's: the delegate is a separate `Sendable` object on its own serial queue that only
/// forwards interruptions and failures as plain values; the 60 Hz frame path is not used at all. Instead the main
/// actor polls `currentFrame` at `pollInterval`, copies the few numbers it needs and lets the frame go before
/// returning (holding `ARFrame`s stalls ARKit: RoomScan pitfall 3). That is one raycast and one state update per
/// poll and nothing per frame.
final class LiveARGuidanceSource: ARGuidanceSource {
    private static let log = Logger(subsystem: "com.matovic.resoniq", category: "ARGuidance")
    /// How often the reticle, camera and tracking are read: enough for a footprint that follows a hand, a quarter
    /// of ARKit's frame rate.
    static let pollInterval = Duration.milliseconds(66)

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    private let session = ARSession()
    private let delegateQueue = DispatchQueue(label: "com.matovic.resoniq.ARGuidance.delegate", qos: .userInteractive)
    private let delegate: ARGuidanceSessionDelegate
    private let signals: AsyncStream<ARSessionSignal>
    private weak var model: ARGuidanceModel?
    private var hasStarted = false
    private var hasStopped = false
    private var pollTask: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?
    private var isFloorReported = false
    /// The tracking last sent to the model; nil to send the next one whatever it is.
    private var lastTracking: ARTracking?
    /// The session failed: tracking stays unavailable whatever the last frame says.
    private var hasFailed = false

    init() {
        let (signals, continuation) = AsyncStream.makeStream(of: ARSessionSignal.self, bufferingPolicy: .bufferingNewest(8))
        self.signals = signals
        delegate = ARGuidanceSessionDelegate(signals: continuation)
        session.delegateQueue = delegateQueue
        session.delegate = delegate
    }

    func makeCameraView(for model: ARGuidanceModel) -> AnyView {
        AnyView(ARGuidanceRealityView(model: model, session: session).ignoresSafeArea())
    }

    /// Runs world tracking with horizontal plane detection. `options: []`, never `.resetTracking`, which would move
    /// the world origin under an alignment already made (RoomScan pitfall 5).
    func start(_ model: ARGuidanceModel) {
        guard !hasStarted, !hasStopped else { return }
        hasStarted = true
        self.model = model
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        session.run(configuration, options: [])
        startSignals()
        startPolling()
    }

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        pollTask?.cancel()
        signalTask?.cancel()
        delegate.finish()
        session.pause()
    }

    private func startSignals() {
        let signals = signals
        signalTask = Task { [weak self] in
            for await signal in signals {
                guard let self else { return }
                switch signal {
                case .interrupted:
                    self.lastTracking = nil
                    self.model?.receive([.interrupted])
                case .interruptionEnded:
                    // ARKit relocalizes against this session's own map (`sessionShouldAttemptRelocalization`).
                    self.lastTracking = nil
                    self.model?.receive([.interruptionEnded])
                case .failed(let description):
                    Self.log.error("AR session failed: \(description, privacy: .public)")
                    self.hasFailed = true
                    self.model?.receive([.trackingDegraded(.unavailable)])
                }
            }
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: Self.pollInterval)) != nil else { return }
                self?.poll()
            }
        }
    }

    /// One reading of the session, synchronous so the frame cannot outlive it.
    private func poll() {
        guard let model, let frame = session.currentFrame else { return }
        let camera = frame.camera
        var events: [ARGuidanceEvent] = []

        let tracking = Self.tracking(camera.trackingState, ambientIntensity: frame.lightEstimate.map { Double($0.ambientIntensity) })
        if !hasFailed, tracking != lastTracking {
            lastTracking = tracking
            switch tracking {
            case .normal: events.append(.trackingRecovered)
            case .limited(let issue): events.append(.trackingDegraded(issue))
            case .interrupted: break
            }
        }
        if let viewer = Self.viewer(camera.transform) { events.append(.cameraMoved(viewer)) }

        let hit = floorHit(in: frame)
        if !isFloorReported, hit?.isOnPlane == true {
            isFloorReported = true
            events.append(.floorFound)
        }
        events.append(.reticleMoved(hit?.hit))
        model.receive(events)
    }

    /// The centre of the screen on the floor: detected plane geometry first, an estimated horizontal plane when the
    /// reticle is off the detected area. A plane ARKit classifies as a table or a seat is not the floor.
    private func floorHit(in frame: ARFrame) -> (hit: FloorHit, isOnPlane: Bool)? {
        let centre = CGPoint(x: 0.5, y: 0.5)
        let onPlane = frame.raycastQuery(from: centre, allowing: .existingPlaneGeometry, alignment: .horizontal)
        if let result = session.raycast(onPlane).first(where: { Self.isFloor($0.anchor) }) {
            return (Self.hit(result.worldTransform), true)
        }
        let estimated = frame.raycastQuery(from: centre, allowing: .estimatedPlane, alignment: .horizontal)
        if let result = session.raycast(estimated).first {
            return (Self.hit(result.worldTransform), false)
        }
        return nil
    }

    private static func isFloor(_ anchor: ARAnchor?) -> Bool {
        guard let plane = anchor as? ARPlaneAnchor, ARPlaneAnchor.isClassificationSupported else { return true }
        switch plane.classification {
        case .table, .seat: return false
        default: return true
        }
    }

    private static func hit(_ transform: simd_float4x4) -> FloorHit {
        let p = transform.columns.3
        return FloorHit(point: PlanPoint(x: Double(p.x), z: Double(p.z)), height: Double(p.y))
    }

    /// The camera on the floor plan: its position, and the way it looks projected onto the floor. Aimed nearly
    /// straight down, the look has no horizontal part, so the top of the phone (the camera's −x in portrait)
    /// stands in for it.
    static func viewer(_ transform: simd_float4x4) -> Viewer? {
        let look = PlanPoint(x: Double(-transform.columns.2.x), z: Double(-transform.columns.2.z))
        let top = PlanPoint(x: Double(-transform.columns.0.x), z: Double(-transform.columns.0.z))
        let forward = look.length > 0.3 ? look : top
        guard forward.length > 1e-6 else { return nil }
        let position = PlanPoint(x: Double(transform.columns.3.x), z: Double(transform.columns.3.z))
        return Viewer(position: position, heading: forward.angle)
    }

    static func tracking(_ state: ARCamera.TrackingState, ambientIntensity: Double?) -> ARTracking {
        switch state {
        case .normal: .normal
        case .notAvailable: .limited(.unavailable)
        case .limited(let reason):
            switch reason {
            case .initializing: .limited(.initializing)
            case .excessiveMotion: .limited(.excessiveMotion)
            case .insufficientFeatures: .limited(ARTrackingIssue.insufficientFeatures(ambientIntensity: ambientIntensity))
            case .relocalizing: .limited(.relocalizing)
            @unknown default: .limited(.initializing)
            }
        }
    }
}

/// What the session delegate hands to the main actor.
nonisolated enum ARSessionSignal: Sendable {
    case interrupted
    case interruptionEnded
    case failed(String)
}

/// The session's delegate, on the session's serial queue. It holds only a continuation (`Sendable`), so it is
/// `Sendable` without a lock, and it never touches a frame: no `session(_:didUpdate:)`, so ARKit does not call it
/// at 60 Hz. Relocalization after an interruption is allowed, as for RoomScan's rescan session.
nonisolated final class ARGuidanceSessionDelegate: NSObject, ARSessionDelegate, Sendable {
    private let signals: AsyncStream<ARSessionSignal>.Continuation

    init(signals: AsyncStream<ARSessionSignal>.Continuation) {
        self.signals = signals
    }

    func finish() { signals.finish() }

    func sessionWasInterrupted(_ session: ARSession) { signals.yield(.interrupted) }

    func sessionInterruptionEnded(_ session: ARSession) { signals.yield(.interruptionEnded) }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        signals.yield(.failed(String(describing: error)))
    }
}
#endif
