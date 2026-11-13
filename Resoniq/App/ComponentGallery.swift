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

#Preview {
    ComponentGallery()
}
#endif
