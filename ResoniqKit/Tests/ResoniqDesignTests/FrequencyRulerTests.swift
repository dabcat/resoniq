import Testing
@testable import ResoniqDesign

@Suite struct FrequencyRulerTests {
    @Test func `the ends of the axis map to 0 and 1`() {
        #expect(FrequencyRuler.fraction(forFrequency: 20) == 0)
        #expect(abs(FrequencyRuler.fraction(forFrequency: 20_000) - 1) < 1e-12)
    }

    @Test func `the middle of the log axis is about 632 Hz`() {
        #expect(abs(FrequencyRuler.fraction(forFrequency: 632) - 0.5) < 0.001)
    }

    @Test func `ticks sit where the mockup draws them`() {
        // V3Result: 100 Hz at y 336 and 1 kHz at y 192 of a ruler running from y 436 (20 Hz) to y 6 (20 kHz).
        let span = 430.0
        #expect(abs(FrequencyRuler.fraction(forFrequency: 100) * span - (436 - 336)) < 1)
        #expect(abs(FrequencyRuler.fraction(forFrequency: 1_000) * span - (436 - 192)) < 1)
        #expect(abs(FrequencyRuler.fraction(forFrequency: 10_000) * span - (436 - 49)) < 1)
    }

    @Test func `frequencies outside the axis are held at its ends`() {
        #expect(FrequencyRuler.fraction(forFrequency: 5) == 0)
        #expect(FrequencyRuler.fraction(forFrequency: 0) == 0)
        #expect(FrequencyRuler.fraction(forFrequency: -3) == 0)
        #expect(FrequencyRuler.fraction(forFrequency: 40_000) == 1)
        #expect(FrequencyRuler.fraction(forFrequency: .infinity) == 1)
        #expect(FrequencyRuler.fraction(forFrequency: .nan) == 0)
    }

    @Test(arguments: [20.0, 55, 90, 440, 1_000, 14_000, 20_000])
    func `frequency and fraction are inverses`(hertz: Double) {
        let back = FrequencyRuler.frequency(forFraction: FrequencyRuler.fraction(forFrequency: hertz))
        #expect(abs(back - hertz) / hertz < 1e-9)
    }

    @Test func `ticks are increasing and inside the axis`() {
        for ticks in [FrequencyRuler.majorTicks, FrequencyRuler.minorTicks] {
            #expect(ticks == ticks.sorted())
            #expect(ticks.allSatisfy { $0 >= FrequencyRuler.lowestFrequency && $0 <= FrequencyRuler.highestFrequency })
        }
    }

    @Test(arguments: [(20.0, "20"), (100, "100"), (1_000, "1k"), (10_000, "10k"), (20_000, "20k")])
    func `labels`(hertz: Double, label: String) {
        #expect(FrequencyRuler.label(forFrequency: hertz) == label)
    }

    @Test(arguments: [(90.2, "90 hertz"), (1_020, "1 kilohertz"), (14_500, "14.5 kilohertz")])
    func `spoken frequencies`(hertz: Double, spoken: String) {
        #expect(FrequencyRuler.spokenFrequency(hertz) == spoken)
    }
}
