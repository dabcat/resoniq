import CoreGraphics
import Testing
@testable import ResoniqDesign

@Suite struct ChartGeometryTests {
    private let plot = CGRect(x: 0, y: 0, width: 300, height: 146)

    // MARK: Level to y

    @Test func `the middle is halfway, the limits are the top and bottom`() {
        #expect(ChartGeometry.yFraction(level: 0, range: 12) == 0.5)
        #expect(ChartGeometry.yFraction(level: 12, range: 12) == 0)
        #expect(ChartGeometry.yFraction(level: -12, range: 12) == 1)
        #expect(abs(ChartGeometry.yFraction(level: 6, range: 12) - 0.25) < 1e-12)
    }

    @Test func `levels beyond the range are held at its edge`() {
        #expect(ChartGeometry.yFraction(level: 40, range: 12) == 0)
        #expect(ChartGeometry.yFraction(level: -40, range: 12) == 1)
        #expect(ChartGeometry.yFraction(level: .infinity, range: 12) == 0)
        #expect(ChartGeometry.yFraction(level: -.infinity, range: 12) == 1)
    }

    @Test func `NaN is the middle and a bad range does not divide by zero`() {
        #expect(ChartGeometry.yFraction(level: .nan, range: 12) == 0.5)
        for range in [0.0, -3, .nan, .infinity] {
            let fraction = ChartGeometry.yFraction(level: 5, range: range)
            #expect(fraction.isFinite && (0...1).contains(fraction))
        }
    }

    @Test func `y stays inside the plot, kept off the edges by the inset`() {
        let top = ChartGeometry.y(level: 99, range: 12, in: plot)
        let bottom = ChartGeometry.y(level: -99, range: 12, in: plot)
        #expect(top == ChartGeometry.plotInset)
        #expect(bottom == plot.height - ChartGeometry.plotInset)
    }

    @Test func `a plot shorter than its inset still gives finite y`() {
        let tiny = CGRect(x: 0, y: 0, width: 10, height: 3)
        #expect(ChartGeometry.y(level: 5, range: 12, in: tiny).isFinite)
    }

    // MARK: Points and paths

    @Test func `no levels give no points and no path`() {
        #expect(ChartGeometry.points(levels: [], range: 12, in: plot).isEmpty)
        #expect(ChartGeometry.smoothPath(through: []).isEmpty)
    }

    @Test func `one level is a line across the plot`() {
        let points = ChartGeometry.points(levels: [3], range: 12, in: plot)
        #expect(points.count == 2)
        #expect(points[0].x == 0 && points[1].x == plot.width)
        #expect(points[0].y == points[1].y)
    }

    @Test func `the first sample is at the left edge and the last at the right`() {
        let points = ChartGeometry.points(levels: [0, 4, -4, 2], range: 12, in: plot)
        #expect(points.first?.x == 0)
        #expect(points.last?.x == plot.width)
    }

    @Test(arguments: [0, 1, 2, 3, 96, 2_000])
    func `paths stay inside the plot for any length`(count: Int) {
        let levels = (0..<count).map { 30 * sin(Double($0) / 3) }
        let path = ChartGeometry.smoothPath(through: ChartGeometry.points(levels: levels, range: 12, in: plot))
        if count == 0 {
            #expect(path.isEmpty)
        } else {
            let box = path.boundingRect
            #expect(box.minX >= plot.minX - 0.001 && box.maxX <= plot.maxX + 0.001)
            #expect(box.minY >= plot.minY - 0.001 && box.maxY <= plot.maxY + 0.001)
        }
    }

    @Test func `non-finite levels give finite coordinates`() {
        let levels: [Double] = [0, .nan, .infinity, -.infinity, 5, .nan]
        let points = ChartGeometry.points(levels: levels, range: 12, in: plot)
        #expect(points.count == levels.count)
        #expect(points.allSatisfy { (0...plot.maxX).contains($0.x) && (0...plot.maxY).contains($0.y) })
        let box = ChartGeometry.smoothPath(through: points).boundingRect
        #expect(box.minX.isFinite && box.minY.isFinite && box.maxX.isFinite && box.maxY.isFinite)
    }

    @Test func `the curve does not overshoot a peak`() {
        let points = ChartGeometry.points(levels: [0, 0, 10, 0, 0], range: 12, in: plot)
        let top = points.map(\.y).min() ?? 0
        #expect(ChartGeometry.smoothPath(through: points).boundingRect.minY >= top - 0.001)
    }

    // MARK: In band and out of band

    @Test func `a trace that never leaves the band is one inside segment`() {
        let segments = ChartGeometry.segments(levels: [0, 1, -2, 2.9, 0], evenBand: 3)
        #expect(segments == [.init(start: 0, end: 1, isOutside: false)])
    }

    @Test func `the split falls where the line crosses the band`() throws {
        let segments = ChartGeometry.segments(levels: [0, 6], evenBand: 3)
        #expect(segments.count == 2)
        #expect(!segments[0].isOutside && segments[1].isOutside)
        #expect(abs(segments[0].end - 0.5) < 1e-12 && segments[1].start == segments[0].end)
    }

    @Test func `a peak and a dip are cut on both sides`() {
        // 6 -> 0 crosses +3 a quarter of the way, 0 -> -6 crosses -3 three quarters of the way.
        let segments = ChartGeometry.segments(levels: [6, 0, -6], evenBand: 3)
        #expect(segments.map(\.isOutside) == [true, false, true])
        #expect(abs(segments[0].end - 0.25) < 1e-12)
        #expect(abs(segments[1].end - 0.75) < 1e-12)
    }

    @Test func `a jump across the whole band is cut twice inside one step`() {
        let segments = ChartGeometry.segments(levels: [6, -6], evenBand: 3)
        #expect(segments.map(\.isOutside) == [true, false, true])
        #expect(abs(segments[0].end - 0.25) < 1e-12 && abs(segments[1].end - 0.75) < 1e-12)
    }

    @Test func `segments cover the width without a gap`() {
        let levels = (0..<80).map { 9 * sin(Double($0) / 5) }
        let segments = ChartGeometry.segments(levels: levels, evenBand: 3)
        #expect(segments.first?.start == 0)
        #expect(abs((segments.last?.end ?? 0) - 1) < 1e-12)
        for pair in zip(segments, segments.dropFirst()) {
            #expect(abs(pair.0.end - pair.1.start) < 1e-12)
            #expect(pair.0.isOutside != pair.1.isOutside)
        }
    }

    @Test func `empty, single and non-finite traces do not trap`() {
        #expect(ChartGeometry.segments(levels: [], evenBand: 3).isEmpty)
        #expect(ChartGeometry.segments(levels: [8], evenBand: 3) == [.init(start: 0, end: 1, isOutside: true)])
        let segments = ChartGeometry.segments(levels: [.nan, .infinity, 0, -.infinity], evenBand: .nan)
        #expect(segments.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start })
    }

    // MARK: Labels

    private func label(at anchor: CGPoint, above: Bool, width: CGFloat = 70) -> ChartGeometry.LabelRequest {
        .init(anchor: anchor, size: CGSize(width: width, height: 13), prefersAbove: above)
    }

    @Test func `labels stay inside the plot, even for dots at the edges`() {
        let anchors = [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 0, y: 146), CGPoint(x: 300, y: 146), CGPoint(x: 150, y: 70)]
        for anchor in anchors {
            for above in [true, false] {
                let frames = ChartGeometry.placeLabels([label(at: anchor, above: above)], in: plot, avoiding: [])
                #expect(plot.contains(frames[0]))
            }
        }
    }

    @Test func `a label wider than the plot is held to its leading edge, not outside`() {
        let frames = ChartGeometry.placeLabels([label(at: CGPoint(x: 50, y: 50), above: true, width: 400)], in: plot, avoiding: [])
        #expect(frames[0].minX == plot.minX && frames[0].minY >= plot.minY)
    }

    @Test func `two labels at nearby dots do not overlap`() {
        let requests = [label(at: CGPoint(x: 30, y: 20), above: true), label(at: CGPoint(x: 45, y: 24), above: true)]
        let frames = ChartGeometry.placeLabels(requests, in: plot, avoiding: [])
        #expect(!frames[0].intersects(frames[1]))
        #expect(frames.allSatisfy { plot.contains($0) })
    }

    @Test func `a label keeps off the trace`() {
        // A level trace through the dot: a label at the dot's height would sit on it.
        let trace = ChartGeometry.points(levels: [0, 0, 0, 0], range: 12, in: plot)
        let anchor = CGPoint(x: 100, y: trace[0].y)
        let frame = ChartGeometry.placeLabels([label(at: anchor, above: true)], in: plot, avoiding: trace)[0]
        #expect(frame.maxY < anchor.y || frame.minY > anchor.y)
    }

    @Test func `the mockup's peak and dip get their labels beside them, clear of the curve`() {
        let levels = PreviewCurves.seat
        let trace = ChartGeometry.points(levels: levels, range: 12, in: plot)
        let peak = CGPoint(x: ChartGeometry.x(fraction: FrequencyRuler.fraction(forFrequency: 41), in: plot), y: ChartGeometry.y(level: 9, range: 12, in: plot))
        let dip = CGPoint(x: ChartGeometry.x(fraction: FrequencyRuler.fraction(forFrequency: 61), in: plot), y: ChartGeometry.y(level: -11, range: 12, in: plot))
        let frames = ChartGeometry.placeLabels([label(at: peak, above: true), label(at: dip, above: false)], in: plot, avoiding: trace)
        #expect(frames.allSatisfy { plot.contains($0) })
        #expect(!frames[0].intersects(frames[1]))
    }

    // MARK: Text

    @Test func `grid labels use a true minus sign`() {
        #expect(ChartGeometry.gridLabel(12) == "+12")
        #expect(ChartGeometry.gridLabel(0) == "0")
        #expect(ChartGeometry.gridLabel(-6) == "\u{2212}6")
        #expect(ChartGeometry.gridLabel(.nan) == "0")
    }

    @Test func `the grid is labelled at +12, +6, 0, -6, -12`() {
        #expect(ChannelComparisonChart.gridLevels(range: 12, step: 6) == [12, 6, 0, -6, -12])
        #expect(ChannelComparisonChart.gridLevels(range: 12, step: 0) == [12, 0, -12])
        #expect(ChannelComparisonChart.gridLevels(range: 12, step: 50) == [0])
    }
}

@Suite struct SpectrumGeometryTests {
    private let plot = CGRect(x: 0, y: 0, width: 300, height: 132)
    private let range = -90.0...(-10.0)

    @Test func `bar height is a fraction of the range, clamped`() {
        #expect(SpectrumGeometry.barFraction(level: -90, range: range) == 0)
        #expect(SpectrumGeometry.barFraction(level: -10, range: range) == 1)
        #expect(SpectrumGeometry.barFraction(level: -50, range: range) == 0.5)
        #expect(SpectrumGeometry.barFraction(level: 20, range: range) == 1)
        #expect(SpectrumGeometry.barFraction(level: -200, range: range) == 0)
        #expect(SpectrumGeometry.barFraction(level: .nan, range: range) == 0)
        #expect(SpectrumGeometry.barFraction(level: .infinity, range: range) == 1)
        #expect(SpectrumGeometry.barFraction(level: 1, range: 3...3) == 0)
    }

    @Test(arguments: [0, 1, 30, 1_000])
    func `bars lie inside the plot for any count`(count: Int) {
        let levels = (0..<count).map { -50 + 80 * sin(Double($0)) }
        let bars = SpectrumGeometry.bars(levels: levels, range: range, in: plot, gap: 2, minimumHeight: 1)
        #expect(bars.count == count)
        for bar in bars {
            #expect(bar.minX >= -0.001 && bar.maxX <= plot.maxX + 0.001)
            #expect(bar.minY >= -0.001 && bar.maxY <= plot.maxY + 0.001)
            #expect(bar.height >= 1 - 0.001)
        }
    }

    @Test func `non-finite levels give finite bars`() {
        let bars = SpectrumGeometry.bars(levels: [.nan, .infinity, -.infinity], range: range, in: plot, gap: 2, minimumHeight: 1)
        #expect(bars.allSatisfy { $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite })
    }
}

@Suite struct SpotsGeometryTests {
    @Test(arguments: [SpotsDiagram.Variant.guide, .running])
    func `spots and speakers are inside the drawing`(variant: SpotsDiagram.Variant) {
        let box = CGRect(origin: .zero, size: SpotsGeometry.size(of: variant))
        let centres = SpotsGeometry.spotCentres(of: variant)
        #expect(centres.count == 3)
        #expect(centres.allSatisfy { box.contains($0) })
        for speaker in SpotsGeometry.speakerCentres {
            #expect(box.insetBy(dx: SpotsGeometry.speakerSide / 2, dy: SpotsGeometry.speakerSide / 2).contains(speaker))
        }
    }

    @Test func `sound arcs stay inside the guide drawing`() {
        let box = CGRect(origin: .zero, size: SpotsGeometry.size(of: .guide))
        for speaker in SpotsGeometry.speakerCentres {
            for arc in SpotsGeometry.arcs {
                let points = SpotsGeometry.arcPoints(centre: CGPoint(x: speaker.x, y: speaker.y + arc.offset), radius: arc.radius)
                #expect(points.allSatisfy { box.contains($0) })
            }
        }
    }

    @Test func `the phone goes to the active spot and starts from the first done one`() {
        let spots: [SpotsDiagram.SpotState] = [.active, .done, .upcoming]
        let target = SpotsGeometry.phoneTarget(spots: spots, requested: nil)
        #expect(target == 0)
        #expect(SpotsGeometry.phoneStart(spots: spots, target: target) == 1)
        #expect(SpotsGeometry.phoneTarget(spots: spots, requested: 9) == 2)
        #expect(SpotsGeometry.normalised([.done]).count == 3)
    }
}

@Suite struct ValuesTableTests {
    @Test func `a row reads as a sentence with its evidence`() {
        let row = ResoniqValuesTable.Row("41 Hz", value: "+9.2 dB", word: "peak", evidence: .measured)
        #expect(row.sentence == "41 Hz, +9.2 dB, peak. Measured.")
        let spoken = ResoniqValuesTable.Row("61 Hz", value: "\u{2212}11.4 dB", word: "dip", evidence: .estimate, spokenValue: "minus 11.4 decibels")
        #expect(spoken.sentence == "61 Hz, minus 11.4 decibels, dip. Estimate.")
    }

    @Test func `step numbers have two digits`() {
        #expect(ResoniqNumberedStep.numeral(1) == "01")
        #expect(ResoniqNumberedStep.numeral(12) == "12")
    }
}
