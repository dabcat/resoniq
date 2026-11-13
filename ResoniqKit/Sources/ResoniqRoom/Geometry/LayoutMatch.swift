import Foundation

/// Whether two layouts put the speakers and seats in the same places: the one definition of "the same layout" that
/// the store uses to tie a measurement to the room it was made in, and an optimisation to the layout it moved from
/// or to.
///
/// Two layouts match when they hold the same speakers and the same seats (by id) and each one's pose is within
/// `positionTolerance` and, for a speaker, `facingTolerance` of the other's. Walls, furniture, sizes and whether an
/// item was confirmed are not compared: a measurement depends on where the speakers and the listener are, and a rescan
/// gives new ids, so it never matches the layout before it.
public enum LayoutMatch {
    /// Positions closer than this are the same place, metres. A first guess: below what a person can place a speaker
    /// to by hand or mark in AR (`MoveGuidance.positionTolerance` is 3 cm), above the rounding of a stored layout.
    public static let positionTolerance = 0.02
    /// Facings closer than this are the same, radians (2°). A first guess, below `MoveGuidance.angleTolerance`.
    public static let facingTolerance = 2 * Double.pi / 180

    public static func matches(_ a: RoomModel, _ b: RoomModel) -> Bool {
        guard a.speakers.count == b.speakers.count, a.seats.count == b.seats.count else { return false }
        for speaker in a.speakers {
            guard let other = b.speaker(speaker.id),
                  speaker.position.distance(to: other.position) <= positionTolerance,
                  abs(PlanAngle.difference(from: speaker.facing, to: other.facing)) <= facingTolerance
            else { return false }
        }
        for seat in a.seats {
            guard let other = b.seat(seat.id), seat.position.distance(to: other.position) <= positionTolerance else {
                return false
            }
        }
        return true
    }
}
