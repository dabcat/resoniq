import SwiftUI

/// A live value: caps label, a large mono number, its unit in sans, and an optional line of detail
/// (V3Listening "Playing now", V3Paused "Room noise"). Wrap it in `.resoniqPanel()` where the mockup does.
///
/// The value turns `signalText` only while `isOutOfRange` is true. Colour is not the only cue: VoiceOver says
/// "out of range", and the caller's detail line says why.
public struct ResoniqReadout: View {
    public enum Size: Sendable {
        /// 46 pt, the main reading of a screen.
        case large
        /// 34 pt, a reading beside other content.
        case medium
    }

    private let label: String
    private let value: String
    private let unit: String?
    private let detail: String?
    private let size: Size
    private let isOutOfRange: Bool
    private let level: ResoniqLevelBar?

    public init(
        label: String,
        value: String,
        unit: String? = nil,
        detail: String? = nil,
        size: Size = .large,
        isOutOfRange: Bool = false,
        level: ResoniqLevelBar? = nil
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.detail = detail
        self.size = size
        self.isOutOfRange = isOutOfRange
        self.level = level
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Text(label)
                .resoniqCapsLabel()
            HStack(alignment: .firstTextBaseline, spacing: Metrics.unitGap) {
                Text(value)
                    .font(size == .large ? ResoniqFont.readoutLarge : ResoniqFont.readoutMedium)
                    .tracking((size == .large ? Metrics.largeSize : Metrics.mediumSize) * ResoniqFont.Tracking.readout)
                    .foregroundStyle(isOutOfRange ? ResoniqColor.signalText : ResoniqColor.ivory)
                    .lineLimit(1)
                    .minimumScaleFactor(Metrics.minimumScale)
                if let unit {
                    Text(unit)
                        .font(Metrics.unitFont)
                        .foregroundStyle(ResoniqColor.ivory)
                }
            }
            if let level {
                level
                    .padding(.top, Metrics.gap)
            }
            if let detail {
                Text(detail)
                    .font(ResoniqFont.caption)
                    .foregroundStyle(ResoniqColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: String {
        var parts = [[value, unit].compactMap { $0 }.joined(separator: " ")]
        if isOutOfRange { parts.append("out of range") }
        if let detail { parts.append(detail) }
        if let level { parts.append(level.caption) }
        return parts.joined(separator: ", ")
    }

    private enum Metrics {
        static let gap: CGFloat = 4
        static let unitGap: CGFloat = 6
        static let largeSize: CGFloat = 46
        static let mediumSize: CGFloat = 34
        static let minimumScale: CGFloat = 0.6
        /// The unit beside a large value is 17 pt semibold in V3Listening.
        static let unitFont = ResoniqFont.font(.sansSemibold, size: 17, relativeTo: .headline)
    }
}

/// A bar for a level against a mark, as under the room-noise value in V3Paused: the fill runs from the left,
/// the mark is a thin `ivory` line. The fill is `lime` up to the mark and `signal` beyond it, and `caption`
/// says in words which side is fine ("Quiet enough left of the mark").
public struct ResoniqLevelBar: View {
    /// 0...1 of the bar's width.
    public let level: Double
    /// 0...1 of the bar's width.
    public let mark: Double
    public let caption: String

    public init(level: Double, mark: Double, caption: String) {
        self.level = level
        self.mark = mark
        self.caption = caption
    }

    private var isBeyondMark: Bool { level > mark }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.captionGap) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ResoniqColor.line)
                        .frame(height: Metrics.trackHeight)
                    Capsule()
                        .fill(isBeyondMark ? ResoniqColor.signal : ResoniqColor.lime)
                        .frame(width: width * clamp(level), height: Metrics.trackHeight)
                    Rectangle()
                        .fill(ResoniqColor.ivory)
                        .frame(width: Metrics.markWidth, height: Metrics.height)
                        .offset(x: width * clamp(mark) - Metrics.markWidth / 2)
                }
                .frame(height: Metrics.height)
            }
            .frame(height: Metrics.height)
            Text(caption)
                .font(ResoniqFont.caption)
                .foregroundStyle(ResoniqColor.muted)
        }
        .accessibilityHidden(true)
    }

    private func clamp(_ value: Double) -> CGFloat {
        CGFloat(min(max(value.isNaN ? 0 : value, 0), 1))
    }

    private enum Metrics {
        static let height: CGFloat = 22
        static let trackHeight: CGFloat = 8
        static let markWidth: CGFloat = 2
        static let captionGap: CGFloat = 4
    }
}

#Preview("Readouts") {
    VStack(spacing: ResoniqSpace.s3) {
        ResoniqReadout(label: "Playing now", value: "1.02", unit: "kHz", detail: "Middle driver", isOutOfRange: true)
            .resoniqPanel()
        ResoniqReadout(label: "Playing now", value: "90", unit: "Hz")
            .resoniqPanel()
        ResoniqReadout(
            label: "Room noise", value: "52 dB", size: .medium, isOutOfRange: true,
            level: ResoniqLevelBar(level: 0.78, mark: 0.55, caption: "Quiet enough left of the mark")
        )
        .resoniqPanel()
    }
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
