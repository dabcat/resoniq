#if DEBUG
import ResoniqDesign
import ResoniqRoom
import SwiftUI

/// The Scan screen in fixed states, for `make run SCREEN=<name>` and screenshots: `scan` is the scripted scan (the
/// simulator's stand-in for RoomPlan), then the denied, no-LiDAR and failed states. Debug builds only.
enum ScanDebugScreens {
    static let names = ["scan", "scan-denied", "scan-unsupported", "scan-failed"]

    @MainActor
    static func view(named name: String) -> AnyView? {
        switch name {
        case "scan":
            AnyView(ScriptedScanHost())
        case "scan-denied":
            AnyView(screen(readiness: .denied))
        case "scan-unsupported":
            AnyView(screen(readiness: .unsupported))
        case "scan-failed":
            AnyView(screen(readiness: .ready, phase: .failed(.worldTrackingFailure)))
        default:
            nil
        }
    }

    @MainActor
    private static func screen(readiness: ScanReadiness, phase: ScanPhase = .preparing) -> some View {
        ScanScreen(
            readiness: readiness, makeSource: { ScriptedRoomScanSource() }, phase: phase,
            onScanned: { _ in }, onManualEntry: {}, onClose: {})
            .preferredColorScheme(.dark)
    }
}

/// The scripted scan, then the room it finished with in place of the Confirm layout screen.
private struct ScriptedScanHost: View {
    @State private var result: RoomScanResult?

    var body: some View {
        if let result {
            VStack(spacing: ResoniqSpace.s3) {
                Text("Confirm layout goes here")
                    .font(ResoniqFont.title3)
                if let size = RoomGeometry.dimensions(of: result.room) {
                    Text(RoomText.dimensions(size))
                        .font(ResoniqFont.body)
                        .foregroundStyle(ResoniqColor.muted)
                }
                Button("Scan again") { self.result = nil }
                    .buttonStyle(ResoniqTextLinkStyle())
            }
            .foregroundStyle(ResoniqColor.ivory)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ResoniqColor.ink)
            .preferredColorScheme(.dark)
        } else {
            ScanScreen(
                readiness: .ready, makeSource: { ScriptedRoomScanSource() },
                onScanned: { result = $0 }, onManualEntry: {}, onClose: {})
                .preferredColorScheme(.dark)
        }
    }
}
#endif
