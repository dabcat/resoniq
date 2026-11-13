import ResoniqDesign
import SwiftUI

/// Optimize home (design/screens/V3Optimize.dc.html). Phase 0 builds the frame; phase 4 fills it.
/// The switcher is flipped here because the room is the subject.
struct OptimizeHomeView: View {
    var body: some View {
        TabHome(switcherOrder: .systemOverRoom) {
            EmptyView()
        } content: {
            Color.clear
        }
    }
}

#Preview {
    OptimizeHomeView()
        .preferredColorScheme(.dark)
}
