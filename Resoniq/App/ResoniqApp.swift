import ResoniqDesign
import SwiftUI

@main
struct ResoniqApp: App {
    /// Nil when the store could not be opened.
    @State private var composition: AppComposition?

    init() {
        ResoniqFont.registerBundledFonts()
        _composition = State(initialValue: AppComposition.launch())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let composition {
                    RootView()
                        .appEnvironment(composition)
                } else {
                    StoreUnavailableScreen()
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
