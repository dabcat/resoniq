import AVFoundation
import Foundation
import ResoniqRoom
#if canImport(RoomPlan) && !targetEnvironment(simulator)
import RoomPlan
#endif

/// The device side of "can we scan": LiDAR from RoomPlan, the camera permission from AVFoundation, and which
/// source drives the scan. The decision itself is `ScanReadiness` in the Kit.
///
/// RoomPlan cannot run in the simulator (`RoomCaptureSession.isSupported` is false there), so the simulator, and
/// the previews that run on it, always get the scripted scan and are treated as ready.
enum ScanCapability {
    static func readiness() -> ScanReadiness {
        #if canImport(RoomPlan) && !targetEnvironment(simulator)
        ScanReadiness(isSupported: RoomCaptureSession.isSupported, camera: cameraPermission())
        #else
        .ready
        #endif
    }

    static func cameraPermission() -> CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    /// Shows the system prompt the first time; afterwards it returns the answer already given.
    static func requestCamera() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
    }

    static func makeSource() -> any RoomScanSource {
        #if canImport(RoomPlan) && !targetEnvironment(simulator)
        LiveRoomScanSource()
        #else
        ScriptedRoomScanSource()
        #endif
    }
}
