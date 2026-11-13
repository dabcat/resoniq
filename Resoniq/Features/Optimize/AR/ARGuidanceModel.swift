import Foundation
import Observation
import ResoniqRoom
import SwiftUI
import UIKit

/// What drives the AR guide: ARKit world tracking on a device (`LiveARGuidanceSource`), or a script in the
/// simulator and previews (`ScriptedARGuidanceSource`). The screen only talks to `ARGuidanceModel`; the source
/// reports plain values into it with `receive(_:)`.
protocol ARGuidanceSource: AnyObject {
    /// The picture behind the screen with the floor overlays: RealityKit on the camera, or a 2D stand-in.
    func makeCameraView(for model: ARGuidanceModel) -> AnyView
    /// Begin: run the session, or start the script's clock.
    func start(_ model: ARGuidanceModel)
    /// Stop for good: pause the session, end the script.
    func stop()
}

/// The two haptics of the guide (design/tokens.json): `arApproach`, a soft tap repeated faster as the speaker
/// nears its target, and `speakerInPlace`, a success. An addition only: the readout and VoiceOver say the same.
protocol ARGuidanceHaptics: AnyObject {
    func approach()
    func inPlace()
    /// The view the haptics belong to (UIKit's feedback generators are tied to one); a no-op for silent haptics.
    func attach(to view: UIView)
}

/// No haptics: the scripted guide in the simulator and previews.
final class SilentARGuidanceHaptics: ARGuidanceHaptics {
    func approach() {}
    func inPlace() {}
    func attach(to view: UIView) {}
}

/// UIKit's feedback generators, made for the AR view once it exists (`init(style:view:)`, iOS 17.5).
final class UIKitARGuidanceHaptics: ARGuidanceHaptics {
    private var impact: UIImpactFeedbackGenerator?
    private var notification: UINotificationFeedbackGenerator?

    func attach(to view: UIView) {
        guard impact == nil else { return }
        impact = UIImpactFeedbackGenerator(style: .soft, view: view)
        notification = UINotificationFeedbackGenerator(view: view)
        impact?.prepare()
    }

    func approach() {
        impact?.impactOccurred()
        impact?.prepare()
    }

    func inPlace() {
        notification?.notificationOccurred(.success)
    }
}

/// What the floor overlay draws, in AR world coordinates: plain values from the Kit's geometry, so the RealityKit
/// view and the simulator's 2D stand-in draw the same thing. Equatable, so the views redraw only on change.
struct ARFloorDrawing: Equatable {
    var reticle: FloorHit?
    /// The floor's world height under the speaker.
    var floorHeight: Double
    /// The target footprint (dashed, marching `guide` outline with a faint fill).
    var target: OrientedRect?
    /// The speaker's current footprint (`ivory` outline).
    var speaker: OrientedRect?
    /// The turn arc and where its label sits; nil unless the turn step shows.
    var arc: [PlanPoint]?
    var arcLabel: PlanPoint?
    var arcText: String?
    /// The camera, for the simulator's stand-in projection.
    var camera: Viewer?

    static let empty = ARFloorDrawing(floorHeight: 0)
}

/// The live state of the AR guide (V3OAR): drives the Kit's `ARGuidanceState` reducer with events from the
/// source and the screen, plays the haptics, speaks progress to VoiceOver, and exposes what the views draw.
///
/// Updates arrive from the source at its own rate (the live source polls at 15 Hz, see `LiveARGuidanceSource`);
/// the state is replaced only when the reducer changes it.
@Observable
final class ARGuidanceModel {
    private(set) var state: ARGuidanceState
    /// Where the turn arc's label is on screen, points in the camera view; set by the RealityKit view, which is
    /// the only thing that can project the floor.
    private(set) var arcLabelPoint: CGPoint?

    @ObservationIgnored let source: any ARGuidanceSource
    @ObservationIgnored let haptics: any ARGuidanceHaptics
    @ObservationIgnored private var announcer = ARProgressAnnouncer()
    @ObservationIgnored private var hapticTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var hasStopped = false
    @ObservationIgnored private let startedAt = ContinuousClock.now

    init(suggestion: PlacementSuggestion, room: RoomModel, source: any ARGuidanceSource,
         haptics: any ARGuidanceHaptics = SilentARGuidanceHaptics()) {
        state = ARGuidanceState(suggestion: suggestion, room: room)
        self.source = source
        self.haptics = haptics
    }

    // MARK: For the views

    var drawing: ARFloorDrawing {
        var drawing = ARFloorDrawing(floorHeight: state.floorHeight ?? state.reticle?.height ?? 0)
        drawing.camera = state.camera
        drawing.reticle = state.phase.isFinished ? nil : state.reticle
        guard !state.phase.isFinished else { return drawing }
        drawing.target = state.targetFootprint
        drawing.speaker = state.speakerFootprint
        if state.showsTurn, let speaker = state.speaker, let target = state.target {
            let arc = ARGuidanceGeometry.turnArc(speaker: speaker, target: target, size: state.size)
            drawing.arc = arc.points
            drawing.arcLabel = arc.label
            drawing.arcText = state.arcLabel
        }
        return drawing
    }

    /// The instruction while the guide is not on a step, or tracking is not to be trusted.
    var message: ARGuidanceMessage? {
        if let tracking = ARGuidanceText.tracking(state.tracking), !state.phase.isFinished,
           state.isFloorFound || state.tracking != .limited(.initializing) {
            return tracking
        }
        switch state.phase {
        case .findingFloor: return ARGuidanceText.findFloor
        case .markingSpeaker: return state.reticle == nil ? ARGuidanceText.markAimLower : ARGuidanceText.markSpeaker
        default: return nil
        }
    }

    // MARK: From the screen

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        source.start(self)
    }

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        hapticTask?.cancel()
        hapticTask = nil
        source.stop()
    }

    func mark() { apply([.marked]) }
    func setFollowing(_ on: Bool) { apply([.follow(on)]) }
    func remark() { apply([.remark]) }
    func confirm() { apply([.confirm]) }
    func decline() { apply([.decline]) }

    func setArcLabelPoint(_ point: CGPoint?) {
        if point != arcLabelPoint { arcLabelPoint = point }
    }

    // MARK: From the source

    func receive(_ events: [ARGuidanceEvent]) { apply(events) }

    // MARK: Applying

    private func apply(_ events: [ARGuidanceEvent]) {
        var next = state
        var effects: [ARGuidanceEffect] = []
        for event in events { effects += next.apply(event) }
        let before = state
        if next != state { state = next }
        for effect in effects { perform(effect) }
        announce(from: before, to: state)
        updateHapticLoop()
        if state.phase.isFinished { stop() }
    }

    private func perform(_ effect: ARGuidanceEffect) {
        switch effect {
        case .reachedPosition: haptics.inPlace()
        case .placed, .declined: break
        }
    }

    /// The approach taps: one loop while the reducer gives an interval, re-reading it after every tap so the
    /// pace follows the distance. It ends by itself when the interval goes away.
    private func updateHapticLoop() {
        guard hapticTask == nil, !hasStopped, state.hapticInterval != nil else { return }
        hapticTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let interval = self.state.hapticInterval else { break }
                self.haptics.approach()
                guard (try? await Task.sleep(for: .seconds(interval))) != nil else { break }
            }
            self?.hapticTask = nil
        }
    }

    /// VoiceOver: a new step or tracking message is said at once; the distance at `ARProgressAnnouncer`'s pace.
    private func announce(from before: ARGuidanceState, to after: ARGuidanceState) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let stepChanged = before.phase != after.phase
        if before.tracking != after.tracking, let message = ARGuidanceText.tracking(after.tracking) {
            post(message.headline)
            return
        }
        if stepChanged {
            announcer.reset()
            if let message, after.readout == nil { post(message.headline) }
            if let readout = after.readout, after.phase != .sliding { post(readout.spoken) }
        }
        if after.phase == .sliding, after.tracking.isNormal, let progress = after.progress,
           let line = announcer.announcement(for: progress, at: (ContinuousClock.now - startedAt).seconds) {
            post(line)
        }
    }

    private func post(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

/// Whether the AR guide can run here, and what drives it. The decision is the Kit's `ScanReadiness` (no AR → the
/// unsupported state; the camera's permission as for the scan).
///
/// The simulator, and the previews that run on it, always get the scripted guide and are treated as ready.
enum ARGuidanceCapability {
    static func readiness() -> ScanReadiness {
        #if targetEnvironment(simulator)
        .ready
        #else
        ScanReadiness(isSupported: LiveARGuidanceSource.isSupported, camera: ScanCapability.cameraPermission())
        #endif
    }

    static func makeSource() -> any ARGuidanceSource {
        #if targetEnvironment(simulator)
        ScriptedARGuidanceSource(script: .whole)
        #else
        LiveARGuidanceSource()
        #endif
    }

    static func makeHaptics() -> any ARGuidanceHaptics {
        #if targetEnvironment(simulator)
        SilentARGuidanceHaptics()
        #else
        UIKitARGuidanceHaptics()
        #endif
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
