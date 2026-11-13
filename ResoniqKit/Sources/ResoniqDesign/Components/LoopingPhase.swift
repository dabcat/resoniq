import SwiftUI

/// Runs a looping animation only while `isRunning` is true and Reduce Motion is off.
///
/// The content gets `phase`, which flips back and forth while the loop runs, and `isActive`, which says
/// whether it runs. Content shows its resting state when `isActive` is false, so nothing is hidden.
struct LoopingPhase<Content: View>: View {
    let isRunning: Bool
    let animation: Animation
    @ViewBuilder let content: (_ phase: Bool, _ isActive: Bool) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    private var isActive: Bool { isRunning && !reduceMotion }

    var body: some View {
        content(phase, isActive)
            .onChange(of: isActive, initial: true) { _, active in
                if active {
                    withAnimation(animation) { phase = true }
                } else {
                    // A plain animation replaces the repeating one, which stops the loop.
                    withAnimation(.linear(duration: 0)) { phase = false }
                }
            }
    }
}
