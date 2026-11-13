import ResoniqDesign
import SwiftUI

/// Diagnose home (design/screens/V3Diagnose.dc.html). Phase 0 builds the frame; the portraits and the
/// "listen" action arrive with the Diagnose flow in phase 2.
struct DiagnoseHomeView: View {
    var body: some View {
        TabHome {
            // No target yet: Settings is built in phase 6.
            Button {} label: {
                ResoniqIconView(.settings)
            }
            .buttonStyle(ResoniqIconButtonStyle())
            .accessibilityLabel("Settings")
        } content: {
            Color.clear
        }
    }
}

#Preview {
    DiagnoseHomeView()
        .preferredColorScheme(.dark)
}
