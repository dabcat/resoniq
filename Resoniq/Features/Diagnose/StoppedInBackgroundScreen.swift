import ResoniqDesign
import SwiftUI

/// What a measurement says when Resoniq left the foreground while it listened or played (the lock button, a call, the
/// app switcher). Static copy with no Kit counterpart: the Kit's `interrupted` sentence is about another app taking
/// the sound, which is not what happened here.
enum StoppedText {
    static let headline = "I stopped because Resoniq went to the background."
    static let body = "I can only play and listen while Resoniq is open on the screen, so I stopped. "
        + "Nothing from this measurement was kept. Start again when you're ready, and keep Resoniq open until it's done."
    static let start = "Start again"
}

/// The screen a flow shows when the app went to the background mid-measurement, in place of quietly returning to its
/// first screen. No mockup; it follows the other failure screens (design/DESIGN_SYSTEM.md): the flow's frame, a
/// headline and a sentence, "Start again" and "Not now". Shared by the four listening flows (a speaker test or the
/// seat, played by the phone or by another device).
struct StoppedInBackgroundScreen: View {
    var onStartAgain: () -> Void
    var onClose: () -> Void

    var body: some View {
        FlowScaffold {
            Text("Resoniq")
                .font(ResoniqFont.headline)
                .foregroundStyle(ResoniqColor.ivory)
        } content: {
            MeasureMessage(headline: StoppedText.headline, message: StoppedText.body) { EmptyView() }
                .padding(.top, ResoniqSpace.s6)
        } footer: {
            VStack(spacing: ResoniqSpace.s1) {
                Button(StoppedText.start, action: onStartAgain)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
                Button("Not now", action: onClose)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
        }
        // The screen takes over from a running one: VoiceOver reads what happened, not just "screen changed".
        .onAppear { AccessibilityNotification.Announcement("\(StoppedText.headline) \(StoppedText.body)").post() }
        .accessibilityAction(.escape, onClose)
    }
}

#if DEBUG
#Preview("Stopped in the background") {
    StoppedInBackgroundScreen(onStartAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Stopped in the background, large type") {
    StoppedInBackgroundScreen(onStartAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
#endif
