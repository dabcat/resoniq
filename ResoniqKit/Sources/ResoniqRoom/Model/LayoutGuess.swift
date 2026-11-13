import Foundation

/// The first guess at the seat and a stereo pair after a scan. RoomPlan does not recognise loudspeakers, so
/// everything placed here has `isConfirmed == false` and the Confirm layout screen exists to correct it.
///
/// The rules, in order:
/// 1. **Seat.** On the largest sofa (the centre of its footprint). Without a sofa, at the centre of the bounding
///    rectangle, the middle of the room's centre third; in an L-shaped room where that falls outside, the nearest
///    allowed point.
/// 2. **Which way the seat faces.** Toward a television if there is one. Else along the sofa's front or back,
///    whichever has more room ahead (RoomPlan's front of a sofa is not trusted). Else along the room's longer side,
///    toward −x or −z when both ways are equal.
/// 3. **The pair.** On a line across that direction, `defaultWallDistance` from the wall ahead (or level with the
///    television when it stands farther out), symmetric about the seat's axis, spaced for a 60° triangle within `minimumSpacing` …
///    `maximumSpacing`, at least a television's width plus `televisionGap` each side apart, narrowed until both fit,
///    each pointed at the seat.
///
/// Items already in the room are kept: a seat is guessed only when there is none, the pair only when there is no
/// left or right speaker. The result is deterministic; guessed items get fixed ids (`seatID`, `leftID`, `rightID`).
public enum LayoutGuess {
    /// The distance from the wall ahead to the speakers' centres, metres. A first guess: common practice is half a
    /// metre to a metre, and a speaker 0.6 m out leaves its boundary dip near 140 Hz.
    public static let defaultWallDistance = 0.6
    /// The narrowest pair guessed, centre to centre, metres. A first guess.
    public static let minimumSpacing = 1.0
    /// The widest pair guessed, metres. A first guess.
    public static let maximumSpacing = 3.0
    /// The gap kept between a television's edge and a speaker's footprint, metres. A first guess.
    public static let televisionGap = 0.15
    /// How much a too-wide pair narrows on each try, metres.
    static let narrowingStep = 0.05

    public static let seatID = UUID(uuidString: "5EA7F00D-0000-4000-8000-000000000001")!
    public static let leftID = UUID(uuidString: "5EA7F00D-0000-4000-8000-000000000002")!
    public static let rightID = UUID(uuidString: "5EA7F00D-0000-4000-8000-000000000003")!

    public static func place(in room: RoomModel) -> RoomModel {
        guard let bounds = RoomGeometry.bounds(of: room) else { return room }
        var result = room
        let sofa = room.furniture.filter { $0.category == .sofa }.max { $0.footprint.area < $1.footprint.area }
        if result.seats.isEmpty {
            let wanted = sofa?.footprint.centre ?? bounds.centre
            let seat = Seat(id: seatID, position: wanted, isConfirmed: false)
            result = result.adding(seat).room
        }
        guard let seat = result.primarySeat?.position else { return result }
        guard result.speaker(role: .left) == nil, result.speaker(role: .right) == nil else { return result }

        let television = room.furniture.filter { $0.category == .television }
            .min { $0.footprint.centre.distance(to: seat) < $1.footprint.centre.distance(to: seat) }
        let facing = viewDirection(from: seat, sofa: sofa, television: television, bounds: bounds, in: room)

        let wall = RoomGeometry.wallAhead(of: seat, direction: facing, in: room)?.distance
            ?? max(bounds.width, bounds.length) / 2
        var ahead = max(0.5, wall - defaultWallDistance)
        var spacing = equilateralSpacing(ahead)
        if let television {
            // Level with the television, unless that is closer to the wall than the default distance.
            ahead = max(0.5, min(ahead, (television.footprint.centre - seat).dot(facing)))
            spacing = max(equilateralSpacing(ahead), television.footprint.width + 2 * televisionGap
                + PlacedSpeaker.defaultSize.width)
        }
        spacing = min(max(spacing, minimumSpacing), maximumSpacing)

        let centre = seat + facing * ahead
        let right = facing.rightHand
        while true {
            let leftPoint = centre - right * (spacing / 2), rightPoint = centre + right * (spacing / 2)
            let left = PlacedSpeaker(
                id: leftID, role: .left, position: leftPoint, facing: (seat - leftPoint).angle, isConfirmed: false)
            let rightSpeaker = PlacedSpeaker(
                id: rightID, role: .right, position: rightPoint, facing: (seat - rightPoint).angle,
                isConfirmed: false)
            var trial = result
            trial.speakers.append(left)
            let leftFits = PlacementRules.allows(speakerFootprint: left.footprint, ignoring: left.id, in: trial)
            trial.speakers.append(rightSpeaker)
            let rightFits = PlacementRules.allows(
                speakerFootprint: rightSpeaker.footprint, ignoring: rightSpeaker.id, in: trial)
            if leftFits && rightFits { return trial }
            if spacing - narrowingStep < minimumSpacing {
                // No symmetric pair fits: place each at the nearest allowed point.
                return result.adding(left).room.adding(rightSpeaker).room
            }
            spacing -= narrowingStep
        }
    }

    /// The side of an equilateral triangle whose apex is `distance` from its base: 2d/√3.
    static func equilateralSpacing(_ distance: Double) -> Double { 2 * distance / 3.0.squareRoot() }

    static func viewDirection(from seat: PlanPoint, sofa: Furniture?, television: Furniture?, bounds: PlanRect,
                              in room: RoomModel) -> PlanPoint {
        if let television {
            let toTV = television.footprint.centre - seat
            if toTV.length > 1e-6 { return toTV.normalized }
        }
        let options: [PlanPoint]
        if let sofa {
            let front = PlanPoint(angle: sofa.footprint.heading)
            options = [front, -front]
        } else if bounds.length >= bounds.width {
            options = [PlanPoint(x: 0, z: -1), PlanPoint(x: 0, z: 1)]
        } else {
            options = [PlanPoint(x: -1, z: 0), PlanPoint(x: 1, z: 0)]
        }
        func space(ahead direction: PlanPoint) -> Double {
            RoomGeometry.wallAhead(of: seat, direction: direction, in: room)?.distance ?? 0
        }
        return space(ahead: options[1]) > space(ahead: options[0]) + 1e-6 ? options[1] : options[0]
    }
}
