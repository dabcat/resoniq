import CoreGraphics
import SwiftUI
import Testing
@testable import ResoniqDesign

@Suite struct SpeakerPortraitTests {
    static let frame = CGRect(x: 10, y: 20, width: 120, height: 430)

    static let profiles: [(name: String, widths: [Double])] = [
        ("empty", []),
        ("single", [0.6]),
        ("pair", [0, 1]),
        ("unknown speaker", SpeakerPortrait.unknownSpeakerWidths),
        ("full width", Array(repeating: 1, count: 40)),
        ("out of range and not a number", [-3, 0.5, 7, .nan, 1, .infinity, -.infinity]),
        ("spiky", (0..<64).map { $0.isMultiple(of: 2) ? 1.0 : 0.0 }),
    ]

    /// Paths keep their points as Float, so allow for that rounding.
    static let slack = 1e-3

    private func boundsHold(_ path: Path) -> Bool {
        guard !path.isEmpty else { return true }
        let box = path.boundingRect
        let slack = Self.slack
        return box.minX >= Self.frame.minX - slack && box.maxX <= Self.frame.maxX + slack
            && box.minY >= Self.frame.minY - slack && box.maxY <= Self.frame.maxY + slack
    }

    @Test(arguments: profiles.map(\.widths))
    func `portrait stays inside its bounds`(widths: [Double]) {
        let path = SpeakerPortraitShape(widths: widths).path(in: Self.frame)
        #expect(boundsHold(path))
    }

    @Test(arguments: profiles.map(\.widths))
    func `portrait is symmetric about its centre line`(widths: [Double]) {
        let path = SpeakerPortraitShape(widths: widths).path(in: Self.frame)
        guard !path.isEmpty else { return }
        let box = path.boundingRect
        // The shape's extent is the same either side of the middle.
        #expect(abs((box.midX) - Self.frame.midX) < Self.slack)
        // Mirroring it about the middle gives the same outline.
        let mirrored = path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * Self.frame.midX, ty: 0))
        let mirroredBox = mirrored.boundingRect
        #expect(abs(mirroredBox.minX - box.minX) < Self.slack)
        #expect(abs(mirroredBox.maxX - box.maxX) < Self.slack)
    }

    @Test func `empty widths draw nothing and one width draws a column`() {
        #expect(SpeakerPortraitShape(widths: []).path(in: Self.frame).isEmpty)
        let column = SpeakerPortraitShape(widths: [0.5]).path(in: Self.frame).boundingRect
        #expect(abs(column.width - Self.frame.width * 0.5) < Self.slack)
        #expect(abs(column.height - Self.frame.height) < Self.slack)
    }

    @Test func `width follows the widths`() {
        let path = SpeakerPortraitShape(widths: [0, 1, 0]).path(in: Self.frame)
        // Full width at the middle height, none at the ends.
        let middle = CGPoint(x: Self.frame.minX + 1, y: Self.frame.midY)
        #expect(path.contains(middle))
        let nearTop = CGPoint(x: Self.frame.minX + 1, y: Self.frame.minY + 2)
        #expect(!path.contains(nearTop))
    }

    @Test(arguments: profiles.map(\.widths), [0.0...0.2, 0.19...0.26, 0.9...1.0, -1.0...2.0])
    func `deviation patch stays inside the bounds and is symmetric`(widths: [Double], range: ClosedRange<Double>) {
        let path = DeviationBandShape(widths: widths, range: range).path(in: Self.frame)
        #expect(boundsHold(path))
        guard !path.isEmpty else { return }
        let box = path.boundingRect
        #expect(abs(box.midX - Self.frame.midX) < Self.slack)
    }

    @Test func `patch with no width to follow or an empty range is empty`() {
        #expect(DeviationBandShape(widths: [], range: 0.2...0.4).path(in: Self.frame).isEmpty)
        #expect(DeviationBandShape(widths: [1, 1], range: 0.4...0.4).path(in: Self.frame).isEmpty)
    }

    @Test func `half width follows the samples`() {
        let widths = [0.2, 0.8, 0.4]
        #expect(abs(PortraitGeometry.halfWidth(at: 0, widths: widths) - 0.2) < 1e-12)
        #expect(abs(PortraitGeometry.halfWidth(at: 0.5, widths: widths) - 0.8) < 1e-12)
        #expect(abs(PortraitGeometry.halfWidth(at: 1, widths: widths) - 0.4) < 1e-12)
        #expect(PortraitGeometry.halfWidth(at: 0.25, widths: widths) > 0.2)
        #expect(PortraitGeometry.halfWidth(at: 0.25, widths: widths) < 0.8)
        #expect(PortraitGeometry.halfWidth(at: 0.5, widths: []) == 0)
    }

    @Test func `drawn part excludes the deviations`() {
        let kept = PortraitGeometry.intervals(upTo: 1, excluding: [0.19...0.26])
        #expect(kept == [0...0.19, 0.26...1])
        // Overlapping, unsorted and out-of-range cuts.
        let messy = PortraitGeometry.intervals(upTo: 0.5, excluding: [0.4...0.9, 0.1...0.2, 0.15...0.3, -1...0])
        #expect(messy == [0...0.1, 0.3...0.4])
        #expect(PortraitGeometry.intervals(upTo: 0, excluding: []).isEmpty)
        #expect(PortraitGeometry.intervals(upTo: 0.3, excluding: [0.5...0.6]) == [0...0.3])
    }

    @Test func `default profile is a usable width list`() {
        let widths = SpeakerPortrait.unknownSpeakerWidths
        #expect(widths.count >= 2)
        #expect(widths.allSatisfy { (0...1).contains($0) })
    }
}
