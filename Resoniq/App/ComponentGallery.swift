#if DEBUG
import ResoniqDesign
import SwiftUI

/// Every Diagnose component in every state, for looking at in the simulator.
/// Open it with the launch argument `-gallery YES`; it replaces the tabs. Debug builds only.
struct ComponentGallery: View {
    @State private var speaker = Speaker.left
    @State private var holding = false

    private enum Speaker: Hashable {
        case left, right, only
    }

    /// A speaker that measured evenly with a little ripple.
    private static let measuredWidths: [Double] = (0..<48).map { index in
        let t = Double(index) / 47
        let taper = min(1, t * 10, (1 - t) * 14)
        return taper * (0.52 + 0.1 * sin(t * 14))
    }

    /// Three runs that turn rough between 0.38 and 0.62 of the width.
    private static let runs: [[Double]] = [1.0, 0.85, 0.95].map { depth in
        (0..<72).map { index in
            let t = Double(index) / 71
            guard (0.38...0.62).contains(t) else { return 0.5 }
            return index.isMultiple(of: 2) ? 0.5 + 0.38 * depth : 0.5 - 0.38 * depth
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ResoniqSpace.s6) {
                section("Speaker portrait") { portraits }
                section("Two portraits, shared ruler") { pair }
                section("Readout") { readouts }
                section("Status pill") { pills }
                section("Segmented control") { segmented }
                section("Hold to hear") { hold }
                section("Evidence tag") { tags }
                section("Run overlay") { overlay }
                Text("Measure").font(ResoniqFont.title3).foregroundStyle(ResoniqColor.ivory)
                section("Response curve") { responseCurves }
                section("Left and right") { channels }
                section("Average building") { averages }
                section("Spots diagram") { spotsDiagrams }
                section("Values table") { values }
                section("Numbered steps") { steps }
                section("Spectrum bars") { spectrum }
            }
            .padding(.horizontal, ResoniqSpace.screenInset)
            .padding(.vertical, ResoniqSpace.s6)
        }
        .background(ResoniqColor.ink)
        .scrollIndicators(.hidden)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
            Text(title).resoniqCapsLabel()
            content()
        }
    }

    // MARK: Sections

    private var portraits: some View {
        let states: [(String, SpeakerPortrait.Status, [ClosedRange<Double>])] = [
            ("Not heard", .notHeard, []),
            ("Drawing", .drawing(progress: 0.57), []),
            ("Paused", .paused(progress: 0.57), []),
            ("Finished", .finished, []),
            ("Deviation", .finished, [0.19...0.26]),
        ]
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: ResoniqSpace.s4) {
                ForEach(states.indices, id: \.self) { index in
                    VStack(spacing: ResoniqSpace.s2) {
                        HStack(alignment: .top, spacing: ResoniqSpace.s1) {
                            if index == 0 { FrequencyRuler(.beside).frame(height: 300) }
                            SpeakerPortrait(
                                widths: index == 0 ? [] : Self.measuredWidths,
                                state: states[index].1,
                                deviations: states[index].2
                            )
                            .frame(width: 84, height: 300)
                        }
                        Text(states[index].0)
                            .font(ResoniqFont.caption)
                            .foregroundStyle(ResoniqColor.muted)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .resoniqPanel()
    }

    private var pair: some View {
        HStack(alignment: .top, spacing: ResoniqSpace.s2) {
            SpeakerPortrait(widths: Self.measuredWidths, state: .finished, deviations: [0.19...0.26])
            FrequencyRuler(.between)
            SpeakerPortrait(state: .notHeard)
        }
        .frame(height: 320)
        .padding(.horizontal, ResoniqSpace.s4)
        .resoniqPanel()
    }

    private var readouts: some View {
        VStack(spacing: ResoniqSpace.s3) {
            ResoniqReadout(label: "Playing now", value: "1.02", unit: "kHz", detail: "Middle driver")
                .resoniqPanel()
            ResoniqReadout(label: "Playing now", value: "1.02", unit: "kHz", detail: "Out of range", isOutOfRange: true)
                .resoniqPanel()
            ResoniqReadout(
                label: "Room noise", value: "52 dB", size: .medium, isOutOfRange: true,
                level: ResoniqLevelBar(level: 0.78, mark: 0.55, caption: "Quiet enough left of the mark")
            )
            .resoniqPanel()
        }
    }

    private var pills: some View {
        HStack(spacing: ResoniqSpace.s2) {
            ResoniqStatusPill("Seat", style: .done)
            ResoniqStatusPill("Left", style: .active)
            ResoniqStatusPill("Right", style: .upcoming)
            ResoniqStatusPill("Paused", style: .paused)
        }
    }

    private var segmented: some View {
        ResoniqSegmentedControl(
            [
                ResoniqSegment(Speaker.left, title: "Left"),
                ResoniqSegment(Speaker.right, title: "Right"),
                ResoniqSegment(Speaker.only, title: "Only one"),
            ],
            selection: $speaker,
            label: "Which speaker"
        )
    }

    private var hold: some View {
        HStack(spacing: ResoniqSpace.s5) {
            ResoniqHoldToHear(accessibilityLabel: "Hold to play 90 hertz through the left speaker") { holding = $0 }
            VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
                Text(holding ? "Playing 90 Hz." : "Hold to hear it")
                    .font(ResoniqFont.headline)
                    .foregroundStyle(ResoniqColor.ivory)
                Text("Press and hold the button.")
                    .font(ResoniqFont.body)
                    .foregroundStyle(ResoniqColor.muted)
            }
        }
    }

    private var tags: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
            ResoniqEvidenceTag(.measured)
            ResoniqEvidenceTag(.inferred, basis: "3 of 3 runs", isDeviation: true)
            ResoniqEvidenceTag(.inferred, basis: "2 of 3 runs")
            ResoniqEvidenceTag(.inconclusive, basis: "could be the phone's angle")
            ResoniqEvidenceTag(.estimate, basis: "decay time")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .resoniqPanel()
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            Text("3 runs compared").resoniqCapsLabel()
            RunOverlay(
                traces: Self.runs,
                markedRange: 0.38...0.62,
                accessibilityLabel: "Three test runs one above the other. All three turn rough in the same place."
            )
        }
        .resoniqPanel()
    }
}

// MARK: - Measure

private extension ComponentGallery {
    private var seatExtremes: [ResponseCurve.Extreme] {
        [
            .init(frequency: 41, level: 9, label: "41 Hz +9 dB"),
            .init(frequency: 61, level: -11, label: "61 Hz \u{2212}11 dB"),
        ]
    }

    var responseCurves: some View {
        VStack(spacing: ResoniqSpace.s3) {
            ResponseCurve(
                levels: PreviewCurves.seat, evenBand: 3, range: 12, extremes: seatExtremes, drawsOnAppear: true,
                title: "Loudness at your seat", detail: "Even band \u{00B1}3 dB",
                accessibilityLabel: "Loudness across pitch at the seat. Below 100 hertz the line swings far outside the even band; above that it stays inside."
            )
            .resoniqPanel()
            ResponseCurve(
                levels: PreviewCurves.improved, evenBand: 3, range: 12, before: PreviewCurves.seat,
                legend: [
                    ResoniqLegendEntry("Before", color: ResoniqColor.muted, isDashed: true),
                    ResoniqLegendEntry("After", color: ResoniqColor.teal),
                ],
                accessibilityLabel: "Before and after. The peak at 41 hertz is lower and the dip at 61 hertz is much shallower."
            )
            .resoniqPanel()
            ResponseCurve(
                levels: PreviewCurves.seat.map { $0 * 0.2 }, evenBand: 3, range: 12, title: "An even room",
                accessibilityLabel: "The response stays inside the even band across the whole range."
            )
            .resoniqPanel()
            ResponseCurve(levels: [], evenBand: 3, range: 12, title: "No data", accessibilityLabel: "No measurement yet.")
                .resoniqPanel()
        }
    }

    var channels: some View {
        ChannelComparisonChart(
            left: PreviewCurves.seat,
            right: PreviewCurves.seat.enumerated().map { index, level in level + 1.2 * sin(Double(index) / 6) },
            caption: "1/3-octave smoothing",
            accessibilityLabel: "Left and right speaker response at the seat on a decibel grid. Both swing up at 41 hertz and down at 61 hertz, then run close together within 3 decibels."
        )
        .resoniqPanel()
    }

    var averages: some View {
        VStack(spacing: ResoniqSpace.s3) {
            AverageBuildingCurve(
                traces: [PreviewCurves.seat], average: PreviewCurves.improved, evenBand: 3, range: 12,
                title: "Building the average", detail: "1 of 3 in",
                accessibilityLabel: "The first spot's line is drawn faintly; the average is being built over it."
            )
            .resoniqPanel()
            AverageBuildingCurve(
                traces: [PreviewCurves.seat, PreviewCurves.improved],
                average: PreviewCurves.seat.indices.map { (PreviewCurves.seat[$0] + PreviewCurves.improved[$0]) / 2 },
                evenBand: 3, range: 12, isBuilding: false,
                title: "Building the average", detail: "2 of 3 in",
                accessibilityLabel: "Two spots are in; their average is drawn over their faint lines."
            )
            .resoniqPanel()
        }
    }

    var spotsDiagrams: some View {
        VStack(spacing: ResoniqSpace.s3) {
            SpotsDiagram(.guide, accessibilityLabel: "Seen from above: both speakers play toward a sofa. Three measuring spots sit in a row at head height, the middle one first.")
                .resoniqPanel(insets: EdgeInsets())
            SpotsDiagram(.guide, spots: [.upcoming, .upcoming, .upcoming], isPlaying: false, accessibilityLabel: "Both speakers are quiet. Three spots wait.")
                .resoniqPanel(insets: EdgeInsets())
            SpotsDiagram(.running, spots: [.active, .done, .upcoming], accessibilityLabel: "Three spots in a row. The middle one is done; the phone slides to the left one.")
                .resoniqPanel(insets: EdgeInsets())
            SpotsDiagram(.running, spots: [.done, .done, .active], accessibilityLabel: "Two spots are done; the phone moves to the right one.")
                .resoniqPanel(insets: EdgeInsets())
        }
    }

    var values: some View {
        ResoniqValuesTable(rows: [
            .init("41 Hz", value: "+9.2 dB", word: "peak", evidence: .measured, isDeviation: true, spokenValue: "plus 9.2 decibels"),
            .init("61 Hz", value: "\u{2212}11.4 dB", word: "dip", evidence: .measured, isDeviation: true, spokenValue: "minus 11.4 decibels"),
            .init("L / R", value: "\u{00B1}1.2 dB", word: "match", evidence: .measured, spokenLabel: "Left against right", spokenValue: "within 1.2 decibels"),
            .init("1 kHz", value: "0.4 %", word: "distortion", evidence: .measured),
            .init("< 80 Hz", value: "\u{2248} 0.6 s", word: "decay", evidence: .estimate),
            .init("Seat", value: "?", word: "unclear", evidence: .inconclusive),
            .init("Room", value: "5 m", word: "inferred", evidence: .inferred),
        ])
    }

    var steps: some View {
        VStack(spacing: 0) {
            ResoniqNumberedStep(1, "Phone at ear height, screen facing the ceiling")
            ResoniqNumberedStep(2, "Volume where you normally keep it", showsSeparator: true)
            ResoniqNumberedStep(3, "Stay quiet while the tones play", showsSeparator: true)
        }
    }

    var spectrum: some View {
        let bands = (0..<30).map { index -> Double in
            let t = Double(index) / 29
            return -30 - 40 * t + 18 * exp(-pow((t - 0.25) / 0.08, 2)) + 5 * sin(t * 40)
        }
        return VStack(spacing: ResoniqSpace.s3) {
            SpectrumBars(
                levels: bands, title: "Live", detail: "dB per third octave",
                accessibilityLabel: "Loudest around 90 hertz; treble is quiet."
            )
            .resoniqPanel()
            SpectrumBars(levels: [], title: "Waiting for sound", accessibilityLabel: "No sound yet.")
                .resoniqPanel()
        }
    }
}

#Preview {
    ComponentGallery()
}
#endif
