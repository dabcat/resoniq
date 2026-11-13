import Foundation

/// Where a speaker should go, from measured problems and the room model.
///
/// Method, for each measured problem:
/// 1. **Explain.** Find the model terms near its frequency: a speaker's boundary dip (`BoundaryInterference`)
///    within `boundaryTolerance` of a measured dip, and an axial mode (`RoomModes`) within `modeTolerance` where the
///    seat and the speakers sit as the problem needs (for a peak, the seat and a speaker both near an antinode; for
///    a dip, the seat or a speaker near a null). No term within tolerance: the problem is unexplained and nothing
///    is invented for it.
/// 2. **Search.** For each main speaker, slide it along each of the four `MoveDirection`s in `gridStep` steps up to
///    `PlacementLimits.maximumMove`, keeping `PlacementRules` and inside the room's closed outline (a scan with walls
///    missing gets no new spot, since nothing in it can be shown to be inside), and turn it toward the seat. Score each spot: for each
///    explained problem, the best-matching term for that speaker either moves its dip away from the problem
///    (credit grows to `targetShift` and stops) or changes its coupling to the mode the right way, weighted by how
///    far outside the band the problem is; minus `movePenaltyPerMetre` for the distance, minus
///    `asymmetryPenalty` for making the listening triangle less even, minus `stackingPenalty` for landing two of the
///    speaker's own dips on one note.
/// 3. **Rank.** Keep the best spot per speaker and direction, best first, so "Can't move it" has an alternative.
///
/// A subwoofer is searched separately along the walls and scored only by its coupling to the problem modes. With no
/// measured problems the same search scores only the listening triangle (`SuggestionBasis.roomShape`). Every
/// constant here is a first guess to be tuned against before-and-after measurements in real rooms.
public enum PlacementAdvisor {
    /// A boundary dip within this many octaves of a measured dip explains it. A first guess: a boundary dip is broad.
    public static let boundaryTolerance = 1.0 / 6
    /// A mode within this many octaves of a problem explains it. A first guess: about ±6 %, the error of a scanned
    /// dimension and the speed of sound together.
    public static let modeTolerance = 1.0 / 12
    /// Problems above this are not explained, hertz: the boundary and modal models only hold in the bass.
    public static let maximumFrequency = 300.0
    /// For a peak, the seat and a speaker must both have at least this mode pressure magnitude. A first guess.
    public static let antinodeCoupling = 0.5
    /// For a dip, the seat or a speaker must have at most this mode pressure magnitude. A first guess.
    public static let nullCoupling = 0.35
    /// Moving a dip this many octaves away from the problem earns full credit. A first guess: a third of an octave
    /// clears a measurement's smoothing.
    public static let targetShift = 1.0 / 3
    /// A coupling change of this much earns full credit. A first guess.
    public static let couplingSwing = 0.5
    /// A problem this many decibels outside the band has weight 1; weight grows with the deviation up to twice that.
    public static let referenceDeviation = 10.0
    /// The slide grid, metres. Moves come in 5 cm steps, which a person can measure.
    public static let gridStep = 0.05
    /// Score lost per metre of a main speaker's slide. A first guess: prefer the smaller move.
    public static let movePenaltyPerMetre = 0.5
    /// Score lost per metre of a subwoofer's move. A first guess.
    public static let subwooferMovePenaltyPerMetre = 0.1
    /// Score lost per unit of `ListeningGeometry.unevenness` added. A first guess; 0.3 m of uneven distance costs 0.3.
    public static let asymmetryPenalty = 0.05
    /// Score lost when a move lands two of a speaker's boundary dips within `boundaryTolerance` of each other.
    public static let stackingPenalty = 0.3
    /// Score per unit of `ListeningGeometry.unevenness` removed, for suggestions from the room's shape. A first guess.
    public static let geometryCredit = 0.1
    /// Turns smaller than this are left out, radians (2°).
    public static let minimumTurn = 2 * Double.pi / 180
    /// The spacing of subwoofer candidates along each wall, metres.
    public static let subwooferStep = 0.25

    /// The suggestions only; see `advice(room:problems:limits:)`.
    public static func suggestions(room: RoomModel, problems: [AcousticProblem], limits: PlacementLimits = .standard)
        -> [PlacementSuggestion]
    {
        advice(room: room, problems: problems, limits: limits).suggestions
    }

    /// The suggestions and how each problem was explained.
    public static func advice(room: RoomModel, problems: [AcousticProblem], limits: PlacementLimits = .standard)
        -> PlacementAdvice
    {
        guard let seat = room.primarySeat, let bounds = RoomGeometry.bounds(of: room) else {
            return PlacementAdvice(
                suggestions: [], explanations: problems.map { ProblemExplanation(problem: $0, terms: []) })
        }
        let context = Context(room: room, seat: seat.position, bounds: bounds, limits: limits)
        let explanations = problems.map { context.explain($0) }
        let explained = explanations.filter(\.isExplained)

        var main: [PlacementSuggestion]
        var subwoofer: [PlacementSuggestion] = []
        if problems.isEmpty {
            main = context.geometrySuggestions()
        } else {
            main = context.measuredSuggestions(explained)
            subwoofer = context.subwooferSuggestions(explained)
        }
        main = Array(main.prefix(limits.maximumSuggestions))
        subwoofer = Array(subwoofer.prefix(limits.maximumSubwooferSuggestions))
        // Best first; equal scores keep their order (speakers as listed, then forward, back, left, right).
        let ranked = (main + subwoofer).enumerated().sorted { a, b in
            if abs(a.element.score - b.element.score) > 1e-9 { return a.element.score > b.element.score }
            return a.offset < b.offset
        }.map(\.element)
        return PlacementAdvice(suggestions: ranked, explanations: explanations)
    }

    /// The listener's frame at a seat: the unit vector of each `MoveDirection`. The listener faces the main
    /// speakers' midpoint (or the subwoofer, or the room's centre).
    public static func frame(in room: RoomModel, seat: PlanPoint) -> [MoveDirection: PlanPoint] {
        let mains = room.speakers.filter { $0.role != .subwoofer }
        let look: PlanPoint
        if !mains.isEmpty {
            look = mains.map(\.position).reduce(.zero, +) * (1 / Double(mains.count)) - seat
        } else if let any = room.speakers.first {
            look = any.position - seat
        } else {
            look = (RoomGeometry.bounds(of: room)?.centre ?? seat) - seat
        }
        let facing = look.length > 1e-6 ? look.normalized : PlanPoint(x: 0, z: -1)
        return [.forward: -facing, .back: facing, .left: -facing.rightHand, .right: facing.rightHand]
    }
}

// MARK: - Search

private struct Candidate {
    var speaker: PlacedSpeaker
    var slides: [Slide]
    var position: PlanPoint
    var facing: Double
    var score: Double
    var goal: SuggestionGoal
    var reason: SuggestionReason
    var basis: SuggestionBasis
}

private struct Context {
    let room: RoomModel
    let seat: PlanPoint
    let bounds: PlanRect
    let limits: PlacementLimits
    let height: Double
    let modes: [RoomMode]
    let frame: [MoveDirection: PlanPoint]
    let geometry: ListeningGeometry?

    init(room: RoomModel, seat: PlanPoint, bounds: PlanRect, limits: PlacementLimits) {
        self.room = room
        self.seat = seat
        self.bounds = bounds
        self.limits = limits
        height = RoomGeometry.height(of: room)
        modes = RoomModes.axial(for: room)
        frame = PlacementAdvisor.frame(in: room, seat: seat)
        geometry = ListeningGeometry(room: room).map { ListeningGeometry(seat: seat, left: $0.left, right: $0.right) }
    }

    var mains: [PlacedSpeaker] { room.speakers.filter { $0.role != .subwoofer } }

    // MARK: Explain

    func coupling(_ mode: RoomMode, at point: PlanPoint, height: Double) -> Double {
        abs(mode.pressure(atCoordinate: RoomModes.coordinate(of: point, height: height, along: mode.dimension, in: bounds)))
    }

    func octaves(_ a: Double, _ b: Double) -> Double { abs(log2(a / b)) }

    func explain(_ problem: AcousticProblem) -> ProblemExplanation {
        guard problem.frequency.isFinite, problem.frequency > 0, problem.frequency <= PlacementAdvisor.maximumFrequency
        else { return ProblemExplanation(problem: problem, terms: []) }
        var terms: [ModelTerm] = []
        if problem.kind == .dip {
            for speaker in mains {
                for dip in BoundaryInterference.dipFrequencies(for: speaker, in: room)
                where octaves(dip.frequency, problem.frequency) <= PlacementAdvisor.boundaryTolerance {
                    terms.append(.boundary(speakerID: speaker.id, dip: dip))
                }
            }
        }
        let seatHeight = PlacedSpeaker.defaultDriverHeight
        for mode in modes where octaves(mode.frequency, problem.frequency) <= PlacementAdvisor.modeTolerance {
            let seatCoupling = coupling(mode, at: seat, height: seatHeight)
            let couplings = room.speakers.map {
                SpeakerCoupling(speakerID: $0.id, coupling: coupling(mode, at: $0.position, height: $0.driverHeight))
            }
            guard let strongest = couplings.map(\.coupling).max(), let weakest = couplings.map(\.coupling).min() else {
                continue
            }
            let fits = switch problem.kind {
            case .peak: seatCoupling >= PlacementAdvisor.antinodeCoupling && strongest >= PlacementAdvisor.antinodeCoupling
            case .dip: seatCoupling <= PlacementAdvisor.nullCoupling || weakest <= PlacementAdvisor.nullCoupling
            }
            if fits { terms.append(.mode(mode, seatCoupling: seatCoupling, speakerCouplings: couplings)) }
        }
        // Closest first; a boundary term before a mode at the same distance, since it belongs to one speaker.
        let ranked = terms.enumerated().sorted { a, b in
            let da = octaves(a.element.frequency, problem.frequency), db = octaves(b.element.frequency, problem.frequency)
            if abs(da - db) > 1e-3 { return da < db }
            return a.offset < b.offset
        }.map(\.element)
        return ProblemExplanation(problem: problem, terms: ranked)
    }

    // MARK: Score

    func weight(_ problem: AcousticProblem) -> Double {
        min(problem.deviation, 2 * PlacementAdvisor.referenceDeviation) / PlacementAdvisor.referenceDeviation
    }

    /// The credit a new spot earns against one explained problem for one speaker, and the reason, or nil when no
    /// term of the problem is one this speaker's move can change.
    func benefit(of speaker: PlacedSpeaker, at position: PlanPoint, facing: Double, for explanation: ProblemExplanation,
                 newDips: [BoundaryDip]) -> (credit: Double, reason: SuggestionReason)? {
        let problem = explanation.problem
        for term in explanation.terms {
            switch term {
            case .boundary(let id, let dip) where id == speaker.id:
                guard let moved = newDips.first(where: { $0.surface == dip.surface }) else { continue }
                let shift = octaves(moved.frequency, problem.frequency) - octaves(dip.frequency, problem.frequency)
                let credit = max(-1, min(shift, PlacementAdvisor.targetShift) / PlacementAdvisor.targetShift)
                return (credit, .boundary(surface: dip.surface, from: dip.frequency, to: moved.frequency))
            case .mode(let mode, _, _) where mode.dimension != .height:
                let before = coupling(mode, at: speaker.position, height: speaker.driverHeight)
                let after = coupling(mode, at: position, height: speaker.driverHeight)
                let change = problem.kind == .peak ? before - after : after - before
                let credit = max(-1, min(1, change / PlacementAdvisor.couplingSwing))
                return (credit, .mode(mode, kind: problem.kind, couplingBefore: before, couplingAfter: after))
            default:
                continue
            }
        }
        return nil
    }

    func stacks(_ dips: [BoundaryDip]) -> Bool {
        for i in dips.indices {
            for j in dips.indices
            where j > i && octaves(dips[i].frequency, dips[j].frequency) <= PlacementAdvisor.boundaryTolerance {
                return true
            }
        }
        return false
    }

    func unevenness(moving speaker: PlacedSpeaker, to position: PlanPoint) -> Double? {
        guard let geometry else { return nil }
        var left = geometry.left, right = geometry.right
        if left.id == speaker.id { left.position = position }
        if right.id == speaker.id { right.position = position }
        return ListeningGeometry(seat: seat, left: left, right: right).unevenness
    }

    /// Whether every corner of a footprint is inside the room's closed outline (`RoomGeometry.isProvablyInside`). A
    /// room with walls missing has no closed outline, so nothing new is suggested in it: the advisor never proposes a
    /// spot it cannot show to be inside.
    func isShownInside(_ footprint: OrientedRect) -> Bool {
        footprint.corners.allSatisfy { RoomGeometry.isProvablyInside($0, in: room) }
    }

    /// Every allowed slide of a main speaker on the grid, turned toward the seat.
    func slides(of speaker: PlacedSpeaker) -> [(Slide, PlanPoint, Double)] {
        let count = Int((limits.maximumMove / PlacementAdvisor.gridStep) + 1e-9)
        guard count > 0 else { return [] }
        var result: [(Slide, PlanPoint, Double)] = []
        for direction in MoveDirection.allCases {
            guard let unit = frame[direction] else { continue }
            for step in 1...count {
                let distance = Double(step) * PlacementAdvisor.gridStep
                let position = speaker.position + unit * distance
                let facing = (seat - position).angle
                let footprint = OrientedRect(
                    centre: position, width: speaker.size.width, depth: speaker.size.depth, heading: facing)
                guard PlacementRules.allows(speakerFootprint: footprint, ignoring: speaker.id, in: room),
                      isShownInside(footprint)
                else { break }
                result.append((Slide(direction: direction, distance: distance), position, facing))
            }
        }
        return result
    }

    /// The best candidate per speaker and direction, best first.
    func bestPerDirection(_ candidates: [Candidate]) -> [Candidate] {
        var best: [String: Candidate] = [:]
        for candidate in candidates {
            let key = "\(candidate.speaker.id)-\(candidate.slides.first?.direction.rawValue ?? "turn")"
            if let current = best[key], current.score >= candidate.score { continue }
            best[key] = candidate
        }
        let order = Dictionary(uniqueKeysWithValues: room.speakers.enumerated().map { ($1.id, $0) })
        let directionOrder = Dictionary(uniqueKeysWithValues: MoveDirection.allCases.enumerated().map { ($1, $0) })
        return best.values.sorted { a, b in
            if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
            if order[a.speaker.id]! != order[b.speaker.id]! { return order[a.speaker.id]! < order[b.speaker.id]! }
            let da = a.slides.first.map { directionOrder[$0.direction]! } ?? -1
            let db = b.slides.first.map { directionOrder[$0.direction]! } ?? -1
            return da < db
        }
    }

    // MARK: Measured problems

    func measuredSuggestions(_ explained: [ProblemExplanation]) -> [PlacementSuggestion] {
        guard !explained.isEmpty else { return [] }
        var candidates: [Candidate] = []
        for speaker in mains {
            let unevenBefore = unevenness(moving: speaker, to: speaker.position)
            let stackedBefore = stacks(BoundaryInterference.dipFrequencies(for: speaker, in: room))
            for (slide, position, facing) in slides(of: speaker) {
                let newDips = BoundaryInterference.dipFrequencies(
                    position: position, facing: facing, driverHeight: speaker.driverHeight, in: room)
                var total = 0.0
                var best: (weighted: Double, problem: AcousticProblem, reason: SuggestionReason)?
                var helped: [AcousticProblem] = []
                for explanation in explained {
                    guard
                        let (credit, reason) = benefit(
                            of: speaker, at: position, facing: facing, for: explanation, newDips: newDips)
                    else { continue }
                    let weighted = credit * weight(explanation.problem)
                    total += weighted
                    if weighted > 0 { helped.append(explanation.problem) }
                    if weighted > (best?.weighted ?? 0) { best = (weighted, explanation.problem, reason) }
                }
                guard let best else { continue }
                var score = total - PlacementAdvisor.movePenaltyPerMetre * slide.distance
                if let before = unevenBefore, let after = unevenness(moving: speaker, to: position) {
                    score -= PlacementAdvisor.asymmetryPenalty * max(0, after - before)
                }
                if !stackedBefore && stacks(newDips) { score -= PlacementAdvisor.stackingPenalty }
                guard score > 0 else { continue }
                candidates.append(
                    Candidate(
                        speaker: speaker, slides: [slide], position: position, facing: facing, score: score,
                        goal: .problem(best.problem), reason: best.reason, basis: .measured(helped)))
            }
        }
        return bestPerDirection(candidates).map(suggestion)
    }

    // MARK: Room shape only

    func geometrySuggestions() -> [PlacementSuggestion] {
        var candidates: [Candidate] = []
        if let geometry {
            let issues = geometry.issues.filter {
                if case .notToedIn = $0 { return false }
                return true
            }
            if let first = issues.first {
                let before = geometry.unevenness
                for speaker in [geometry.left, geometry.right] {
                    for (slide, position, facing) in slides(of: speaker) {
                        guard let after = unevenness(moving: speaker, to: position) else { continue }
                        // The move ends with a turn toward the seat, so it also earns the toe-in credit.
                        let score = PlacementAdvisor.geometryCredit * (before - after) + toeInCredit(speaker)
                            - PlacementAdvisor.movePenaltyPerMetre * slide.distance
                        guard score > 0 else { continue }
                        let goal: SuggestionGoal
                        if case .closerTo = first { goal = .evenDistances } else { goal = .evenAngle }
                        candidates.append(
                            Candidate(
                                speaker: speaker, slides: [slide], position: position, facing: facing, score: score,
                                goal: goal, reason: .geometry(first), basis: .roomShape))
                    }
                }
            }
        }
        for speaker in mains where toeInCredit(speaker) > 0 {
            candidates.append(
                Candidate(
                    speaker: speaker, slides: [], position: speaker.position, facing: (seat - speaker.position).angle,
                    score: toeInCredit(speaker), goal: .toeIn, reason: .geometry(.notToedIn(speaker.role)),
                    basis: .roomShape))
        }
        return bestPerDirection(candidates).map(suggestion)
    }

    /// Credit for turning a speaker that points more than `ListeningGeometry.toeInTolerance` away from the seat.
    func toeInCredit(_ speaker: PlacedSpeaker) -> Double {
        let error = ListeningGeometry.toeInError(of: speaker, toward: seat)
        guard error > ListeningGeometry.toeInTolerance else { return 0 }
        return PlacementAdvisor.geometryCredit * error / ListeningGeometry.toeInTolerance
    }

    // MARK: Subwoofer

    func subwooferSuggestions(_ explained: [ProblemExplanation]) -> [PlacementSuggestion] {
        let modeProblems = explained.filter { $0.terms.contains { if case .mode = $0 { true } else { false } } }
        guard !modeProblems.isEmpty else { return [] }
        var result: [PlacementSuggestion] = []
        for sub in room.speakers where sub.role == .subwoofer {
            var candidates: [Candidate] = []
            for spot in wallSpots(for: sub) {
                let distance = spot.position.distance(to: sub.position)
                guard distance >= PlacementAdvisor.gridStep, distance <= limits.maximumSubwooferMove else { continue }
                var total = 0.0
                var best: (weighted: Double, problem: AcousticProblem, reason: SuggestionReason)?
                var helped: [AcousticProblem] = []
                for explanation in modeProblems {
                    guard
                        let (credit, reason) = benefit(
                            of: sub, at: spot.position, facing: spot.facing, for: explanation, newDips: [])
                    else { continue }
                    let weighted = credit * weight(explanation.problem)
                    total += weighted
                    if weighted > 0 { helped.append(explanation.problem) }
                    if weighted > (best?.weighted ?? 0) { best = (weighted, explanation.problem, reason) }
                }
                guard let best else { continue }
                let score = total - PlacementAdvisor.subwooferMovePenaltyPerMetre * distance
                guard score > 0 else { continue }
                candidates.append(
                    Candidate(
                        speaker: sub, slides: subwooferSlides(from: sub.position, to: spot.position),
                        position: spot.position, facing: sub.facing, score: score, goal: .problem(best.problem),
                        reason: best.reason, basis: .measured(helped)))
            }
            // Distinct spots: at least a metre apart.
            var chosen: [Candidate] = []
            for candidate in candidates.sorted(by: { $0.score > $1.score })
            where chosen.allSatisfy({ $0.position.distance(to: candidate.position) >= 1 }) {
                chosen.append(candidate)
            }
            result += chosen.map(suggestion)
        }
        return result
    }

    /// Spots along every wall where the subwoofer fits, facing into the room.
    func wallSpots(for sub: PlacedSpeaker) -> [(position: PlanPoint, facing: Double)] {
        let inset = PlacementRules.speakerWallClearance + sub.size.depth / 2 + 0.01
        var spots: [(PlanPoint, Double)] = []
        for wall in room.walls where wall.length > 0 {
            let count = Int(wall.length / PlacementAdvisor.subwooferStep)
            guard count >= 1 else { continue }
            for k in 0...count {
                let along = wall.start + wall.direction * (Double(k) * PlacementAdvisor.subwooferStep)
                for normal in [wall.direction.rightHand, -wall.direction.rightHand] {
                    let position = along + normal * inset
                    let footprint = OrientedRect(
                        centre: position, width: sub.size.width, depth: sub.size.depth, heading: normal.angle)
                    if PlacementRules.allows(speakerFootprint: footprint, ignoring: sub.id, in: room),
                       isShownInside(footprint) {
                        spots.append((position, sub.facing))
                    }
                }
            }
        }
        return spots
    }

    /// A subwoofer's move as at most two slides in the listener's frame: forward or back, then left or right.
    func subwooferSlides(from: PlanPoint, to: PlanPoint) -> [Slide] {
        let delta = to - from
        guard let forward = frame[.forward], let right = frame[.right] else { return [] }
        var slides: [Slide] = []
        let ahead = delta.dot(forward), side = delta.dot(right)
        if abs(ahead) >= PlacementAdvisor.gridStep / 2 {
            slides.append(Slide(direction: ahead > 0 ? .forward : .back, distance: abs(ahead)))
        }
        if abs(side) >= PlacementAdvisor.gridStep / 2 {
            slides.append(Slide(direction: side > 0 ? .right : .left, distance: abs(side)))
        }
        return slides
    }

    // MARK: Build

    func suggestion(_ candidate: Candidate) -> PlacementSuggestion {
        let speaker = candidate.speaker
        let turnAngle = PlanAngle.difference(from: speaker.facing, to: candidate.facing)
        let turn: Turn? = abs(turnAngle) >= PlacementAdvisor.minimumTurn && speaker.role != .subwoofer
            ? Turn(angle: turnAngle) : nil
        let steps = candidate.slides.map(SuggestionStep.slide) + (turn.map { [SuggestionStep.turn($0)] } ?? [])
        let total = candidate.slides.reduce(0) { $0 + $1.distance }
        let text = SuggestionText(
            headline: RoomText.headline(role: speaker.role, slides: candidate.slides, turn: turn, goal: candidate.goal),
            reason: RoomText.reason(candidate.reason, slides: candidate.slides, geometry: geometry),
            totalDistance: candidate.slides.isEmpty ? nil : RoomText.totalDistance(total),
            thenTurn: turn.map(RoomText.thenTurn),
            steps: steps.map(RoomText.stepInstruction),
            stepLabels: steps.indices.map { RoomText.stepLabel($0 + 1, of: steps.count) })
        return PlacementSuggestion(
            speakerID: speaker.id, role: speaker.role, from: speaker.pose,
            to: PlanPose(position: candidate.position, facing: turn == nil ? speaker.facing : candidate.facing),
            slides: candidate.slides, turn: turn, steps: steps, goal: candidate.goal, reason: candidate.reason,
            score: candidate.score, basis: candidate.basis, text: text)
    }
}
