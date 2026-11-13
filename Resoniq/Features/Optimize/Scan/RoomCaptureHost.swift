#if canImport(RoomPlan) && !targetEnvironment(simulator)
import ARKit
import os
import ResoniqRoom
import RoomPlan
import SwiftUI

// RoomPlan on a LiDAR device, ported from RoomScan (docs/reference/iosar-roomplan-arkit.md, "Session setup and
// lifecycle"; iosar RoomScan/Capture/RoomCaptureFlow.swift, CaptureCoordinator.swift, SessionDelegateProxy.swift).
// Compiled out of the simulator build, where RoomPlan cannot run; there the scripted source stands in.

/// The live source: RoomPlan's camera view, started when it appears and stopped by Finish or Cancel.
final class LiveRoomScanSource: RoomScanSource {
    fileprivate weak var controller: RoomCaptureHostController?

    func makeCameraView(for model: RoomScanModel) -> AnyView {
        AnyView(RoomCaptureRepresentable(model: model, source: self).ignoresSafeArea())
    }

    /// The session starts when the camera view appears (`viewDidAppear`), not here.
    func start(_ model: RoomScanModel) {}

    func finish() { controller?.stopScanning(cancelled: false) }

    func cancel() { controller?.stopScanning(cancelled: true) }
}

/// Hosts `RoomCaptureView`. RoomPlan gives the camera, the outlines and the processing, but no Done button:
/// stopping the session is the app's job, and stopping is what makes RoomPlan process the scan.
struct RoomCaptureRepresentable: UIViewControllerRepresentable {
    let model: RoomScanModel
    let source: LiveRoomScanSource

    func makeCoordinator() -> RoomCaptureCoordinator { RoomCaptureCoordinator(model: model) }

    func makeUIViewController(context: Context) -> RoomCaptureHostController {
        let controller = RoomCaptureHostController(coordinator: context.coordinator, model: model)
        source.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: RoomCaptureHostController, context: Context) {}
}

/// What the session delegate proxy hands to the main actor, in order: plain values only, converted where RoomPlan
/// called from (`CapturedRoom` and `RoomCaptureSession.Instruction` stay on that side).
nonisolated enum RoomCaptureEvent: Sendable {
    case room(RoomModel, [ScanMarker])
    case instruction(ScanInstruction)
}

final class RoomCaptureHostController: UIViewController {
    private static let log = Logger(subsystem: "com.matovic.resoniq", category: "RoomCapture")
    /// How often the labels follow the camera.
    private static let overlayInterval = Duration.milliseconds(100)
    /// A marker closer than this in front of the camera, or behind it, gets no label, metres.
    private static let nearestLabel: Float = 0.2

    /// The one camera owner. RoomPlan runs on it (`RoomCaptureView(frame:arSession:)`, iOS 17), so the AR guide of
    /// phase 5 can share the same session pattern. No delegate is set on it: the labels poll `currentFrame`.
    private let session = ARSession()
    private let captureView: RoomCaptureView
    private let coordinator: RoomCaptureCoordinator
    private let model: RoomScanModel
    private var proxy: SessionDelegateProxy?
    private var hasStarted = false
    private var hasStopped = false
    private var markers: [ScanMarker] = []
    private var eventTask: Task<Void, Never>?
    private var overlayTask: Task<Void, Never>?
    private let events: AsyncStream<RoomCaptureEvent>
    private let eventSink: AsyncStream<RoomCaptureEvent>.Continuation

    init(coordinator: RoomCaptureCoordinator, model: RoomScanModel) {
        self.coordinator = coordinator
        self.model = model
        (events, eventSink) = AsyncStream.makeStream(of: RoomCaptureEvent.self, bufferingPolicy: .bufferingNewest(8))
        captureView = RoomCaptureView(frame: .zero, arSession: session)
        super.init(nibName: nil, bundle: nil)
        captureView.delegate = coordinator
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = captureView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // viewDidAppear can fire again (a sheet dismissed over it). A stopped scan stays stopped: running RoomPlan
        // again restarts LiDAR for a coordinator that has already finished (RoomScan audit CO2).
        guard !hasStarted, !hasStopped else { return }
        hasStarted = true
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        captureView.captureSession.run(configuration: configuration)
        // After `run`, as RoomScan does: the proxy stands in front of the view's own session delegate.
        proxy = SessionDelegateProxy.install(on: captureView.captureSession, events: eventSink)
        if proxy == nil { Self.log.notice("No session delegate to forward to; the inset and labels stay empty") }
        startEvents()
        startOverlay()
        model.didStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leaving the screen without Finish abandons the scan (RoomScan processes here; Resoniq has Close for that).
        stopScanning(cancelled: true)
    }

    /// Stopping the session is what makes RoomPlan process the scan and call the view delegate. Guarded so a
    /// double tap cannot stop twice. A cancelled scan tells the delegate first, so nothing is processed.
    func stopScanning(cancelled: Bool) {
        guard !hasStopped else { return }
        hasStopped = true
        overlayTask?.cancel()
        // The view's own delegate is back before the session stops, so RoomPlan's processing never runs through the
        // proxy (`SessionDelegateProxy.restore`).
        proxy?.restore(on: captureView.captureSession)
        proxy = nil
        eventSink.finish()
        if cancelled { coordinator.isCancelled = true }
        // A session that already ended with an error has nothing to stop.
        guard hasStarted, !coordinator.hasFinished else { return }
        captureView.captureSession.stop()
    }

    private func startEvents() {
        let events = events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .room(let room, let markers):
                    self.markers = markers
                    self.model.update(room: room)
                case .instruction(let instruction):
                    self.model.update(instruction: instruction)
                }
            }
        }
    }

    private func startOverlay() {
        overlayTask = Task { [weak self] in
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: Self.overlayInterval)) != nil else { return }
                self?.updateOverlay()
            }
        }
    }

    /// Projects the markers into the view and reads the camera's plan pose. Reads `currentFrame` and lets go of it
    /// before returning: holding an `ARFrame` stalls ARKit and RoomPlan with it (RoomScan pitfall 3).
    private func updateOverlay() {
        guard let frame = session.currentFrame else { return }
        let camera = frame.camera
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let transform = camera.transform
        let forward = PlanPoint(x: Double(-transform.columns.2.x), z: Double(-transform.columns.2.z))
        let pose = forward.length > 1e-6
            ? ScanCameraPose(
                position: PlanPoint(x: Double(transform.columns.3.x), z: Double(transform.columns.3.z)),
                heading: forward.angle)
            : nil
        let worldToCamera = transform.inverse
        let bounds = CGRect(origin: .zero, size: size)
        let labels = markers.compactMap { marker -> ScanLabel? in
            guard let text = ScanText.label(for: marker.kind) else { return nil }
            let point = SIMD3<Float>(Float(marker.position.x), Float(marker.position.y), Float(marker.position.z))
            // ARKit's camera looks along its −z.
            guard (worldToCamera * SIMD4<Float>(point, 1)).z < -Self.nearestLabel else { return nil }
            // Portrait only (Info.plist). `projectPoint(_:orientation:viewportSize:)` is deprecated from iOS 27, not
            // at this deployment target (26); its successor needs `ARSession.viewRotationAngle`.
            let projected = camera.projectPoint(point, orientation: .portrait, viewportSize: size)
            guard bounds.contains(projected) else { return nil }
            if case .wall = marker.kind {
                return ScanLabel(id: marker.id, text: text, isMeasurement: true, position: unit(projected, in: size))
            }
            return ScanLabel(id: marker.id, text: text, isMeasurement: false, position: unit(projected, in: size))
        }
        model.update(labels: labels, camera: pose)
    }

    private func unit(_ point: CGPoint, in size: CGSize) -> UnitPoint {
        UnitPoint(x: point.x / size.width, y: point.y / size.height)
    }
}

/// `RoomCaptureViewDelegate` inherits `NSCoding`, so this is an `NSObject` with the coding stubs.
///
/// Main actor (the app's default): RoomCaptureView is main-actor and calls its delegate on the main thread; the
/// conformance is `@preconcurrency`, so a call from anywhere else is a runtime check rather than a silent race.
final class RoomCaptureCoordinator: NSObject, @preconcurrency RoomCaptureViewDelegate {
    nonisolated private static let log = Logger(subsystem: "com.matovic.resoniq", category: "RoomCapture")

    /// Set before the session stops when the person cancels, so the scan is discarded instead of processed.
    var isCancelled = false
    private(set) var hasFinished = false
    private let model: RoomScanModel

    init(model: RoomScanModel) {
        self.model = model
        super.init()
    }

    nonisolated required init?(coder: NSCoder) { nil }
    nonisolated func encode(with coder: NSCoder) {}

    /// Returning true asks RoomPlan to process and call `didPresent`. A cancelled scan returns false. An error is
    /// reported here: RoomScan returns false on an error too, and then `didPresent` is not called, so the error
    /// would otherwise never reach the screen.
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
        guard !isCancelled else { return false }
        if let error {
            fail(with: error)
            return false
        }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {
        guard !isCancelled, !hasFinished else { return }
        if let error {
            fail(with: error)
            return
        }
        guard !processedResult.walls.isEmpty else {
            hasFinished = true
            model.didFail(.noWalls)
            return
        }
        hasFinished = true
        // `CapturedRoom` is Sendable: converted and exported off the main actor, then handed over as a value.
        let model = model
        Task {
            let result = await Self.process(processedResult)
            if !result.lowConfidence.isEmpty || !result.dropped.isEmpty {
                Self.log.notice(
                    "Scan kept \(result.lowConfidence.count) low-confidence items, dropped \(result.dropped.count)")
            }
            model.didFinish(result)
        }
    }

    private func fail(with error: any Error) {
        guard !hasFinished else { return }
        hasFinished = true
        Self.log.error("Scan failed: \(String(describing: error), privacy: .public)")
        model.didFail(ScanFailure(error))
    }

    /// The room, and the USDZ written to a temporary file (parametric: walls, openings and boxes). A failed export
    /// is a missing file, never a failed scan.
    @concurrent
    nonisolated static func process(_ room: CapturedRoom) async -> RoomScanResult {
        let conversion = RoomPlanConverter.conversion(from: room)
        let url = URL.temporaryDirectory.appending(path: "Resoniq-scan-\(UUID().uuidString).usdz")
        var usdz: URL?
        do {
            try room.export(to: url, exportOptions: .parametric)
            usdz = url
        } catch {
            Self.log.error("USDZ export failed: \(String(describing: error), privacy: .public)")
        }
        return RoomScanResult(
            room: conversion.room, lowConfidence: conversion.lowConfidence, dropped: conversion.dropped,
            usdzURL: usdz)
    }
}

extension ScanFailure {
    /// RoomPlan's capture errors one to one (RoomScan's `CaptureFailure`), anything else unknown.
    init(_ error: any Error) {
        guard let error = error as? RoomCaptureSession.CaptureError else {
            self = .unknown
            return
        }
        switch error {
        case .worldTrackingFailure: self = .worldTrackingFailure
        case .exceedSceneSizeLimit: self = .sceneTooLarge
        case .deviceTooHot: self = .deviceTooHot
        case .deviceNotSupported: self = .deviceNotSupported
        case .invalidARConfiguration: self = .invalidConfiguration
        case .internalError: self = .internalError
        @unknown default: self = .unknown
        }
    }
}

/// Stands in front of `RoomCaptureView`'s own session delegate and forwards every call to it, so the view keeps
/// drawing its outlines and processing the scan, while the in-progress room and the instructions become visible
/// here (RoomScan's `SessionDelegateProxy`).
///
/// RoomScan measured on device (2026-10-20) that installing it suppresses `RoomCaptureView`'s coaching overlay.
/// Resoniq accepts that: the screen shows RoomPlan's instruction itself, in its own words. Taking the delegate
/// outright, instead of forwarding, would break the view.
///
/// Not isolated: RoomPlan calls it on whatever thread it uses. It converts to plain values there and sends them
/// in order through an `AsyncStream`.
nonisolated final class SessionDelegateProxy: NSObject, RoomCaptureSessionDelegate {
    private weak var original: (any RoomCaptureSessionDelegate)?
    private let events: AsyncStream<RoomCaptureEvent>.Continuation

    private init(original: any RoomCaptureSessionDelegate, events: AsyncStream<RoomCaptureEvent>.Continuation) {
        self.original = original
        self.events = events
    }

    /// Nil when there is no delegate to stand in front of.
    static func install(on session: RoomCaptureSession, events: AsyncStream<RoomCaptureEvent>.Continuation)
        -> SessionDelegateProxy?
    {
        guard let existing = session.delegate, !(existing is SessionDelegateProxy) else { return nil }
        let proxy = SessionDelegateProxy(original: existing, events: events)
        session.delegate = proxy
        return proxy
    }

    /// The session holds its delegate weakly, so the caller keeps the proxy and restores the original here.
    func restore(on session: RoomCaptureSession) {
        guard session.delegate === self else { return }
        session.delegate = original
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        original?.captureSession(session, didUpdate: room)
        publish(room)
    }

    func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
        original?.captureSession(session, didAdd: room)
        publish(room)
    }

    func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) {
        original?.captureSession(session, didChange: room)
        publish(room)
    }

    func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom) {
        original?.captureSession(session, didRemove: room)
        publish(room)
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        events.yield(.instruction(Self.instruction(instruction)))
        original?.captureSession(session, didProvide: instruction)
    }

    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        original?.captureSession(session, didStartWith: configuration)
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        original?.captureSession(session, didEndWith: data, error: error)
    }

    private func publish(_ room: CapturedRoom) {
        events.yield(.room(RoomPlanConverter.partial(from: room), RoomPlanConverter.markers(from: room)))
    }

    static func instruction(_ instruction: RoomCaptureSession.Instruction) -> ScanInstruction {
        switch instruction {
        case .moveCloseToWall: .moveCloser
        case .moveAwayFromWall: .moveAway
        case .slowDown: .slowDown
        case .turnOnLight: .turnOnLight
        case .lowTexture: .lowTexture
        case .normal: .normal
        @unknown default: .normal
        }
    }
}
#endif
