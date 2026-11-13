import ResoniqDesign
import SwiftUI

/// Measure home (design/screens/V3Measure.dc.html). Phase 0 builds the frame; phase 3 fills it.
struct MeasureHomeView: View {
    var context: ListeningContext = .placeholder

    var body: some View {
        TabHome(context: context) {
            EmptyView()
        } content: {
            Color.clear
        }
    }
}

#Preview {
    MeasureHomeView()
        .preferredColorScheme(.dark)
}
