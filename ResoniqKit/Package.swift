// swift-tools-version: 6.0
import PackageDescription

// One target per module in docs/ARCHITECTURE.md. macOS is listed so `swift test` runs on the Mac.
let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "ResoniqKit",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "ResoniqDesign", targets: ["ResoniqDesign"]),
        .library(name: "ResoniqDSP", targets: ["ResoniqDSP"]),
        .library(name: "ResoniqAudio", targets: ["ResoniqAudio"]),
        .library(name: "ResoniqDiagnostics", targets: ["ResoniqDiagnostics"]),
        .library(name: "ResoniqRoom", targets: ["ResoniqRoom"]),
        .library(name: "ResoniqStore", targets: ["ResoniqStore"]),
    ],
    targets: [
        .target(name: "ResoniqDesign", swiftSettings: swift6),
        .target(name: "ResoniqDSP", swiftSettings: swift6),
        .target(name: "ResoniqAudio", dependencies: ["ResoniqDSP"], swiftSettings: swift6),
        .target(name: "ResoniqDiagnostics", dependencies: ["ResoniqDSP"], swiftSettings: swift6),
        .target(name: "ResoniqRoom", swiftSettings: swift6),
        .target(name: "ResoniqStore", dependencies: ["ResoniqDiagnostics", "ResoniqRoom"], swiftSettings: swift6),
        .testTarget(name: "ResoniqDesignTests", dependencies: ["ResoniqDesign"], swiftSettings: swift6),
        .testTarget(name: "ResoniqDSPTests", dependencies: ["ResoniqDSP"], swiftSettings: swift6),
        .testTarget(name: "ResoniqAudioTests", dependencies: ["ResoniqAudio"], swiftSettings: swift6),
        .testTarget(name: "ResoniqDiagnosticsTests", dependencies: ["ResoniqDiagnostics"], swiftSettings: swift6),
        .testTarget(name: "ResoniqRoomTests", dependencies: ["ResoniqRoom"], swiftSettings: swift6),
        .testTarget(name: "ResoniqStoreTests", dependencies: ["ResoniqStore"], swiftSettings: swift6),
    ]
)
