import SwiftUI

/// "Title rise" from the motion table: a new screen's headline comes up 12 pt over 0.5 s. With Reduce Motion
/// it is simply there.
private struct ResoniqTitleRise: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasRisen = false

    func body(content: Content) -> some View {
        content
            .offset(y: hasRisen || reduceMotion ? 0 : Metrics.distance)
            .onAppear {
                withAnimation(ResoniqMotion.enter) { hasRisen = true }
            }
    }

    private enum Metrics {
        static let distance: CGFloat = 12
    }
}

/// "Waiting dot" from the motion table: opacity between `low` and 1 over 1.2 s, while the app waits for the user
/// or the room. Still with Reduce Motion.
private struct ResoniqWaitingPulse: ViewModifier {
    let low: Double

    func body(content: Content) -> some View {
        LoopingPhase(isRunning: true, animation: ResoniqMotion.waiting) { phase, isActive in
            content.opacity(isActive && !phase ? low : 1)
        }
    }
}

public extension View {
    /// The headline group of a new screen rises into place.
    func resoniqTitleRise() -> some View { modifier(ResoniqTitleRise()) }

    /// Pulses between `low` and full opacity while on screen. V3Listening's "Hold still." uses 0.4, V3Paused's
    /// dot 0.35.
    func resoniqWaitingPulse(low: Double = 0.4) -> some View { modifier(ResoniqWaitingPulse(low: low)) }
}
