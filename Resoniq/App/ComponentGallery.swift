#if DEBUG
import ResoniqDesign
import SwiftUI

/// Every Diagnose component in every state, for looking at in the simulator.
/// Open it with the launch argument `-gallery YES`; it replaces the tabs. Debug builds only.
struct ComponentGallery: View {
    @State private var speaker = Speaker.left
    @State private var holding = false
    @State private var optimizeRoom = RoomPlanContent.sampleMeasured
    @State private var optimizeSelection: String? = "right"

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
                Text("Optimize").font(ResoniqFont.title3).foregroundStyle(ResoniqColor.ivory)
                section("Progress tracker") { trackers }
                section("Room plan") { roomPlans }
                section("Room plan editor") { roomEditors }
                section("Chips") { chips }
                section("Floor plan inset") { floorInsets }
                section("AR guidance") { arGuidance }
                section("Direction instruction") { directions }
                section("Before and after") { beforeAfter }
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

// MARK: - Optimize

private extension ComponentGallery {
    var trackers: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s5) {
            ResoniqProgressTracker(steps: ["Scanned", "Measured", "Move", "Verify"], current: 2)
            ResoniqProgressTracker(steps: ["Scanned", "Measured", "Move", "Verify"], current: 1)
            ResoniqProgressTracker(steps: ["Scanned", "Measured", "Moved", "Verified"], current: 4)
            ResoniqProgressTracker(steps: ["Scanned", "Measured", "Move", "Verify"], current: 3)
                .environment(\.dynamicTypeSize, .accessibility2)
        }
    }

    var roomPlans: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s5) {
            RoomPlanView(.sample, accessibilityLabel: RoomPlanContent.sampleSummary)
            RoomPlanView(.sample, isSuggestionAnimating: true, accessibilityLabel: RoomPlanContent.sampleSummary)
            RoomPlanView(
                .sampleMeasured, showsLegend: false, height: 260,
                accessibilityLabel: "The room with three measured spots at the seat inside a bass dip. Nothing is suggested yet."
            )
            RoomPlanView(
                RoomPlanContent(walls: [.init(x1: 0, y1: 0, x2: 3, y2: 0)]), showsLegend: false, height: 140,
                accessibilityLabel: "One wall scanned so far."
            )
            RoomPlanView(RoomPlanContent(), showsLegend: false, height: 120, accessibilityLabel: "Nothing scanned yet.")
        }
    }

    var roomEditors: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s5) {
            RoomPlanEditor(
                optimizeRoom,
                selection: $optimizeSelection,
                distance: optimizeSelection == "right"
                    ? RoomPlanWallDistance(label: "0.90 m", wallPoint: CGPoint(x: optimizeRoom.speakers.first { $0.id == "right" }?.position.x ?? 3.4, y: 0))
                    : nil,
                accessibilityLabel: "Room plan with the left and right speakers and the seat. Drag one to move it.",
                onMove: { id, proposed in
                    let held = CGPoint(x: min(max(proposed.x, 0.2), 4.0), y: min(max(proposed.y, 0.2), 5.4))
                    if let index = optimizeRoom.speakers.firstIndex(where: { $0.id == id }) { optimizeRoom.speakers[index].position = held }
                    if let index = optimizeRoom.seats.firstIndex(where: { $0.id == id }) { optimizeRoom.seats[index].position = held }
                    return held
                },
                onRotate: { id, facing in
                    if let index = optimizeRoom.speakers.firstIndex(where: { $0.id == id }) { optimizeRoom.speakers[index].facing = facing }
                    return facing
                }
            )
            RoomPlanEditor(
                .sampleMeasured, selection: .constant(nil), height: 240,
                accessibilityLabel: "Room plan with nothing selected.", onMove: { $1 }, onRotate: { $1 }
            )
        }
    }

    var chips: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
            HStack(spacing: ResoniqSpace.s2) {
                ResoniqChip("Add subwoofer") {}
                ResoniqChip("Add a seat") {}
                ResoniqChip("Fix a wall") {}
            }
            HStack(spacing: ResoniqSpace.s2) {
                ResoniqChip("Window", style: .detected)
                ResoniqChip("Door", style: .detected)
                ResoniqChip("Sofa", style: .detected)
                ResoniqChip("4.20 m", style: .measurement)
            }
            .padding(ResoniqSpace.s3)
            .background(ResoniqColor.panelRaised)
        }
    }

    var floorInsets: some View {
        HStack(alignment: .top, spacing: ResoniqSpace.s3) {
            FloorPlanInset(
                walls: FloorPlanInset.sampleWalls, camera: CGPoint(x: 2, y: 3.6), cameraFacing: 70,
                accessibilityLabel: "Small floor plan: three walls drawn, the right wall still missing, a wedge shows where the camera points."
            )
            FloorPlanInset(
                walls: FloorPlanInset.sampleWalls.map { FloorPlanInset.Wall($0.segment, isCaptured: true) }, camera: CGPoint(x: 2, y: 3.6), cameraFacing: 0,
                accessibilityLabel: "Small floor plan: all four walls drawn."
            )
            FloorPlanInset(walls: [], camera: .zero, cameraFacing: 0, accessibilityLabel: "Small floor plan: nothing captured yet.")
        }
        .padding(ResoniqSpace.s3)
        .background(ResoniqColor.panelRaised)
    }

    var arGuidance: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
            ZStack(alignment: .topLeading) {
                ResoniqColor.panelRaised
                VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
                    ARStepPill("Right speaker \u{00B7} step 1 of 2")
                    ARToGoCard(value: "18", unit: "cm")
                }
                .padding(ResoniqSpace.s4)
            }
            .frame(height: 180)
            ARGuidanceReadout(
                title: "Right speaker \u{00B7} step 1 of 2", toGoValue: "18", unit: "cm", progress: 0.62,
                instruction: "Slide it toward you until it fills the blue outline.", progressLabel: "Distance moved",
                leadingLine: "35 cm in total", trailingLine: "then turn 12\u{00B0} toward your seat",
                hint: "Taps in your hand speed up as you get closer."
            )
            ARGuidanceReadout(
                title: "Right speaker \u{00B7} step 2 of 2", toGoValue: "12", unit: "\u{00B0}", progress: 1,
                instruction: "Turn it toward your seat."
            )
        }
    }

    var directions: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
            DirectionArrowInstruction(.right, text: "Turn right to catch the last wall.")
            DirectionArrowInstruction(.left, text: "Turn left to the window.")
            DirectionArrowInstruction(.forward, text: "Walk forward a little.")
            DirectionArrowInstruction(.back, text: "Step back to see the whole wall.")
        }
    }

    var beforeAfter: some View {
        VStack(spacing: 0) {
            BeforeAfterRow(label: "Missing note, 61 Hz", before: "\u{2212}11 dB", after: "\u{2212}4 dB", improved: true, showsDivider: false)
            BeforeAfterRow(label: "Booming note, 41 Hz", before: "+9 dB", after: "+5 dB", improved: true)
            BeforeAfterRow(label: "Midrange, 400 Hz", before: "+1 dB", after: "+2 dB", improved: false)
            BeforeAfterRow(label: "Voices and treble", unchanged: "Unchanged, still even")
        }
    }
}

#Preview {
    ComponentGallery()
}
#endif
