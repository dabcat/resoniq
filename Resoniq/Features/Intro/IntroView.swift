import ResoniqDesign
import SwiftUI

/// How the intro ended.
enum IntroOutcome: Equatable {
    /// The third screen's "Try it on a speaker": straight into the first test.
    case tryOnSpeaker
    /// "Skip intro", on any page.
    case skipped
}

/// The three intro screens (design/screens/V3Onb1 to V3Onb3): what the app does, shown with the real
/// visualisations. Swipe or press the button; "Skip intro" is on every page. The caller marks the intro finished
/// (`IntroGate.finish()`) when `onFinished` is called, whatever the outcome.
struct IntroView: View {
    var onFinished: (IntroOutcome) -> Void

    @State private var page: Int
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter page: 0-based; the debug entries open on a later page.
    init(startingAtPage page: Int = 0, onFinished: @escaping (IntroOutcome) -> Void) {
        _page = State(initialValue: min(max(page, 0), IntroText.pages.count - 1))
        self.onFinished = onFinished
    }

    private var isLast: Bool { page == IntroText.pages.count - 1 }

    var body: some View {
        VStack(spacing: Metrics.gap) {
            header
            TabView(selection: $page) {
                ForEach(IntroText.pages.indices, id: \.self) { index in
                    IntroPageView(index: index, isVisible: index == page && scenePhase == .active)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            footer
        }
        .padding(.horizontal, ResoniqSpace.screenInset)
        .padding(.top, ResoniqSpace.s2)
        .padding(.bottom, ResoniqSpace.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ResoniqColor.ink)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text(IntroText.counter(page + 1))
                .font(Metrics.counterFont)
                .foregroundStyle(ResoniqColor.muted)
                .accessibilityHidden(true)
            Spacer()
            Button(IntroText.skip) { onFinished(.skipped) }
                .buttonStyle(ResoniqTextLinkStyle())
        }
        .frame(minHeight: ResoniqSize.touchMin)
    }

    private var footer: some View {
        HStack(spacing: Metrics.footerGap) {
            PageIndicator(count: IntroText.pages.count, current: page) { page = $0 }
            Button(isLast ? IntroText.tryOnSpeaker : IntroText.next, action: advance)
                .buttonStyle(ResoniqPrimaryButtonStyle())
        }
    }

    private func advance() {
        if isLast {
            onFinished(.tryOnSpeaker)
        } else if reduceMotion {
            page += 1
        } else {
            withAnimation(ResoniqMotion.sheet) { page += 1 }
        }
    }

    private enum Metrics {
        static let gap: CGFloat = 18
        static let footerGap: CGFloat = 16
        static let counterFont = ResoniqFont.font(.monoRegular, size: 13, relativeTo: .footnote)
    }
}

// MARK: - Page indicator

/// Three dots, the current one a long pill; the width says where you are as well as the colour. One adjustable
/// element for VoiceOver.
private struct PageIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let count: Int
    let current: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: Metrics.gap) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(color(for: index))
                    .frame(width: index == current ? Metrics.currentWidth : Metrics.dot, height: Metrics.dot)
            }
        }
        .frame(width: Metrics.width, alignment: .leading)
        .animation(reduceMotion ? nil : ResoniqMotion.press, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(IntroText.pageIndicator)
        .accessibilityValue(IntroText.pageValue(current + 1))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(min(current + 1, count - 1))
            case .decrement: select(max(current - 1, 0))
            @unknown default: break
            }
        }
    }

    /// The pages seen, the page you are on, the pages to come.
    private func color(for index: Int) -> Color {
        if index == current { return ResoniqColor.ivory }
        return index < current ? ResoniqColor.muted : ResoniqColor.line
    }

    private enum Metrics {
        static let dot: CGFloat = 6
        static let currentWidth: CGFloat = 26
        static let gap: CGFloat = 6
        static let width: CGFloat = 84
    }
}

// MARK: - A page

/// One page: the illustration in its panel, then the kicker, headline and sentence. It scrolls when the text
/// is too large to fit.
private struct IntroPageView: View {
    let index: Int
    let isVisible: Bool

    private var page: IntroText.Page { IntroText.pages[index] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                illustration
                VStack(alignment: .leading, spacing: Metrics.textGap) {
                    Text(page.kicker)
                        .font(Metrics.kickerFont)
                        .tracking(Metrics.kickerSize * ResoniqFont.Tracking.capsLabel)
                        .textCase(.uppercase)
                        .foregroundStyle(kickerColor)
                    Text(page.headline)
                        .resoniqTitle(.large)
                        .accessibilityAddTraits(.isHeader)
                    Text(page.body)
                        .font(ResoniqFont.bodyLarge)
                        .foregroundStyle(ResoniqColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var illustration: some View {
        switch index {
        case 0: DiagnoseIllustration(isVisible: isVisible)
        case 1: MeasureIllustration(isVisible: isVisible)
        default: OptimizeIllustration(isVisible: isVisible)
        }
    }

    /// Diagnose in the deviation's text colour, Measure quiet, Optimize in the guide colour.
    private var kickerColor: Color {
        switch index {
        case 0: ResoniqColor.signalText
        case 1: ResoniqColor.muted
        default: ResoniqColor.guide
        }
    }

    private enum Metrics {
        static let gap: CGFloat = 18
        static let textGap: CGFloat = 10
        static let kickerSize: CGFloat = 12
        static let kickerFont = ResoniqFont.font(.monoRegular, size: kickerSize, relativeTo: .caption)
    }
}

#Preview("Intro, Diagnose") {
    IntroView { _ in }
}

#Preview("Intro, Measure") {
    IntroView(startingAtPage: 1) { _ in }
}

#Preview("Intro, Optimize") {
    IntroView(startingAtPage: 2) { _ in }
}

#Preview("Intro, largest text") {
    IntroView(startingAtPage: 2) { _ in }
        .dynamicTypeSize(.accessibility2)
}
