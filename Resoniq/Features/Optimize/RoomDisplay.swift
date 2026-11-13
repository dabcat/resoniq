import CoreGraphics
import Foundation
import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqRoom
import ResoniqStore
import SwiftUI

// The one place that maps Kit values onto the Optimize screens' component inputs. Every number and sentence comes
// from the Kit; the only numbers written here are the scales that turn a measured value into something drawn,
// named in `RoomDisplay.Scale`.

/// Mapping only. Nothing here decides where a speaker goes or what a measurement means.
///
/// **Axis convention.** The Kit's plan is the x–z plane in metres, seen from above with y up: +x to the right and
/// +z toward the bottom of the page (that is not a mirror: right-handed x right, y toward the viewer, z down).
/// `RoomPlanContent` is x right and y down, also in metres, so a plan point `(x, z)` is the component's `(x, y)`.
///
/// **Angles.** A Kit plan angle is radians, `atan2(z, x)`: 0 points along +x and π/2 along +z, which on screen is
/// down, so the angle grows clockwise as seen on screen. The component's angle is degrees clockwise with 0 pointing
/// up (−z). A plan angle θ therefore becomes `degrees(θ) + 90`: +x (θ = 0) is 90 (right), +z (θ = π/2) is 180
/// (down), −z (θ = −π/2) is 0 (up).
nonisolated enum RoomDisplay {
    nonisolated enum Scale {
        /// The measured spots sit this far either side of the seat, metres, along x: the Kit's one spacing, the
        /// same the instruction to move the phone states.
        static let spotOffset = SeatSpot.spacing
        /// The hatched ring around the seat that carries the problem's label, metres. A marker for where the
        /// problem was measured (at the seat), not an extent: the Kit locates no problem on the plan.
        static let problemRadius = 0.8
        /// Decibels shown above and below the middle in the before-and-after curve.
        static let curveDecibelsEachWay = 12.0
        /// How far from an existing seat a second seat is offered when the room's centre is taken, metres.
        static let secondSeatOffset = 0.8
        /// The seat is this close to the centre when it counts as "taken", metres.
        static let seatTaken = 0.5
    }

    // MARK: Plane and angles

    static func point(_ point: PlanPoint) -> CGPoint { CGPoint(x: point.x, y: point.z) }

    static func planPoint(_ point: CGPoint) -> PlanPoint { PlanPoint(x: Double(point.x), z: Double(point.y)) }

    /// A plan angle in radians as the component's degrees (see the type's note), −180…180.
    static func screenDegrees(planAngle radians: Double) -> Double {
        wrap(PlanAngle.degrees(radians) + 90)
    }

    /// The component's degrees as a plan angle in radians.
    static func planAngle(screenDegrees degrees: Double) -> Double {
        PlanAngle.radians(degrees - 90)
    }

    private static func wrap(_ degrees: Double) -> Double {
        var value = (degrees + 180).truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value - 180
    }

    // MARK: Room to plan

    /// The room as the plan draws it. `measuredAtSeat` adds the three spots at the primary seat; `problem` hatches the
    /// ring at the seat with its label; `suggestion` adds the dashed outline.
    static func content(
        of room: RoomModel,
        measuredAtSeat: Bool = false,
        problem: AcousticProblem? = nil,
        suggestion: PlacementSuggestion? = nil
    ) -> RoomPlanContent {
        var content = RoomPlanContent()
        for wall in room.walls {
            content.walls.append(.init(point(wall.start), point(wall.end)))
            for opening in wall.openings {
                let direction = wall.direction
                let first = wall.start + direction * (opening.offset - opening.width / 2)
                let second = wall.start + direction * (opening.offset + opening.width / 2)
                let segment = RoomPlanContent.Segment(point(first), point(second))
                switch opening.kind {
                case .window: content.windows.append(segment)
                // The model keeps no swing direction, so every door swings the same way: the arc is a cue, not data.
                case .door: content.doors.append(.init(leaf: segment, swing: .clockwise))
                }
            }
        }
        content.furniture = room.furniture.map { item in
            RoomPlanContent.Furniture(
                id: item.id.uuidString, centre: point(item.footprint.centre),
                size: CGSize(width: item.footprint.width, height: item.footprint.depth),
                angle: screenDegrees(planAngle: item.footprint.heading))
        }
        content.speakers = room.speakers.map { speaker in
            RoomPlanContent.Speaker(
                id: speaker.id.uuidString, position: point(speaker.position),
                facing: screenDegrees(planAngle: speaker.facing), label: RoomText.shortName(speaker.role),
                size: CGSize(width: speaker.size.width, height: speaker.size.depth),
                kind: speaker.role == .subwoofer ? .subwoofer : .speaker)
        }
        let primary = room.primarySeat?.id
        var number = 1
        content.seats = room.seats.map { seat in
            if seat.id == primary { return .init(id: seat.id.uuidString, position: point(seat.position), label: RoomText.seatName) }
            number += 1
            return .init(id: seat.id.uuidString, position: point(seat.position), label: "Seat \(number)")
        }
        guard let seat = room.primarySeat?.position else { return content }
        if measuredAtSeat {
            content.measuredSpots = [-Scale.spotOffset, 0, Scale.spotOffset].map {
                point(PlanPoint(x: seat.x + $0, z: seat.z))
            }
        }
        if let problem {
            let radius = CGFloat(Scale.problemRadius)
            content.problemAreas = [
                .init(
                    id: "problem", shape: .ellipse(centre: point(seat), radii: CGSize(width: radius, height: radius)),
                    label: RoomText.problemLabel(problem))
            ]
        }
        if let suggestion { content.suggestions = [self.suggestion(suggestion)] }
        return content
    }

    /// A suggested move as the plan draws it: the outline at the target, its distance and, when there is a turn, the
    /// turn.
    static func suggestion(_ suggestion: PlacementSuggestion) -> RoomPlanContent.Suggestion {
        .init(
            speakerID: suggestion.speakerID.uuidString, target: point(suggestion.to.position),
            targetFacing: suggestion.turn == nil ? nil : screenDegrees(planAngle: suggestion.to.facing),
            distanceLabel: suggestion.slides.isEmpty ? nil : RoomText.move(suggestion.distance),
            turnLabel: suggestion.turn.map { RoomText.turnLabel($0.angle) })
    }

    // MARK: Words for the plan

    /// What the plan shows, in one sentence for VoiceOver: the layout, then what was measured, then what is suggested.
    static func summary(
        of room: RoomModel,
        measuredAtSeat: Bool = false,
        problem: AcousticProblem? = nil,
        suggestion: PlacementSuggestion? = nil
    ) -> String {
        var parts = [layoutSummary(of: room)]
        if measuredAtSeat { parts.append(OptimizeText.measuredAtSeat) }
        if let problem { parts.append(OptimizeText.problemArea(RoomText.problemLabel(problem))) }
        if let suggestion { parts.append("\(RoomText.legendSuggested): \(suggestion.text.headline)") }
        return parts.joined(separator: " ")
    }

    /// "Plan of the room from above, 4.20 × 5.60 m, with the left speaker, the right speaker and your seat."
    static func layoutSummary(of room: RoomModel) -> String {
        var things = room.speakers.map { RoomText.title($0.role).lowercased() }
        switch room.seats.count {
        case 0: break
        case 1: things.append("your seat")
        default: things.append("\(room.seats.count) seats")
        }
        let size = RoomGeometry.dimensions(of: room).map { ", \(RoomText.dimensions($0))" } ?? ""
        guard !things.isEmpty else { return "Plan of the room from above\(size), with nothing placed in it yet." }
        return "Plan of the room from above\(size), with \(ListFormatter.localizedString(byJoining: things))."
    }

    /// "Living room · 4.20 × 5.60 m" (the Kit's text); just the name when the room has no outline yet.
    static func title(of room: RoomModel, name: String) -> String {
        guard let size = RoomGeometry.dimensions(of: room) else { return name }
        return RoomText.roomTitle(name: name, dimensions: size)
    }

    // MARK: Problems

    /// The seat report's bass extremes as the advisor's problems.
    static func problems(from report: SeatReport) -> [AcousticProblem] {
        report.placementTargets.map {
            AcousticProblem(frequency: Double($0.frequency), deviation: Double(abs($0.deviation)), kind: $0.kind == .peak ? .peak : .dip)
        }
    }

    /// The problem to hatch on the plan: the one the suggestion is for, else the largest.
    static func problemToShow(_ problems: [AcousticProblem], suggestion: PlacementSuggestion?) -> AcousticProblem? {
        suggestion?.problem ?? problems.max { $0.deviation < $1.deviation }
    }

    // MARK: Progress

    struct Tracker: Equatable {
        var steps: [String]
        var current: Int
    }

    /// The tracker's steps. The design files disagree on their names: V3Optimize says "Scanned, Measured, Move,
    /// Verify" while the flow is under way and V3OVerify says "Scanned, Measured, Moved, Verified" when it is done.
    /// One definition: a step is named in the past tense once it is done and as an action until then.
    static func tracker(_ progress: OptimizeProgress) -> Tracker {
        let done = [progress.scanned, progress.measured, progress.moved, progress.verified]
        let steps = [
            OptimizeText.stepScanned, OptimizeText.stepMeasured,
            progress.moved ? OptimizeText.stepMoved : OptimizeText.stepMove,
            progress.verified ? OptimizeText.stepVerified : OptimizeText.stepVerify,
        ]
        return Tracker(steps: steps, current: done.firstIndex(of: false) ?? steps.count)
    }

    // MARK: Layout editing

    /// The layout after an item was dragged: the Kit's answer, with the item confirmed because a person placed it.
    /// The position to draw is where the Kit put the item.
    static func move(_ id: String, to proposed: CGPoint, in room: RoomModel) -> (room: RoomModel, position: CGPoint)? {
        guard let uuid = UUID(uuidString: id), proposed.x.isFinite, proposed.y.isFinite else { return nil }
        var edited = room.moving(uuid, to: planPoint(proposed)).room
        confirm(uuid, in: &edited)
        guard let at = edited.speaker(uuid)?.position ?? edited.seat(uuid)?.position else { return nil }
        return (edited, point(at))
    }

    /// The layout after a speaker was turned (the Kit may also nudge it off a wall), and the facing to draw.
    static func turn(_ id: String, toScreenDegrees degrees: Double, in room: RoomModel) -> (room: RoomModel, degrees: Double)? {
        guard let uuid = UUID(uuidString: id), degrees.isFinite else { return nil }
        var edited = room.rotating(uuid, to: planAngle(screenDegrees: degrees)).room
        confirm(uuid, in: &edited)
        guard let facing = edited.speaker(uuid)?.facing else { return nil }
        return (edited, screenDegrees(planAngle: facing))
    }

    /// Everything on the plan was looked at and accepted: "Looks right".
    static func confirmed(_ room: RoomModel) -> RoomModel {
        var result = room
        for index in result.speakers.indices { result.speakers[index].isConfirmed = true }
        for index in result.seats.indices { result.seats[index].isConfirmed = true }
        return result
    }

    private static func confirm(_ id: UUID, in room: inout RoomModel) {
        if let index = room.speakers.firstIndex(where: { $0.id == id }) { room.speakers[index].isConfirmed = true }
        if let index = room.seats.firstIndex(where: { $0.id == id }) { room.seats[index].isConfirmed = true }
    }

    /// A subwoofer added by the Kit's `adding`, which moves it to the nearest allowed spot. The Kit offers no default
    /// position, so it is asked for midway between the pair, or at the room's centre without one, facing the seat.
    static func addingSubwoofer(to room: RoomModel) -> (room: RoomModel, id: String)? {
        guard let bounds = RoomGeometry.bounds(of: room) else { return nil }
        let pair = [room.speaker(role: .left), room.speaker(role: .right)].compactMap { $0?.position }
        let wanted = pair.count == 2 ? (pair[0] + pair[1]) * 0.5 : bounds.centre
        let facing = room.primarySeat.map { ($0.position - wanted).angle } ?? 0
        let sub = PlacedSpeaker(role: .subwoofer, position: wanted, facing: facing, isConfirmed: true)
        let edited = room.adding(sub).room
        return edited.speaker(sub.id) == nil ? nil : (edited, sub.id.uuidString)
    }

    /// A seat added by the Kit's `adding`, asked for at the room's centre (or a little to the side when a seat is
    /// already there). The Kit offers no default position.
    static func addingSeat(to room: RoomModel) -> (room: RoomModel, id: String)? {
        guard let bounds = RoomGeometry.bounds(of: room) else { return nil }
        var wanted = bounds.centre
        if room.seats.contains(where: { $0.position.distance(to: wanted) < Scale.seatTaken }) {
            wanted.x += Scale.secondSeatOffset
        }
        let seat = Seat(position: wanted, isConfirmed: true)
        let edited = room.adding(seat).room
        return edited.seat(seat.id) == nil ? nil : (edited, seat.id.uuidString)
    }

    /// The distance from the selected speaker (its edge) or seat to the nearest wall, with the point on the wall the
    /// dimension line runs to.
    static func wallDistance(of id: String?, in room: RoomModel) -> RoomPlanWallDistance? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        if let speaker = room.speaker(uuid) {
            guard let gap = RoomGeometry.distanceToNearestWall(footprint: speaker.footprint, in: room),
                  let wall = RoomGeometry.nearestWall(to: speaker.position, in: room)
            else { return nil }
            return RoomPlanWallDistance(label: RoomText.metres(gap), wallPoint: point(wall.closestPoint))
        }
        if let seat = room.seat(uuid), let wall = RoomGeometry.nearestWall(to: seat.position, in: room) {
            return RoomPlanWallDistance(label: RoomText.metres(wall.distance), wallPoint: point(wall.closestPoint))
        }
        return nil
    }

    // MARK: Comparison

    struct ComparisonLine: Identifiable, Equatable {
        enum Content: Equatable {
            case values(before: String, after: String, improved: Bool)
            case plain(String)
        }

        var id: Int
        var label: String
        var content: Content
    }

    /// The report's rows for `BeforeAfterRow`. A row that got worse says so in its label, because the row has only
    /// an improved style.
    static func lines(of comparison: ComparisonReport) -> [ComparisonLine] {
        comparison.rows.enumerated().map { index, row in
            let label = row.change == .worse ? "\(row.label)\(OptimizeText.gotWorse)" : row.label
            if let before = row.before, let after = row.after {
                return ComparisonLine(id: index, label: label, content: .values(before: before, after: after, improved: row.change == .improved))
            }
            return ComparisonLine(id: index, label: label, content: .plain(row.status ?? ""))
        }
    }

    /// The seat curve on the chart's scale; empty when the report has none.
    static func levels(of report: SeatReport) -> [Double] {
        (report.curve ?? []).map(Double.init)
    }

    /// What the before-and-after chart says, for VoiceOver: each row in words.
    static func curveSummary(of comparison: ComparisonReport) -> String {
        let rows = lines(of: comparison).map { line -> String in
            switch line.content {
            case .values(let before, let after, _): "\(line.label): \(before) before, \(after) after."
            case .plain(let text): "\(line.label): \(text)."
            }
        }
        return ([OptimizeText.curveIntro] + rows).joined(separator: " ")
    }
}

// MARK: - Optimize home

/// What the home screen has to work with. Plain values read from the store (or a fixture).
struct OptimizeHomeInput {
    var layout: RoomModel?
    /// The latest seat measurement's report.
    var seat: SeatReport?
    var progress: OptimizeProgress
    /// The current optimisation's comparison, once it has one.
    var comparison: ComparisonReport?
    /// Suggestions the person declined for this measurement; the home shows the next one the advisor has.
    var declined: [PlacementSuggestion] = []
    /// The stored layout could not be read: the home shows "no room yet" with a line saying so.
    var layoutUnreadable = false
}

extension OptimizeHomeState {
    /// The state to show, and the suggestion behind it when there is one (the caller routes it to AR or to the
    /// optimisation). Which suggestion is shown is the Kit's: the advisor's first that was not declined.
    static func make(_ input: OptimizeHomeInput) -> (state: OptimizeHomeState, suggestion: PlacementSuggestion?) {
        let tracker = RoomDisplay.tracker(input.progress)
        guard let layout = input.layout else { return (.noRoom(tracker: tracker), nil) }

        func plan(
            measured: Bool, problem: AcousticProblem? = nil, suggestion: PlacementSuggestion? = nil
        ) -> OptimizePlan {
            OptimizePlan(
                content: RoomDisplay.content(of: layout, measuredAtSeat: measured, problem: problem, suggestion: suggestion),
                summary: RoomDisplay.summary(of: layout, measuredAtSeat: measured, problem: problem, suggestion: suggestion))
        }

        if input.progress.verified, let comparison = input.comparison {
            return (.verified(tracker: tracker, headline: comparison.verdict, plan: plan(measured: true)), nil)
        }
        if input.progress.moved {
            return (.moved(tracker: tracker, headline: OptimizeText.movedHeadline, plan: plan(measured: true)), nil)
        }
        guard let report = input.seat else {
            return (.notMeasured(tracker: tracker, headline: OptimizeText.notMeasuredHeadline, plan: plan(measured: false)), nil)
        }
        guard report.isConclusive else {
            // The Kit's own sentence says what was wrong with the measurement.
            return (.nothingToSuggest(tracker: tracker, headline: report.verdict, notes: [], plan: plan(measured: false)), nil)
        }

        let problems = RoomDisplay.problems(from: report)
        let advice = PlacementAdvisor.advice(room: layout, problems: problems)
        if let suggestion = OptimizeRules.firstOpen(advice.suggestions, declined: input.declined) {
            let shown = RoomDisplay.problemToShow(problems, suggestion: suggestion)
            return (
                .suggestion(
                    tracker: tracker, headline: suggestion.text.headline,
                    basis: suggestion.basis == .roomShape ? RoomText.roomShapeBasis : nil,
                    plan: plan(measured: true, problem: suggestion.basis == .roomShape ? nil : shown, suggestion: suggestion)),
                suggestion
            )
        }
        // The Kit explained no problem, or there is none: its own sentences say which.
        let headline = problems.isEmpty ? report.verdict : (advice.unexplainedText.first ?? report.verdict)
        let notes = problems.isEmpty ? [] : Array(advice.unexplainedText.dropFirst())
        let shown = RoomDisplay.problemToShow(problems, suggestion: nil)
        return (.nothingToSuggest(tracker: tracker, headline: headline, notes: notes, plan: plan(measured: true, problem: shown)), nil)
    }
}

#if DEBUG
/// If the conversion mirrored the room, this would show it: the window is in the wall at the top (z = −2.8 m, behind
/// the speakers), the door is in the left wall near the bottom (the front, z > 0), the sofa is at the bottom facing
/// up, and both speakers face down toward the seat between them and the sofa.
#Preview("Axis check") {
    let room = OptimizeFixtures.room
    RoomPlanView(
        RoomDisplay.content(of: room, measuredAtSeat: true, suggestion: nil),
        accessibilityLabel: RoomDisplay.layoutSummary(of: room)
    )
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
#endif
