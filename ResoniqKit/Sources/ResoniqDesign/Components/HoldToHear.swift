import SwiftUI

/// The button that plays the offending frequency only while it is held (V3Finding): a 92 pt `signal`
/// circle with a speaker glyph and a ring that expands while the tone plays.
///
/// `onPressingChanged` is called with `true` when playing should start and `false` when it should stop, and
/// never twice in a row with the same value. Playing also stops if the button leaves the screen.
///
/// With VoiceOver, holding is awkward, so the default action toggles: double-tap to start, double-tap to stop.
public struct ResoniqHoldToHear: View {
    private let label: String
    private let onPressingChanged: (Bool) -> Void

    @State private var isHeld = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter accessibilityLabel: What it plays, e.g. "Hold to play 90 hertz through the left speaker".
    public init(accessibilityLabel: String = "Hold to hear it", onPressingChanged: @escaping (Bool) -> Void) {
        self.label = accessibilityLabel
        self.onPressingChanged = onPressingChanged
    }

    public var body: some View {
        ZStack {
            LoopingPhase(isRunning: isHeld, animation: ResoniqMotion.pulseRing) { phase, isActive in
                Circle()
                    .strokeBorder(ResoniqColor.signal, lineWidth: Metrics.ringWidth)
                    .scaleEffect(isActive && phase ? Metrics.ringScale : 1)
                    .opacity(isActive ? (phase ? 0 : Metrics.ringOpacity) : 0)
            }
            Circle()
                .fill(ResoniqColor.signal)
                .overlay {
                    ResoniqIconView(.speaker)
                        .foregroundStyle(ResoniqColor.onAction)
                }
                .scaleEffect(isHeld ? Metrics.heldScale : 1)
                .animation(reduceMotion ? nil : ResoniqMotion.press, value: isHeld)
        }
        .frame(width: Metrics.diameter, height: Metrics.diameter)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: Metrics.slop, perform: {}) { pressing in
            setHeld(pressing)
        }
        .sensoryFeedback(trigger: isHeld) { _, held in held ? .impact(weight: .medium) : nil }
        .onDisappear { setHeld(false) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isHeld ? "Playing" : "Stopped")
        .accessibilityHint("Double-tap to start playing, double-tap again to stop.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { setHeld(!isHeld) }
    }

    private func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
        isHeld = held
        onPressingChanged(held)
    }

    private enum Metrics {
        static let diameter: CGFloat = 92
        static let ringWidth: CGFloat = 2
        static let ringScale: CGFloat = 1.5
        static let ringOpacity: Double = 0.6
        /// V3Finding presses to 0.94, a firmer squeeze than the 0.97 of other buttons.
        static let heldScale: CGFloat = 0.94
        /// How far a finger may drift before the hold ends.
        static let slop: CGFloat = 60
    }
}

#Preview("Hold to hear") {
    @Previewable @State var playing = false
    HStack(spacing: ResoniqSpace.s5) {
        ResoniqHoldToHear(accessibilityLabel: "Hold to play 90 hertz through the left speaker") { playing = $0 }
        Text(playing ? "Playing" : "Silent")
            .font(ResoniqFont.headline)
            .foregroundStyle(ResoniqColor.ivory)
    }
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
