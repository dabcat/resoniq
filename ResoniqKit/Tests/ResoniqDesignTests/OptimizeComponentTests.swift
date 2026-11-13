import CoreGraphics
import Testing
@testable import ResoniqDesign

@Suite struct OptimizeComponentTests {
    // MARK: Progress tracker

    @Test func `steps before the current are done, the current is current, the rest are upcoming`() {
        let states = (0..<4).map { TrackerStepState.state(ofStep: $0, current: 2) }
        #expect(states == [.done, .done, .current, .upcoming])
        #expect((0..<4).map { TrackerStepState.state(ofStep: $0, current: 4) } == [.done, .done, .done, .done])
        #expect((0..<4).map { TrackerStepState.state(ofStep: $0, current: -1) } == [.upcoming, .upcoming, .upcoming, .upcoming])
    }

    @Test func `a rule takes the state of the step it leads into`() {
        // Scanned, Measured, Move, Verify with Move current: lime, guide, line, as in V3Optimize.
        let rules = (1..<4).map { TrackerStepState.state(ofRuleBefore: $0, current: 2) }
        #expect(rules == [.done, .current, .upcoming])
    }

    @Test func `VoiceOver reads the step number, the title and the state`() {
        #expect(TrackerStepState.spokenLabel(title: "Move", index: 2, count: 4, current: 2) == "Step 3 of 4, Move, current")
        #expect(TrackerStepState.spokenLabel(title: "Scanned", index: 0, count: 4, current: 2) == "Step 1 of 4, Scanned, done")
        #expect(TrackerStepState.spokenLabel(title: "Verify", index: 3, count: 4, current: 2) == "Step 4 of 4, Verify, upcoming")
    }

    // MARK: Floor plan inset

    @Test func `the camera wedge opens ahead of the camera with a flat far edge`() {
        let wedge = FloorPlanInsetGeometry.wedge(apex: CGPoint(x: 40, y: 60), facing: 90)
        #expect(wedge.count == 3)
        #expect(wedge[0] == CGPoint(x: 40, y: 60))
        // Facing right: both corners at x = apex + 25, one above and one below, as in the mockup.
        #expect(abs(wedge[1].x - 65) < 1e-6 && abs(wedge[2].x - 65) < 1e-6)
        #expect(abs((wedge[1].y - 60) + (wedge[2].y - 60)) < 1e-6)
        #expect(abs(abs(wedge[1].y - 60) - 25 * tan(28.6 * .pi / 180)) < 1e-6)
    }

    @Test func `the wedge is empty for an apex it cannot use`() {
        #expect(FloorPlanInsetGeometry.wedge(apex: CGPoint(x: CGFloat.nan, y: 0), facing: 0).isEmpty)
        #expect(FloorPlanInsetGeometry.wedge(apex: .zero, facing: .nan, length: 25).count == 3)
        #expect(FloorPlanInsetGeometry.wedge(apex: .zero, facing: 0, length: .infinity).isEmpty)
    }

    @Test func `the inset's bounds hold the walls and the camera`() {
        let walls = [FloorPlanInset.Wall(.init(x1: 0, y1: 0, x2: 4, y2: 0), isCaptured: true)]
        #expect(FloorPlanInsetGeometry.bounds(walls: walls, camera: CGPoint(x: 2, y: 3)) == CGRect(x: 0, y: 0, width: 4, height: 3))
        #expect(FloorPlanInsetGeometry.bounds(walls: [], camera: CGPoint(x: CGFloat.nan, y: 0)) == nil)
    }

    // MARK: AR readout

    @Test func `progress is held to the bar and never not a number`() {
        #expect(ARProgress.fraction(0.62) == 0.62)
        #expect(ARProgress.fraction(-1) == 0)
        #expect(ARProgress.fraction(7) == 1)
        #expect(ARProgress.fraction(.nan) == 0)
        #expect(ARProgress.fraction(.infinity) == 0)
        #expect(ARProgress.percent(0.625) == 63)
    }

    // MARK: Before and after

    @Test func `the spoken row says improved only when it improved`() {
        #expect(BeforeAfterRow.spokenSummary(label: "Missing note, 61 Hz", before: "\u{2212}11 dB", after: "\u{2212}4 dB", improved: true)
            == "Missing note, 61 Hz, from \u{2212}11 dB to \u{2212}4 dB, improved")
        #expect(BeforeAfterRow.spokenSummary(label: "Midrange", before: "+1 dB", after: "+2 dB", improved: false)
            == "Midrange, from +1 dB to +2 dB")
    }

    // MARK: Direction

    @Test func `each direction turns the arrow and moves it the same way`() {
        for direction in DirectionArrowInstruction.Direction.allCases {
            let radians = direction.rotation * .pi / 180
            // The right-pointing arrow turned clockwise by `rotation` ends up along `vector`.
            #expect(abs(cos(radians) - direction.vector.dx) < 1e-9)
            #expect(abs(sin(radians) - direction.vector.dy) < 1e-9)
        }
    }
}
