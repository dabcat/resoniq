import Foundation
import Testing
@testable import ResoniqRoom

@Suite struct AcousticModelTests {
    @Test func axialModesOfTheLivingRoom() {
        let modes = RoomModes.axial(for: Fixtures.livingRoom, upTo: 100)
        // c = 343 m/s: length 343/11.2 = 30.625 Hz, width 343/8.4 = 40.833 Hz, height 343/4.8 = 71.458 Hz.
        let expected: [(RoomDimension, Int, Double)] = [
            (.length, 1, 30.625), (.width, 1, 40.833_333), (.length, 2, 61.25), (.height, 1, 71.458_333),
            (.width, 2, 81.666_667), (.length, 3, 91.875),
        ]
        #expect(modes.count == expected.count)
        for (mode, (dimension, order, frequency)) in zip(modes, expected) {
            #expect(mode.dimension == dimension && mode.order == order)
            #expect(isClose(mode.frequency, frequency, 1e-5))
        }
    }

    @Test func modePressure() {
        let mode = RoomMode(dimension: .length, order: 2, span: 5.6, frequency: 61.25)
        #expect(isClose(mode.pressure(atCoordinate: 0), 1))
        #expect(isClose(mode.pressure(atCoordinate: 1.4), 0, 1e-12))
        #expect(isClose(mode.pressure(atCoordinate: 2.8), -1))
    }

    @Test func boundaryDipsAreQuarterWavelengths() throws {
        let room = Fixtures.stereoRoom
        let right = try #require(room.speaker(role: .right))
        let dips = BoundaryInterference.dipFrequencies(for: right, in: room)
        // Behind: 1.40 m → 343/5.6 = 61.25 Hz. Side: 1.10 m to x = 2.1 → 343/4.4 = 77.95 Hz. Floor: 0.9 m → 95.28 Hz.
        #expect(dips.map(\.surface) == [.wallBehind, .sideWall, .floor])
        #expect(isClose(dips[0].frequency, 61.25, 1e-9))
        #expect(isClose(dips[1].distance, 1.1, 1e-12) && isClose(dips[1].frequency, 343 / 4.4, 1e-9))
        #expect(isClose(dips[2].frequency, 343 / 3.6, 1e-9))
    }
}
