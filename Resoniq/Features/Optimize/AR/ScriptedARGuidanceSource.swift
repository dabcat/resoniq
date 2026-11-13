import Foundation
import ResoniqRoom
import SwiftUI

/// The AR guide without ARKit, for the simulator and previews: a scripted floor, a mark on the speaker's front edge,
/// a second mark on the other speaker's front (or the floor under the seat), then a reticle that slides from the
/// speaker's place toward the target, so the whole screen runs unattended. The world is the room model turned and
/// shifted, as a fresh AR session would put it, so the two-point alignment is exercised too.
final class ScriptedARGuidanceSource: ARGuidanceSource {
    enum Script: Sendable {
        /// Stays on finding the floor.
        case findFloor
        /// Finds the floor and puts the reticle on the speaker's front edge, then waits for the tap.
        case mark
        /// Marks the speaker and puts the reticle on the second point, then waits for the tap.
        case markSecond
        /// Marks the speaker, then a second point 60 cm from where the plan has it: the marks do not agree.
        case disagree
        /// Marks both, follows, and stops 18 cm short as in V3OAR.
        case slide
        /// The whole move: marks both, follows to the target, and waits on the turn (or on "It's in place").
        case whole
        /// Straight to the turn.
        case turn
        /// Straight to the target (use a suggestion without a turn to land on "arrived").
        case arrive
        /// Part of the way, then tracking limited (too little detail).
        case limited
    }

    /// Where the room model sits in the scripted world.
    static let world = WorldAlignment(rotation: 0.5, translation: PlanPoint(x: 0.4, z: -0.8))
    /// V3OAR's state: 18 cm of 35 to go.
    static let mockupFraction = 17.0 / 35.0
    /// How far the second mark lands from the plan in `disagree`, metres.
    static let disagreement = 0.6

    private let script: Script
    private let slideDuration: Duration
    private var task: Task<Void, Never>?
    private weak var model: ARGuidanceModel?

    init(script: Script = .whole, slideDuration: Duration = .seconds(6)) {
        self.script = script
        self.slideDuration = slideDuration
    }

    func makeCameraView(for model: ARGuidanceModel) -> AnyView { AnyView(ARGuidanceCameraStandIn(model: model)) }

    func start(_ model: ARGuidanceModel) {
        self.model = model
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        guard let model else { return }
        let suggestion = model.state.suggestion, size = model.state.size
        let start = Self.world.apply(suggestion.from), end = Self.world.apply(suggestion.to)
        let floor = 0.0
        func frontEdge(_ centre: PlanPoint) -> FloorHit {
            FloorHit(point: ARGuidanceGeometry.frontEdgeCentre(of: PlanPose(position: centre, facing: start.facing), size: size),
                     height: floor)
        }
        // Standing 1.4 m in front of the target, looking back at the speaker.
        let camera = Viewer(position: end.position + PlanPoint(angle: start.facing) * 1.4, heading: start.facing + .pi)
        model.receive([.trackingRecovered, .cameraMoved(camera)])
        guard script != .findFloor else { return }

        guard await pause(.milliseconds(800)) else { return }
        model.receive([.floorFound, .reticleMoved(frontEdge(start.position))])
        guard script != .mark else { return }

        guard await pause(.milliseconds(800)) else { return }
        model.mark()
        // The second point: where the plan has it, carried into the scripted world.
        guard let reference = model.state.reference else { return }
        var second = Self.world.apply(reference.modelPoint)
        if script == .disagree {
            second = second + (second - Self.world.apply(suggestion.from.position)).normalized * Self.disagreement
        }
        guard await pause(.milliseconds(600)) else { return }
        model.receive([.reticleMoved(FloorHit(point: second, height: floor))])
        guard script != .markSecond else { return }

        guard await pause(.milliseconds(800)) else { return }
        model.mark()
        guard script != .disagree else { return }
        // Back to the speaker's front edge before following it.
        model.receive([.reticleMoved(frontEdge(start.position))])
        model.setFollowing(true)

        let quick = script == .turn || script == .arrive
        let stopAt = script == .slide || script == .limited ? Self.mockupFraction : 1
        let duration = quick ? Duration.milliseconds(1200) : slideDuration
        let step = Duration.milliseconds(66)
        let count = max(1, Int(duration / step))
        for index in 1...count {
            guard await pause(step) else { return }
            let t = stopAt * Double(index) / Double(count)
            model.receive([.reticleMoved(frontEdge(start.position + (end.position - start.position) * t))])
        }
        model.setFollowing(false)
        if script == .limited { model.receive([.trackingDegraded(.insufficientFeatures)]) }
    }

    private func pause(_ duration: Duration) async -> Bool {
        (try? await Task.sleep(for: duration)) != nil
    }
}
