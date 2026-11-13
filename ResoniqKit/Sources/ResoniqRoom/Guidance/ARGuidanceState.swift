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

/// What the person marks after the speaker, so the plan can be lined up with the room from two points.
public struct ARReference: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Another speaker of the system: the person puts the dot at the middle of its front.
        case speaker(SpeakerRole)
        /// The listening seat: the person puts the dot on the floor below where their head is when they sit.
        case seat
    }

    public var kind: Kind
    /// The point the person marks, in room-model coordinates.
    public var modelPoint: PlanPoint

    public init(kind: Kind, modelPoint: PlanPoint) {
        self.kind = kind
        self.modelPoint = modelPoint
    }

    /// A second point closer than this to the speaker's own mark gives too short a baseline to fix the rotation,
    /// metres. A first guess: with marks good to 2 cm, half a metre still holds the heading to about 3°.
    public static let minimumBaseline = 0.5

    /// The second mark for a move: the other speaker of the pair (a long, visible baseline), else another main
    /// speaker (the farthest), else the primary seat, else a subwoofer. Nil when the room holds nothing else at least
    /// `minimumBaseline` from the speaker being moved.
    public static func choose(for suggestion: PlacementSuggestion, in room: RoomModel) -> ARReference? {
        let size = room.speaker(suggestion.speakerID)?.size
            ?? (suggestion.role == .subwoofer ? PlacedSpeaker.defaultSubwooferSize : PlacedSpeaker.defaultSize)
        let mark = ARGuidanceGeometry.frontEdgeCentre(of: suggestion.from, size: size)
        func far(_ point: PlanPoint) -> Bool { point.distance(to: mark) >= minimumBaseline }
        func reference(_ speaker: PlacedSpeaker) -> ARReference {
            ARReference(kind: .speaker(speaker.role),
                        modelPoint: ARGuidanceGeometry.frontEdgeCentre(of: speaker.pose, size: speaker.size))
        }
        let others = room.speakers.filter { $0.id != suggestion.speakerID }.map(reference).filter { far($0.modelPoint) }
        let partner: SpeakerRole? = switch suggestion.role {
        case .left: .right
        case .right: .left
        default: nil
        }
        if let partner, let found = others.first(where: { $0.kind == .speaker(partner) }) { return found }
        let mains = others.filter { $0.kind != .speaker(.subwoofer) }
        if let farthest = mains.max(by: { $0.modelPoint.distance(to: mark) < $1.modelPoint.distance(to: mark) }) {
            return farthest
        }
        if let seat = room.primarySeat, far(seat.position) { return ARReference(kind: .seat, modelPoint: seat.position) }
        return others.first
    }
}

/// Why the guide cannot draw a target.
public enum ARAlignmentIssue: Sendable, Equatable {
    /// The two marks are not as far apart as the plan says: the root-mean-square residual of the fit, metres, is
    /// above `WorldAlignment.maximumResidual` (infinity when no fit was possible).
    case marksDisagree(residual: Double)
    /// The plan has nothing besides the speaker to mark (no other speaker, no seat far enough away).
    case nothingElseToMark
}

/// "It's in place": where the speaker is now, as the person last pointed at it, in room-model coordinates.
public struct ARPlacement: Sendable, Equatable {
    /// The position the follow control last saw, mapped back through the fitted alignment; the facing is the
    /// suggestion's, because the person turned it by eye and said so.
    public var pose: PlanPose
    /// Metres between that position and the suggestion's target.
    public var distanceFromTarget: Double
    /// Farther than `MoveGuidance.positionTolerance` from the target: the speaker is recorded where it was marked,
    /// which is not the suggested spot.
    public var isApproximate: Bool { distanceFromTarget > MoveGuidance.positionTolerance }

    public init(pose: PlanPose, distanceFromTarget: Double) {
        self.pose = pose
        self.distanceFromTarget = distanceFromTarget
    }
}

/// Where AR guidance is.
public enum ARGuidancePhase: Sendable, Equatable {
    /// No horizontal plane yet.
    case findingFloor
    /// The floor is found; the person puts the reticle on the speaker's front edge and taps "This is the speaker".
    case markingSpeaker
    /// The speaker is marked; the person marks the second point (`ARGuidanceState.reference`). No target yet.
    case markingReference
    /// The marks cannot line the plan up with the room; the person marks again or fixes the layout.
    case cannotAlign(ARAlignmentIssue)
    /// The target is drawn; the speaker is short of it.
    case sliding
    /// In position, with a turn still to make. The phone cannot see the speaker turn: the person turns it by eye
    /// and confirms.
    case turning
    /// In position and nothing to turn; waiting for "It's in place".
    case arrived
    /// "It's in place".
    case placed(ARPlacement)
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
    /// "This is the speaker", then "This is the left speaker" (or "This is my seat") for the second mark.
    case marked
    /// The follow control held (true) or let go (false).
    case follow(Bool)
    /// "Mark again": throw both marks away and start with the speaker.
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
    case placed(ARPlacement)
    case declined
}

/// The AR guide for one `PlacementSuggestion`, as a pure reducer: events in, state and effects out. Tested on the
/// Mac; the app's `ARGuidanceModel` feeds it from the AR session and the screen.
///
/// What the phone measures and what the person confirms:
/// - **Measured by the phone:** the floor plane, the reticle's point on it (a raycast), the camera's position and
///   heading (used only to say "toward you" or "to your left"), and the tracking quality.
/// - **Confirmed by the person:** two marks — the middle of the moving speaker's front edge, then the middle of the
///   other speaker's front (or the floor under the seat) — which fix the `WorldAlignment` by a two-point fit with
///   a residual that says whether they agree with the plan; that the reticle is on the speaker's front edge again
///   while they hold "follow" (the phone does not track the loudspeaker; the current footprint is where the person
///   points); and the turn, which the phone cannot see at all.
///
/// **Why two marks.** One mark plus the camera's heading assumes the person stands square to the speaker and that
/// the plan's facing is the speaker's real facing. A heading error ε then swings a target `d` metres away by about
/// `d·ε` (35 cm at 20° is 12 cm, against a 3 cm arrival tolerance), and nothing can notice: one point leaves no
/// residual. Two marked points fix the rotation from their baseline instead: with marks good to 2 cm on the pair's
/// 2 m baseline the rotation is good to about 0.6°, and a target 35 cm away to a few millimetres; marks that do not
/// fit the plan show as a residual and stop the guide before it draws a wrong target.
///
/// **What still cannot be checked here:** how well a person puts the dot on a front edge, how far ARKit's floor
/// drifts over a walk across the room, and whether the plan's speaker size and facing match the real speaker. Those
/// need a device and a tape measure.
public struct ARGuidanceState: Sendable, Equatable {
    /// How far the speaker may drift back out of position before the guide goes back to sliding: twice the
    /// arrival tolerance, so a reticle that wobbles at the boundary does not flicker between steps.
    public static let leavePositionDistance = 2 * MoveGuidance.positionTolerance

    public let suggestion: PlacementSuggestion
    /// The speaker's footprint, from the room model.
    public let size: FootprintSize
    /// The second point to mark; nil when the room has none (the guide then stops at `cannotAlign`).
    public let reference: ARReference?

    public private(set) var phase: ARGuidancePhase = .findingFloor
    public private(set) var tracking: ARTracking = .limited(.initializing)
    public private(set) var isFloorFound = false
    public private(set) var reticle: FloorHit?
    public private(set) var camera: Viewer?
    /// Where the person marked the middle of the speaker's front edge, world; nil before the first mark.
    public private(set) var speakerMark: PlanPoint?
    /// Where the person marked the second point, world; nil before it.
    public private(set) var referenceMark: PlanPoint?
    /// Room model to world, fitted from the two marks; nil until both agree with the plan.
    public private(set) var alignment: WorldAlignment?
    /// The speaker's centre and facing in the world where it was marked, before the move; nil before the fit.
    public private(set) var markedStart: PlanPose?
    /// The speaker's centre and facing in the world, as last marked or followed; nil before the fit.
    public private(set) var speaker: PlanPose?
    /// The floor's world height under the speaker, from the first mark.
    public private(set) var floorHeight: Double?
    public private(set) var isFollowing = false

    public init(suggestion: PlacementSuggestion, size: FootprintSize, reference: ARReference?) {
        self.suggestion = suggestion
        self.size = size
        self.reference = reference
    }

    /// The footprint size is the room's for this speaker, or the default for its role; the second mark is
    /// `ARReference.choose`'s.
    public init(suggestion: PlacementSuggestion, room: RoomModel) {
        let size = room.speaker(suggestion.speakerID)?.size
            ?? (suggestion.role == .subwoofer ? PlacedSpeaker.defaultSubwooferSize : PlacedSpeaker.defaultSize)
        self.init(suggestion: suggestion, size: size, reference: ARReference.choose(for: suggestion, in: room))
    }

    // MARK: Derived

    /// The tap can be taken as a mark: marking, tracking normal and the reticle on the floor.
    public var canMark: Bool {
        (phase == .markingSpeaker || phase == .markingReference) && tracking.isNormal && reticle != nil
    }

    public var canConfirm: Bool { phase == .turning || phase == .arrived }

    /// Whether the person needs to see the follow control: the target is on the floor and not yet finished.
    public var canFollow: Bool { phase == .sliding || phase == .turning || phase == .arrived }

    /// The suggestion's target pose in the world, once both marks agree.
    ///
    /// A slide is defined relative to the speaker (forward, back, left, right of where it stands), so the target is
    /// the marked speaker's centre displaced by the slide vector turned into the world by the fitted rotation, not
    /// the fitted transform applied to the plan's target: the fit spreads its residual over both marks, and this
    /// keeps the target tied to the speaker the person actually marked. What remains is the rotation's own error,
    /// which turns the slide direction: a slide of `d` metres lands about `d·ε` off for a rotation error ε (with two
    /// marks on a 2 m baseline, ε is a fraction of a degree, so a 35 cm slide is off by millimetres).
    public var target: PlanPose? {
        guard let alignment, let markedStart else { return nil }
        let slide = (suggestion.to.position - suggestion.from.position).rotated(by: alignment.rotation)
        return PlanPose(position: markedStart.position + slide, facing: alignment.apply(heading: suggestion.to.facing))
    }

    public var targetFootprint: OrientedRect? {
        target.map { ARGuidanceGeometry.footprint(of: $0, size: size) }
    }

    public var speakerFootprint: OrientedRect? {
        speaker.map { ARGuidanceGeometry.footprint(of: $0, size: size) }
    }

    /// The speaker's pose in room-model coordinates, through the fitted alignment.
    public var speakerInModel: PlanPose? {
        guard let alignment, let speaker else { return nil }
        return alignment.inverse.apply(speaker)
    }

    /// How far the move has come, measured against the drawn target and seen by the camera (or, before there is one,
    /// by someone standing in front of the target). The world is carried into the suggestion's frame about the
    /// marked speaker, so the distance to go is the distance between the two outlines on the floor.
    public var progress: MoveProgress? {
        guard let alignment, let markedStart, let speaker else { return nil }
        func toMove(_ point: PlanPoint) -> PlanPoint {
            suggestion.from.position + (point - markedStart.position).rotated(by: -alignment.rotation)
        }
        let current = PlanPose(position: toMove(speaker.position),
                               facing: alignment.inverse.apply(heading: speaker.facing))
        let viewer: Viewer
        if let camera {
            viewer = Viewer(position: toMove(camera.position), heading: alignment.inverse.apply(heading: camera.heading))
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

    /// What "It's in place" handed back.
    public var placement: ARPlacement? {
        if case .placed(let placement) = phase { return placement }
        return nil
    }

    /// The pose handed back by "It's in place".
    public var placedPose: PlanPose? { placement?.pose }

    /// Whether the turn arc is drawn: in position with a turn left.
    public var showsTurn: Bool { phase == .turning }

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
            speakerMark = nil
            referenceMark = nil
            alignment = nil
            markedStart = nil
            speaker = nil
            floorHeight = nil
            isFollowing = false
            return []
        case .confirm:
            guard canConfirm, let current = speakerInModel else { return [] }
            let pose = PlanPose(position: current.position, facing: suggestion.to.facing)
            let placement = ARPlacement(pose: pose, distanceFromTarget: pose.position.distance(to: suggestion.to.position))
            phase = .placed(placement)
            isFollowing = false
            return [.placed(placement)]
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
        guard canMark, let reticle else { return [] }
        if phase == .markingSpeaker {
            speakerMark = reticle.point
            floorHeight = reticle.height
            phase = reference == nil ? .cannotAlign(.nothingElseToMark) : .markingReference
            return []
        }
        guard let reference, let speakerMark else { return [] }
        referenceMark = reticle.point
        let model = [ARGuidanceGeometry.frontEdgeCentre(of: suggestion.from, size: size), reference.modelPoint]
        let fitted = WorldAlignment.fit(model: model, world: [speakerMark, reticle.point])
        guard let fit = fitted, fit.isConsistent else {
            phase = .cannotAlign(.marksDisagree(residual: fitted?.residual ?? .infinity))
            return []
        }
        alignment = fit
        let facing = fit.apply(heading: suggestion.from.facing)
        let centre = ARGuidanceGeometry.centre(behindFrontEdge: speakerMark, facing: facing, size: size)
        markedStart = PlanPose(position: centre, facing: facing)
        speaker = markedStart
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
