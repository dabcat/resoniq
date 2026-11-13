import ResoniqDesign
import SwiftUI

/// Sit and aim (design/screens/V3MGuide.dc.html): where to sit, the top view of both speakers playing toward the
/// sofa with the three spots (the middle one first), three short instructions and "I'm seated, start".
struct SitAndAimScreen: View {
    /// The room's name, for the line at the top: "Measure · Living room".
    let room: String
    var onStart: () -> Void
    var onBack: () -> Void

    var body: some View {
        FlowScaffold {
            HStack(spacing: ResoniqSpace.s3) {
                Button(action: onBack) {
                    ResoniqIconView(.back)
                }
                .buttonStyle(ResoniqIconButtonStyle())
                .accessibilityLabel("Back")
                Text("Measure · \(room)")
                    .resoniqCapsLabel()
                    .fixedSize(horizontal: false, vertical: true)
            }
        } content: {
            VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
                VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
                    Text("Sit where you always listen.")
                        .resoniqTitle(.large)
                        .accessibilityAddTraits(.isHeader)
                    Text("I'll measure at your head, then a little to each side, so one odd spot can't fool us.")
                        .font(ResoniqFont.bodyLarge)
                        .foregroundStyle(ResoniqColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .resoniqTitleRise()

                SpotsDiagram(.guide, accessibilityLabel: MeasureText.guideDiagramLabel)
                    .resoniqPanel(insets: EdgeInsets())

                VStack(spacing: 0) {
                    ResoniqNumberedStep(1, "Phone at ear height, screen facing the ceiling")
                    ResoniqNumberedStep(2, "Volume where you normally keep it", showsSeparator: true)
                    ResoniqNumberedStep(3, "Stay quiet while the tones play", showsSeparator: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            Button("I'm seated, start", action: onStart)
                .buttonStyle(ResoniqPrimaryButtonStyle())
        }
        .accessibilityAction(.escape, onBack)
    }
}

#if DEBUG
#Preview("Sit and aim") {
    SitAndAimScreen(room: "Living room", onStart: {}, onBack: {})
        .preferredColorScheme(.dark)
}

#Preview("Sit and aim, large type") {
    SitAndAimScreen(room: "Living room", onStart: {}, onBack: {})
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
#endif
