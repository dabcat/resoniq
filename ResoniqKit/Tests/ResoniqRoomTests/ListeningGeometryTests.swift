import Foundation
import Testing
@testable import ResoniqRoom

@Suite struct ListeningGeometryTests {
    @Test func equilateralTriangleIsEven() throws {
        let geometry = try #require(ListeningGeometry(room: Fixtures.stereoRoom))
        #expect(isClose(geometry.leftDistance, 2, 1e-12) && isClose(geometry.rightDistance, 2, 1e-12))
        #expect(isClose(geometry.distanceDifference, 0, 1e-12))
        #expect(isClose(geometry.spacing, 2))
        #expect(isClose(geometry.subtendedAngle, .pi / 3, 1e-12))
        #expect(isClose(geometry.leftToeInError, 0, 1e-12) && isClose(geometry.rightToeInError, 0, 1e-12))
        #expect(geometry.isEven)
        #expect(RoomText.geometrySummary(geometry) == "The speakers and your seat make an even triangle.")
    }

    @Test func unevenTriangle() throws {
        // Seat 0.5 m right of centre, 1 m from the line of a pair 3 m apart, both speakers facing straight ahead.
        let seat = PlanPoint(x: 0.5, z: 0)
        let left = PlacedSpeaker(role: .left, position: PlanPoint(x: -1.5, z: -1), facing: .pi / 2, isConfirmed: true)
        let right = PlacedSpeaker(role: .right, position: PlanPoint(x: 1.5, z: -1), facing: .pi / 2, isConfirmed: true)
        let geometry = ListeningGeometry(seat: seat, left: left, right: right)
        let leftDistance = (4.0 + 1).squareRoot(), rightDistance = (1.0 + 1).squareRoot()
        #expect(isClose(geometry.leftDistance, leftDistance, 1e-12))
        #expect(isClose(geometry.distanceDifference, leftDistance - rightDistance, 1e-12))
        // atan(2/1) + atan(1/1) = 63.43° + 45° = 108.43°.
        #expect(isClose(geometry.subtendedAngle, atan(2.0) + .pi / 4, 1e-12))
        // Facing +z, the left speaker points atan(2) − … away: the seat is at angle atan2(1, 2) from it.
        #expect(isClose(geometry.leftToeInError, .pi / 2 - atan2(1.0, 2.0), 1e-12))
        #expect(geometry.issues == [.tooWide, .closerTo(.right), .notToedIn(.left), .notToedIn(.right)])
        #expect(RoomText.geometryIssue(.closerTo(.right), in: geometry) == "Your seat is 82 cm closer to the right speaker.")
    }
}
