import ResoniqDesign
import SwiftUI

@main
struct ResoniqApp: App {
    init() {
        ResoniqFont.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}
