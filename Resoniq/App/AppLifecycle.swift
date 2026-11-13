import Foundation
import SwiftUI

/// The one place that stops sound when the app leaves the foreground.
///
/// Whatever can play or record (a speaker test, a seat measurement, a tone, the live spectrum) registers a handler
/// once, when its coordinator is made. `RootView` calls `sceneLeftForeground()` when the scene is no longer active:
/// a call, the lock button, the app switcher or another app. Each handler must be safe in any state (the audio
/// module's `cancel()` and `stop()` are).
@MainActor
final class AppLifecycle {
    private var handlers: [() -> Void] = []

    /// Registers something to run each time the scene leaves the foreground.
    func onLeavingForeground(_ handler: @escaping () -> Void) {
        handlers.append(handler)
    }

    /// The scene is inactive or in the background: stop everything that makes or listens to sound.
    func sceneLeftForeground() {
        for handler in handlers { handler() }
    }
}

extension EnvironmentValues {
    /// The app's lifecycle hook. Nil in previews that skip the composition.
    @Entry var appLifecycle: AppLifecycle?
}
