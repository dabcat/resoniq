import Foundation

/// Where the reticle at the centre of the screen meets the floor, in AR world coordinates: the plan point and the
/// floor's height (world y), metres. The app finds it with one raycast a frame against detected horizontal planes.
public struct FloorHit: Sendable, Equatable {
    public var point: PlanPoint
    public var height: Double

    public init(point: PlanPoint, height: Double) {
        self.point = point
        self.height = height
    }
}

/// Why world tracking is limited, as plain values (ARKit's `ARCamera.TrackingState.Reason`, plus `tooDark`, which
/// ARKit reports as too few features in a dim room).
public enum ARTrackingIssue: Sendable, Equatable, CaseIterable {
    case initializing
    case excessiveMotion
    case insufficientFeatures
    case tooDark
    /// After an interruption, until ARKit has found where it was.
    case relocalizing
    /// ARKit says tracking is not available at all.
    case unavailable

    /// Below this ambient light, lumens (ARKit's `ARLightEstimate.ambientIntensity`, about 1000 in a well-lit
    /// room), too few features is put down to the dark. A first guess.
    public static let darkAmbientIntensity = 120.0

    /// ARKit's "insufficient features", told apart from a dark room by the light estimate when there is one.
    public static func insufficientFeatures(ambientIntensity: Double?) -> ARTrackingIssue {
        guard let ambientIntensity, ambientIntensity.isFinite else { return .insufficientFeatures }
        return ambientIntensity < darkAmbientIntensity ? .tooDark : .insufficientFeatures
    }
}

/// How far the phone's sense of the world can be trusted right now.
public enum ARTracking: Sendable, Equatable {
    case normal
    case limited(ARTrackingIssue)
    /// The session is interrupted (another app has the camera, the app is in the background).
    case interrupted

    public var isNormal: Bool { self == .normal }
}

/// Where AR guidance is.
public enum ARGuidancePhase: Sendable, Equatable {
    /// No horizontal plane yet.
    case findingFloor
    /// The floor is found; the person puts the reticle on the speaker's front edge and taps "This is the speaker".
    case markingSpeaker
    /// The target is drawn; the speaker is short of it.
    case sliding
    /// In position, with a turn still to make. The phone cannot see the speaker turn: the person turns it by eye
    /// and confirms.
    case turning
    /// In position and nothing to turn; waiting for "It's in place".
    case arrived
    /// "It's in place": the speaker's new pose in room-model coordinates.
    case placed(PlanPose)
    /// "Can't move it".
    case declined

    public var isFinished: Bool {
        switch self {
        case .placed, .declined: true
        default: false
        }
    }
}

/// What can happen during AR guidance: from the AR session (floor, reticle, camera, tracking) or from the person.
public enum ARGuidanceEvent: Sendable, Equatable {
    /// A horizontal plane was detected.
    case floorFound
    /// The reticle's floor point this frame, or nil when the centre of the screen is not on the floor.
    case reticleMoved(FloorHit?)
    /// The camera's place and heading on the floor, world coordinates.
    case cameraMoved(Viewer)
    /// "This is the speaker".
    case marked
    /// The follow control held (true) or let go (false).
    case follow(Bool)
    /// "Mark it again": throw the alignment away and mark the speaker afresh.
    case remark
    /// "It's in place".
    case confirm
    /// "Can't move it".
    case decline
    case trackingDegraded(ARTrackingIssue)
    case trackingRecovered
    case interrupted
    case interruptionEnded
}

/// What the app does once, in answer to an event: a haptic, or handing the result back.
public enum ARGuidanceEffect: Sendable, Equatable {
    /// The speaker came within `MoveGuidance.positionTolerance` of the target (the `speakerInPlace` haptic).
    case reachedPosition
    case placed(PlanPose)
    case declined
}

/// The AR guide for one `PlacementSuggestion`, as a pure reducer: events in, state and effects out. Tested on the
/// Mac; the app's `ARGuidanceModel` feeds it from the AR session and the screen.
///
/// What the phone measures and what the person confirms:
/// - **Measured by the phone:** the floor plane, the reticle's point on it (a raycast), the camera's position and
///   heading, and the tracking quality.
/// - **Confirmed by the person:** that the reticle is on the middle of the speaker's front edge when they tap
///   "This is the speaker" (which, with the camera's heading, fixes the speaker's world pose and the
///   `WorldAlignment`), that the reticle is on the front edge again while they hold "follow" (the phone does not
///   track the loudspeaker; the current footprint is where the person points), and the turn, which the phone
///   cannot see at all. The returned pose's facing is the suggestion's target facing, because the person said
///   they turned it so.
public struct ARGuidanceState: Sendable, Equatable {
    /// How far the speaker may drift back out of position before the guide goes back to sliding: twice the
    /// arrival tolerance, so a reticle that wobbles at the boundary does not flicker between steps.
    public static let leavePositionDistance = 2 * MoveGuidance.positionTolerance

    public let suggestion: PlacementSuggestion
    /// The speaker's footprint, from the room model.
    public let size: FootprintSize

    public private(set) var phase: ARGuidancePhase = .findingFloor
    public private(set) var tracking: ARTracking = .limited(.initializing)
    public private(set) var isFloorFound = false
    public private(set) var reticle: FloorHit?
    public private(set) var camera: Viewer?
    /// Room model to world, from the mark; nil before it.
    public private(set) var alignment: WorldAlignment?
    /// The speaker's centre and facing in the world, as last marked or followed; nil before the mark.
    public private(set) var speaker: PlanPose?
    /// The floor's world height under the speaker, from the mark.
    public private(set) var floorHeight: Double?
    public private(set) var isFollowing = false

    public init(suggestion: PlacementSuggestion, size: FootprintSize) {
        self.suggestion = suggestion
        self.size = size
    }

    /// The footprint size is the room's for this speaker, or the default for its role.
    public init(suggestion: PlacementSuggestion, room: RoomModel) {
        let size = room.speaker(suggestion.speakerID)?.size
            ?? (suggestion.role == .subwoofer ? PlacedSpeaker.defaultSubwooferSize : PlacedSpeaker.defaultSize)
        self.init(suggestion: suggestion, size: size)
    }

    // MARK: Derived

    /// The tap can be taken as a mark: floor found, tracking normal, the reticle on the floor and a camera heading.
    public var canMark: Bool {
        phase == .markingSpeaker && tracking.isNormal && reticle != nil && camera != nil
    }

    public var canConfirm: Bool { phase == .turning || phase == .arrived }

    /// Whether the person needs to see the follow control: the target is on the floor and not yet finished.
    public var canFollow: Bool { phase == .sliding || phase == .turning || phase == .arrived }

    /// The suggestion's target pose in the world.
    public var target: PlanPose? { alignment.map { $0.apply(suggestion.to) } }

    public var targetFootprint: OrientedRect? {
        target.map { ARGuidanceGeometry.footprint(of: $0, size: size) }
    }

    public var speakerFootprint: OrientedRect? {
        speaker.map { ARGuidanceGeometry.footprint(of: $0, size: size) }
    }

    /// The speaker's pose in room-model coordinates.
    public var speakerInModel: PlanPose? {
        guard let alignment, let speaker else { return nil }
        return alignment.inverse.apply(speaker)
    }

    /// How far the move has come, in room-model coordinates, seen by the camera (or, before there is one, by
    /// someone standing in front of the target).
    public var progress: MoveProgress? {
        guard let alignment, let current = speakerInModel else { return nil }
        let viewer: Viewer
        if let camera {
            viewer = Viewer(position: alignment.inverse.apply(camera.position),
                            heading: alignment.inverse.apply(heading: camera.heading))
        } else {
            viewer = Viewer(position: suggestion.to.position + PlanPoint(angle: suggestion.to.facing),
                            heading: suggestion.to.facing + .pi)
        }
        return MoveGuidance.progress(current: current, target: suggestion.target, viewer: viewer)
    }

    /// The gap between approach taps, seconds; nil when there should be none (not sliding, tracking not trusted,
    /// in position or out of range).
    public var hapticInterval: TimeInterval? {
        guard phase == .sliding, tracking.isNormal, let progress else { return nil }
        return MoveGuidance.hapticInterval(distance: progress.distanceToGo)
    }

    /// The pose handed back by "It's in place".
    public var placedPose: PlanPose? {
        if case .placed(let pose) = phase { return pose }
        return nil
    }

    /// Whether the turn arc is drawn: in position with a turn left.
    public var showsTurn: Bool { phase == .turning }

    /// Refits the alignment with the speaker's mark and further matched points (the seat, another speaker),
    /// by least squares, with the residual that says whether they agree (`WorldAlignment.isConsistent`). Nil
    /// before the mark. The mark contributes the speaker's centre where it was marked (its place before the move);
    /// its heading is dropped in a fit of two or more points.
    public func refinedAlignment(matching matches: [(model: PlanPoint, world: PlanPoint)]) -> WorldAlignment? {
        guard let alignment, !matches.isEmpty else { return nil }
        let model = [suggestion.from.position] + matches.map(\.model)
        let world = [alignment.apply(suggestion.from.position)] + matches.map(\.world)
        return WorldAlignment.fit(model: model, world: world)
    }

    // MARK: Reducer

    @discardableResult
    public mutating func apply(_ event: ARGuidanceEvent) -> [ARGuidanceEffect] {
        guard !phase.isFinished else { return [] }
        switch event {
        case .floorFound:
            isFloorFound = true
            if phase == .findingFloor { phase = .markingSpeaker }
            return []
        case .reticleMoved(let hit):
            reticle = hit
            return followReticle()
        case .cameraMoved(let viewer):
            camera = viewer
            return []
        case .marked:
            return mark()
        case .follow(let on):
            isFollowing = on && canFollow
            return isFollowing ? followReticle() : []
        case .remark:
            guard isFloorFound else { return [] }
            phase = .markingSpeaker
            alignment = nil
            speaker = nil
            floorHeight = nil
            isFollowing = false
            return []
        case .confirm:
            guard canConfirm, let current = speakerInModel else { return [] }
            let pose = PlanPose(position: current.position, facing: suggestion.to.facing)
            phase = .placed(pose)
            isFollowing = false
            return [.placed(pose)]
        case .decline:
            phase = .declined
            isFollowing = false
            return [.declined]
        case .trackingDegraded(let issue):
            tracking = .limited(issue)
            return []
        case .trackingRecovered:
            tracking = .normal
            return followReticle()
        case .interrupted:
            tracking = .interrupted
            return []
        case .interruptionEnded:
            tracking = .limited(.relocalizing)
            return []
        }
    }

    private mutating func mark() -> [ARGuidanceEffect] {
        guard canMark, let reticle, let camera else { return [] }
        // The person faces the speaker, so the speaker faces back along the camera's heading.
        let facing = PlanAngle.normalized(camera.heading + .pi)
        let centre = ARGuidanceGeometry.centre(behindFrontEdge: reticle.point, facing: facing, size: size)
        alignment = WorldAlignment(
            modelPoint: suggestion.from.position, worldPoint: centre,
            modelHeading: suggestion.from.facing, worldHeading: facing)
        speaker = PlanPose(position: centre, facing: facing)
        floorHeight = reticle.height
        isFollowing = false
        phase = .sliding
        _ = updatePhase()
        return []
    }

    /// Moves the speaker to the reticle while following and the reticle can be trusted, then updates the step.
    private mutating func followReticle() -> [ARGuidanceEffect] {
        guard isFollowing, canFollow, tracking.isNormal, let reticle, let current = speaker else { return [] }
        speaker = PlanPose(
            position: ARGuidanceGeometry.centre(behindFrontEdge: reticle.point, facing: current.facing, size: size),
            facing: current.facing)
        return updatePhase()
    }

    private mutating func updatePhase() -> [ARGuidanceEffect] {
        guard let progress else { return [] }
        let needsTurn = abs(progress.turnRemaining) > MoveGuidance.angleTolerance
        switch phase {
        case .sliding where progress.isInPosition:
            phase = needsTurn ? .turning : .arrived
            return [.reachedPosition]
        case .turning, .arrived:
            if progress.distanceToGo > Self.leavePositionDistance { phase = .sliding }
            return []
        default:
            return []
        }
    }
}
