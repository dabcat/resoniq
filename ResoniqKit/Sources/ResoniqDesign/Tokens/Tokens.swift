// Written by hand from design/tokens.json (version 0.2). Keep the two in sync.
// Typography is in Typography.swift.

import SwiftUI

public extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

public enum ResoniqColor {
    public static let ink = Color(hex: 0x151412)
    public static let panel = Color(hex: 0x1F1D1A)
    public static let panelRaised = Color(hex: 0x2E2B26)
    public static let line = Color(hex: 0x3B3731)
    public static let ivory = Color(hex: 0xF0EBE1)
    public static let muted = Color(hex: 0xA9A398)
    public static let lime = Color(hex: 0xD8F27A)
    public static let teal = Color(hex: 0x37C8C0)
    public static let indigo = Color(hex: 0x5B6CFF)
    public static let signal = Color(hex: 0xFF5B2E)
    public static let signalText = Color(hex: 0xFF8157)
    public static let guide = Color(hex: 0x9CC9E8)
    public static let disabled = Color(hex: 0x6B665D)

    // Semantic aliases
    public static let action = lime
    public static let onAction = ink
    public static let deviation = signal
    public static let suggestion = guide
    public static let improved = lime
}

public enum ResoniqGradient {
    private static let stops: [Gradient.Stop] = [
        .init(color: ResoniqColor.indigo, location: 0),
        .init(color: ResoniqColor.teal, location: 0.55),
        .init(color: ResoniqColor.lime, location: 1),
    ]

    /// Bass at the bottom, treble at the top. For speaker portraits.
    public static let frequencyVertical = LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)

    /// Bass on the left, treble on the right. For response curves.
    public static let frequencyHorizontal = LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
}

public enum ResoniqSpace {
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 20
    public static let s6: CGFloat = 24
    public static let screenInset: CGFloat = 24
    public static let panelPadding: CGFloat = 14
}

public enum ResoniqRadius {
    public static let segment: CGFloat = 10
    public static let control: CGFloat = 14
    public static let panel: CGFloat = 18
    public static let sheet: CGFloat = 28
}

public enum ResoniqSize {
    public static let touchMin: CGFloat = 44
    public static let buttonHeight: CGFloat = 58
    public static let segmentHeight: CGFloat = 44
    public static let tabItemHeight: CGFloat = 60
    public static let iconButton: CGFloat = 44
    public static let strokeHairline: CGFloat = 1
    public static let strokeTrace: CGFloat = 3
    public static let strokeWall: CGFloat = 3
}

public enum ResoniqMotion {
    public static let press = Animation.spring(response: 0.2, dampingFraction: 0.7)
    public static let settle = Animation.spring(response: 0.6, dampingFraction: 0.65)
    public static let sheet = Animation.spring(response: 0.45, dampingFraction: 0.85)
    public static let pop = Animation.spring(response: 0.35, dampingFraction: 0.6)
    public static let enter = Animation.easeOut(duration: 0.5)
    public static let traceDraw = Animation.easeOut(duration: 1.6)
    public static let waiting = Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true)
    public static let pulseRing = Animation.easeOut(duration: 1.8).repeatForever(autoreverses: false)
    /// Sweep line hovering at the current frequency: loop.scan, a 1.2 s period, so 0.6 s each way.
    public static let scan = Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true)
    /// A deviating zone trembling: loop.buzz, a 0.09 s period.
    public static let buzz = Animation.linear(duration: 0.045).repeatForever(autoreverses: true)

    /// Distance of the sweep line's hover, in points, each way.
    public static let scanDistance: CGFloat = 4
    /// Distance of the tremble, in points, each way.
    public static let buzzDistance: CGFloat = 1.4

    /// Scale of a pressed button or row.
    public static let pressedScale: CGFloat = 0.97
}
