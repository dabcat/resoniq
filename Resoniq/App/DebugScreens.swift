#if DEBUG
import SwiftUI

/// One screen in a fixed state, by name, for `make run SCREEN=<name>` and screenshots.
enum DebugScreens {
    @MainActor
    static func view(named name: String) -> AnyView? {
        FlowDebugScreens.view(named: name) ?? ResultsDebugScreens.view(named: name)
    }
}
#endif
