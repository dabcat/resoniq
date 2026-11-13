#if DEBUG
import ResoniqRoom
import SwiftUI

/// The AR guide in fixed states, for `make run SCREEN=<name>` and screenshots, all on the scripted source (the
/// simulator's stand-in for ARKit): `ar` slides to V3OAR's 18 cm to go, then the floor search, the first mark, the
/// second mark (the other speaker), marks that do not agree with the plan, the turn, the arrival (a move without a
/// turn) and tracking limited mid-slide. Debug builds only.
enum ARDebugScreens {
    static let names = [
        "ar", "ar-floor", "ar-mark", "ar-mark-second", "ar-disagree", "ar-turn", "ar-arrived", "ar-limited",
    ]

    @MainActor
    static func view(named name: String) -> AnyView? {
        switch name {
        case "ar": AnyView(screen(.slide))
        case "ar-floor": AnyView(screen(.findFloor))
        case "ar-mark": AnyView(screen(.mark))
        case "ar-mark-second": AnyView(screen(.markSecond))
        case "ar-disagree": AnyView(screen(.disagree))
        case "ar-turn": AnyView(screen(.turn))
        case "ar-arrived": AnyView(screen(.arrive, turnDegrees: 0))
        case "ar-limited": AnyView(screen(.limited))
        default: nil
        }
    }

    @MainActor
    private static func screen(_ script: ScriptedARGuidanceSource.Script, turnDegrees: Double = 12) -> some View {
        let sample = ARGuidanceSample.rightSpeaker(turnDegrees: turnDegrees)
        return ARGuidanceScreen(
            suggestion: sample.suggestion, room: sample.room, readiness: .ready,
            source: ScriptedARGuidanceSource(script: script), onPlaced: { _ in }, onDeclined: {}, onClose: {})
            .preferredColorScheme(.dark)
    }
}
#endif
