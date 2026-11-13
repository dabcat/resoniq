import ResoniqDesign
import ResoniqStore
import SwiftUI

/// Aim (design/screens/V3Start.dc.html): how to hold the phone, which speaker, and "Start listening". The first
/// test and every later one are this same screen.
struct AimScreen: View {
    @Binding var position: SpeakerPosition
    var onStart: () -> Void
    var onClose: () -> Void

    var body: some View {
        FlowScaffold {
            HStack {
                Text("Resoniq")
                    .font(Metrics.wordmarkFont)
                    .tracking(Metrics.wordmarkSize * Metrics.wordmarkTracking)
                    .foregroundStyle(ResoniqColor.ivory)
                Spacer()
                Button("Not now", action: onClose)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
        } content: {
            VStack(alignment: .leading, spacing: ResoniqSpace.s5) {
                VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
                    Text("Let's hear a speaker.")
                        .font(ResoniqFont.display)
                        .tracking(Metrics.headlineSize * ResoniqFont.Tracking.title)
                        .foregroundStyle(ResoniqColor.ivory)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Stop any music, then hold your iPhone like this.")
                        .font(ResoniqFont.bodyLarge)
                        .foregroundStyle(ResoniqColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .resoniqTitleRise()

                AimIllustration()

                ResoniqSegmentedControl(
                    [
                        ResoniqSegment(SpeakerPosition.left, title: "Left"),
                        ResoniqSegment(SpeakerPosition.right, title: "Right"),
                        ResoniqSegment(SpeakerPosition.single, title: "Only one"),
                    ],
                    selection: $position,
                    label: "Which speaker"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            VStack(spacing: ResoniqSpace.s3) {
                Button("Start listening", action: onStart)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
                Text("Resoniq will ask for the microphone. Sound is analyzed on this iPhone and never leaves it.")
                    .font(ResoniqFont.caption)
                    .foregroundStyle(ResoniqColor.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private enum Metrics {
        static let headlineSize: CGFloat = 36
        static let wordmarkSize: CGFloat = 17
        static let wordmarkFont = ResoniqFont.font(.sansBold, size: wordmarkSize, relativeTo: .headline)
        static let wordmarkTracking: CGFloat = -0.01
    }
}

/// The phone held sideways about 30 cm from the speaker, drawn in the mockup's 340 x 298 space: the not-heard
/// portrait and its ruler on the left, a 30 cm measure, the phone on the right with the microphone end lit.
private struct AimIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringExpanded = false

    var body: some View {
        GeometryReader { proxy in
            let scale = min(1, proxy.size.width / Metrics.canvas.width)
            canvas
                .frame(width: Metrics.canvas.width, height: Metrics.canvas.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .top)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(height: Metrics.height)
        .background(ResoniqColor.panel, in: RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous)
                .strokeBorder(ResoniqColor.line, lineWidth: ResoniqSize.strokeHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "An iPhone held sideways 30 centimetres from a speaker, its bottom edge facing the middle of the speaker"
        )
        .accessibilityAddTraits(.isImage)
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            // The speaker's axis.
            Rectangle()
                .fill(ResoniqColor.line)
                .frame(width: Metrics.canvas.width, height: ResoniqSize.strokeHairline)
                .offset(y: Metrics.axisY - ResoniqSize.strokeHairline / 2)

            // A speaker nobody has heard yet, with its ruler.
            HStack(spacing: 0) {
                FrequencyRuler(.beside)
                SpeakerPortrait(state: .notHeard)
            }
            .frame(width: Metrics.portrait.width, height: Metrics.portrait.height)
            .offset(x: Metrics.portrait.minX, y: Metrics.portrait.minY)

            // The 30 cm measure.
            Path { path in
                path.move(to: CGPoint(x: Metrics.measureStart, y: Metrics.axisY))
                path.addLine(to: CGPoint(x: Metrics.measureEnd, y: Metrics.axisY))
                path.move(to: CGPoint(x: Metrics.measureStart, y: Metrics.axisY - Metrics.tick))
                path.addLine(to: CGPoint(x: Metrics.measureStart, y: Metrics.axisY + Metrics.tick))
                path.move(to: CGPoint(x: Metrics.measureEnd, y: Metrics.axisY - Metrics.tick))
                path.addLine(to: CGPoint(x: Metrics.measureEnd, y: Metrics.axisY + Metrics.tick))
            }
            .stroke(ResoniqColor.ivory, lineWidth: Metrics.measureStroke)

            // The phone, sideways, and the microphone at its bottom edge.
            RoundedRectangle(cornerRadius: Metrics.phoneRadius, style: .continuous)
                .stroke(ResoniqColor.ivory, lineWidth: Metrics.phoneStroke)
                .frame(width: Metrics.phone.width, height: Metrics.phone.height)
                .offset(x: Metrics.phone.minX, y: Metrics.phone.minY)
            Circle()
                .fill(ResoniqColor.signal)
                .frame(width: Metrics.dot * 2, height: Metrics.dot * 2)
                .offset(x: Metrics.dotCentre.x - Metrics.dot, y: Metrics.dotCentre.y - Metrics.dot)
            Circle()
                .stroke(ResoniqColor.signal, lineWidth: Metrics.ringStroke)
                .frame(width: Metrics.ring, height: Metrics.ring)
                .scaleEffect(ringExpanded ? Metrics.ringScale : 1)
                .opacity(ringExpanded ? 0 : Metrics.ringOpacity)
                .offset(x: Metrics.dotCentre.x - Metrics.ring / 2, y: Metrics.dotCentre.y - Metrics.ring / 2)

            // Labels.
            Text("≈ 30 cm")
                .font(Metrics.distanceFont)
                .foregroundStyle(ResoniqColor.ivory)
                .offset(x: Metrics.distanceOrigin.x, y: Metrics.distanceOrigin.y)
            Text("Bottom edge toward the speaker, level with its middle")
                .font(ResoniqFont.caption)
                .foregroundStyle(ResoniqColor.muted)
                .frame(width: Metrics.captionWidth, alignment: .leading)
                .offset(x: Metrics.captionOrigin.x, y: Metrics.captionOrigin.y)
            Text("Not heard yet")
                .resoniqCapsLabel()
                .offset(x: Metrics.statusOrigin.x, y: Metrics.statusOrigin.y)
        }
        // The drawing is a diagram laid out in fixed points: its text stops growing before it would overlap.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(ResoniqMotion.pulseRing) { ringExpanded = true }
        }
    }

    /// Positions from V3Start's illustration, in its 340 x 298 space.
    private enum Metrics {
        static let height: CGFloat = 300
        static let canvas = CGSize(width: 340, height: 298)
        static let axisY: CGFloat = 149
        /// The portrait and its ruler: the mockup's nested 170 x 440 drawing placed at (12, 18), 102 x 262.
        static let portrait = CGRect(x: 12, y: 18, width: 102, height: 262)
        static let measureStart: CGFloat = 124
        static let measureEnd: CGFloat = 196
        static let tick: CGFloat = 7
        static let measureStroke: CGFloat = 1.5
        static let phone = CGRect(x: 206, y: 125, width: 110, height: 48)
        static let phoneRadius: CGFloat = 12
        static let phoneStroke: CGFloat = 2.4
        static let dotCentre = CGPoint(x: 218, y: 149)
        static let dot: CGFloat = 4
        static let ring: CGFloat = 12
        static let ringStroke: CGFloat = 1.5
        static let ringScale: CGFloat = 2.6
        static let ringOpacity: Double = 0.7
        static let distanceOrigin = CGPoint(x: 134, y: 120)
        static let distanceFont = ResoniqFont.font(.monoRegular, size: 12, relativeTo: .caption)
        static let captionOrigin = CGPoint(x: 206, y: 184)
        static let captionWidth: CGFloat = 124
        static let statusOrigin = CGPoint(x: 206, y: 16)
    }
}

#if DEBUG
#Preview("Aim") {
    @Previewable @State var position = SpeakerPosition.left
    AimScreen(position: $position, onStart: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Aim, large type") {
    @Previewable @State var position = SpeakerPosition.right
    AimScreen(position: $position, onStart: {}, onClose: {})
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
#endif
