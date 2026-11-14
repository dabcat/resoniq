import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Keeps the screen from locking while something that needs the phone left alone is on screen.
///
/// A measurement is hands-off: the phone is held still or set down while a sound plays, and the auto-lock would
/// otherwise stop it. Every flow that needs the screen on says so with `.keepsScreenAwake(while:)`; this object
/// counts those holds and sets `UIApplication.isIdleTimerDisabled` only when the first one begins and when the last
/// one ends, so nested or overlapping flows can neither leave it on nor turn it off early. Holds are identified, so
/// asking for one twice or giving one back twice counts once.
@MainActor
final class ScreenAwake {
    /// The one the app uses; it drives the system's idle timer.
    static let shared = ScreenAwake { isDisabled in
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = isDisabled
        #endif
    }

    private var holders: Set<UUID> = []
    private let apply: (Bool) -> Void

    /// - Parameter apply: Called with true when the first hold begins and false when the last one ends. Nothing else
    ///   is called, so a Mac build (previews) touches nothing.
    init(apply: @escaping (Bool) -> Void) {
        self.apply = apply
    }

    /// Whether anything is holding the screen on.
    var isHeld: Bool { !holders.isEmpty }

    func hold(_ id: UUID) {
        let wasHeld = isHeld
        holders.insert(id)
        if !wasHeld { apply(true) }
    }

    func release(_ id: UUID) {
        guard holders.remove(id) != nil, holders.isEmpty else { return }
        apply(false)
    }
}

extension EnvironmentValues {
    /// The screen-awake counter. A preview or a test can replace it with one that applies nothing.
    @Entry var screenAwake = ScreenAwake.shared
}

private struct KeepsScreenAwake: ViewModifier {
    let isActive: Bool
    @Environment(\.screenAwake) private var screenAwake
    @Environment(\.scenePhase) private var scenePhase
    @State private var id = UUID()

    /// Held only while the flow is active and the app is in the foreground, so leaving the foreground gives the
    /// screen back and returning to a flow that is still active takes it again.
    private var wantsHold: Bool { isActive && scenePhase == .active }

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            .onChange(of: wantsHold) { sync() }
            .onDisappear { screenAwake.release(id) }
    }

    private func sync() {
        if wantsHold { screenAwake.hold(id) } else { screenAwake.release(id) }
    }
}

extension View {
    /// Keeps the screen on for as long as `isActive` is true and this view is on screen in the foreground: a speaker
    /// test or seat measurement listening or playing, the live spectrum, the room scan, the AR guide. Given back when
    /// the flow ends, fails, is cancelled, the view goes or the app leaves the foreground.
    func keepsScreenAwake(while isActive: Bool = true) -> some View {
        modifier(KeepsScreenAwake(isActive: isActive))
    }
}
