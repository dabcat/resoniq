import ResoniqDesign
import ResoniqDiagnostics
import ResoniqStore
import SwiftData
import SwiftUI

/// Diagnose home (design/screens/V3Diagnose.dc.html): the portraits of the speakers of the selected system on
/// either side of a shared frequency ruler, each with its name and what was found, the most useful next test, and
/// the quick check.
///
/// A speaker with a result opens it; a speaker not heard yet starts its test (the caller decides which). A system with one speaker (a soundbar, a single speaker) shows one
/// portrait with the ruler beside it; there is no mockup for that, so it follows the design system's portrait and
/// the same screen frame.
struct DiagnoseHomeView: View {
    var context: ListeningContext = .placeholder
    private let speakers: [SpeakerSummary]
    private let primaryTitle: String
    private let onPrimary: () -> Void
    private let onOpenSpeaker: (SpeakerPosition) -> Void
    private let onQuickCheck: () -> Void
    private let onSettings: () -> Void

    /// Two speakers, left and right.
    init(
        context: ListeningContext = .placeholder,
        left: SpeakerSummary,
        right: SpeakerSummary,
        primaryTitle: String,
        onPrimary: @escaping () -> Void,
        onOpenSpeaker: @escaping (SpeakerPosition) -> Void,
        onQuickCheck: @escaping () -> Void,
        onSettings: @escaping () -> Void
    ) {
        self.init(
            context: context, speakers: [left, right], primaryTitle: primaryTitle, onPrimary: onPrimary,
            onOpenSpeaker: onOpenSpeaker, onQuickCheck: onQuickCheck, onSettings: onSettings
        )
    }

    /// One speaker: a soundbar or a single speaker.
    init(
        context: ListeningContext = .placeholder,
        single: SpeakerSummary,
        primaryTitle: String,
        onPrimary: @escaping () -> Void,
        onOpenSpeaker: @escaping (SpeakerPosition) -> Void,
        onQuickCheck: @escaping () -> Void,
        onSettings: @escaping () -> Void
    ) {
        self.init(
            context: context, speakers: [single], primaryTitle: primaryTitle, onPrimary: onPrimary,
            onOpenSpeaker: onOpenSpeaker, onQuickCheck: onQuickCheck, onSettings: onSettings
        )
    }

    private init(
        context: ListeningContext,
        speakers: [SpeakerSummary],
        primaryTitle: String,
        onPrimary: @escaping () -> Void,
        onOpenSpeaker: @escaping (SpeakerPosition) -> Void,
        onQuickCheck: @escaping () -> Void,
        onSettings: @escaping () -> Void
    ) {
        self.context = context
        self.speakers = speakers
        self.primaryTitle = primaryTitle
        self.onPrimary = onPrimary
        self.onOpenSpeaker = onOpenSpeaker
        self.onQuickCheck = onQuickCheck
        self.onSettings = onSettings
    }

    var body: some View {
        TabHome(context: context) {
            Button(action: onSettings) {
                ResoniqIconView(.settings)
            }
            .buttonStyle(ResoniqIconButtonStyle())
            .accessibilityLabel("Settings")
        } content: {
            VStack(spacing: ResoniqSpace.panelPadding) {
                // Whole page when it fits; the same page scrolling when the type is large.
                ViewThatFits(in: .vertical) {
                    portraitsPanel(fixedHeight: nil)
                    ScrollView {
                        portraitsPanel(fixedHeight: Metrics.scrollingPortraitHeight)
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(maxHeight: .infinity)

                VStack(spacing: 2) {
                    Button(primaryTitle, action: onPrimary)
                        .buttonStyle(ResoniqPrimaryButtonStyle())
                    Button(HomeText.quickCheck, action: onQuickCheck)
                        .buttonStyle(ResoniqTextLinkStyle())
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    // MARK: Portraits

    /// `fixedHeight` nil lets the portraits take whatever height is left.
    private func portraitsPanel(fixedHeight: CGFloat?) -> some View {
        VStack(spacing: ResoniqSpace.s3) {
            portraitRow
                .frame(minHeight: Metrics.smallestPortraitHeight, idealHeight: Metrics.smallestPortraitHeight)
                .frame(height: fixedHeight)
                .frame(maxHeight: fixedHeight == nil ? .infinity : nil)
            nameRow
        }
        .frame(maxWidth: .infinity)
        .resoniqPanel()
    }

    @ViewBuilder
    private var portraitRow: some View {
        if speakers.count == 2 {
            HStack(alignment: .top, spacing: ResoniqSpace.s1) {
                portrait(speakers[0])
                    .frame(maxWidth: .infinity)
                FrequencyRuler(.between)
                portrait(speakers[1])
                    .frame(maxWidth: .infinity)
            }
        } else if let only = speakers.first {
            HStack(alignment: .top, spacing: ResoniqSpace.s1) {
                FrequencyRuler(.beside)
                portrait(only)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func portrait(_ speaker: SpeakerSummary) -> some View {
        SpeakerPortrait(
            widths: speaker.profile.portraitWidths,
            state: speaker.profile.portraitStatus,
            deviations: speaker.profile.portraitDeviations,
            accessibilityLabel: speaker.portraitLabel
        )
        .frame(maxWidth: Metrics.portraitWidth)
        .contentShape(Rectangle())
        .onTapGesture { onOpenSpeaker(speaker.position) }
    }

    // MARK: Names

    @ViewBuilder
    private var nameRow: some View {
        if speakers.count == 2 {
            HStack(alignment: .top, spacing: ResoniqSpace.s1) {
                name(speakers[0])
                // The same width as the ruler between the portraits, so each name sits under its portrait.
                FrequencyRuler(.between)
                    .frame(height: 0)
                    .hidden()
                name(speakers[1])
            }
        } else if let only = speakers.first {
            name(only)
        }
    }

    @ViewBuilder
    private func name(_ speaker: SpeakerSummary) -> some View {
        let label = VStack(spacing: 2) {
            Text(speaker.name)
                .font(ResoniqFont.speakerName)
                .foregroundStyle(ResoniqColor.ivory)
            Text(speaker.status)
                .font(speaker.isDeviation ? ResoniqFont.captionSemibold : ResoniqFont.caption)
                .foregroundStyle(speaker.isDeviation ? ResoniqColor.signalText : ResoniqColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: ResoniqSize.touchMin)
        .contentShape(Rectangle())

        Button { onOpenSpeaker(speaker.position) } label: { label }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(speaker.name), \(speaker.status)")
            .accessibilityHint(speaker.hasResult ? "Opens the result" : "Starts listening to it")
            .accessibilityAddTraits(.isButton)
    }

    private enum Metrics {
        /// V3Diagnose draws each portrait 120 pt wide.
        static let portraitWidth: CGFloat = 120
        /// Below this the portraits stop shrinking and the page scrolls instead.
        static let smallestPortraitHeight: CGFloat = 200
        /// The portraits' height while the page scrolls.
        static let scrollingPortraitHeight: CGFloat = 280
    }
}

extension DiagnoseHomeView {
    /// The empty home, with nothing to open and no action behind its buttons: what the tab shows until the
    /// Diagnose flow is wired in.
    init() {
        self.init(
            left: .notHeard(.left, name: SpeakerPosition.left.displayName),
            right: .notHeard(.right, name: SpeakerPosition.right.displayName),
            primaryTitle: "Listen to the left speaker",
            onPrimary: {}, onOpenSpeaker: { _ in }, onQuickCheck: {}, onSettings: {}
        )
    }
}

// MARK: - From the store

/// The Diagnose home for the selected sound system, read from the store.
///
/// The latest test of each speaker comes from the model container in the environment, so the screen updates when
/// a test is kept. What each speaker shows, and which test the primary button offers, is decided by `HomePlan`.
struct DiagnoseHomeContainer: View {
    /// Starts a test of this speaker: the primary button.
    let onListen: (SpeakerPosition) -> Void
    /// A tap on a speaker's portrait or name: its result when it has one, else the caller starts its test.
    let onOpenSpeaker: (SpeakerPosition) -> Void
    let onQuickCheck: () -> Void
    let onSettings: () -> Void

    @Query private var states: [StoreState]
    @Query(sort: \Room.createdAt) private var rooms: [Room]
    @Query(sort: \SpeakerTest.date, order: .reverse) private var tests: [SpeakerTest]

    /// The selected system, else the first one of the oldest room that has one; nil before anything exists.
    private var system: SoundSystem? {
        states.first?.selectedSystem ?? rooms.lazy.compactMap { $0.orderedSystems.first }.first
    }

    var body: some View {
        let system = system
        let kind = system?.kind ?? .stereoPair
        let plan = HomePlan.make(kind: kind, latest: latest(in: system, kind: kind))
        let context = system.map { ListeningContext(room: $0.room?.name ?? StoreText.defaultRoomName, system: $0.name) }
            ?? ListeningContext(room: StoreText.defaultRoomName, system: StoreText.defaultSystemName)

        if plan.speakers.count == 1 {
            DiagnoseHomeView(
                context: context, single: plan.speakers[0], primaryTitle: plan.primaryTitle,
                onPrimary: { onListen(plan.next) }, onOpenSpeaker: onOpenSpeaker,
                onQuickCheck: onQuickCheck, onSettings: onSettings
            )
        } else {
            DiagnoseHomeView(
                context: context, left: plan.speakers[0], right: plan.speakers[1], primaryTitle: plan.primaryTitle,
                onPrimary: { onListen(plan.next) }, onOpenSpeaker: onOpenSpeaker,
                onQuickCheck: onQuickCheck, onSettings: onSettings
            )
        }
    }

    /// The newest readable test of each speaker the system shows. A test that cannot be read counts as not heard.
    private func latest(in system: SoundSystem?, kind: SoundSystemKind) -> [SpeakerPosition: HomePlan.Latest] {
        guard let system else { return [:] }
        var found: [SpeakerPosition: HomePlan.Latest] = [:]
        for position in HomePlan.positions(for: kind) {
            // `tests` is newest first.
            if let test = tests.first(where: { $0.system === system && $0.speaker == position && $0.report != nil }) {
                found[position] = HomePlan.Latest(date: test.date, report: test.report)
            }
        }
        return found
    }
}

#if DEBUG
#Preview("Left heard, right not") {
    DiagnoseHomeView(
        left: SpeakerSummary(position: .left, name: "Left", report: DiagnoseFixtures.buzzing),
        right: .notHeard(.right, name: "Right"),
        primaryTitle: "Listen to the right speaker",
        onPrimary: {}, onOpenSpeaker: { _ in }, onQuickCheck: {}, onSettings: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Nothing heard") {
    DiagnoseHomeView()
        .preferredColorScheme(.dark)
}

#Preview("Soundbar") {
    DiagnoseHomeView(
        single: SpeakerSummary(position: .single, name: "Soundbar", report: DiagnoseFixtures.healthy),
        primaryTitle: "Listen to the soundbar again",
        onPrimary: {}, onOpenSpeaker: { _ in }, onQuickCheck: {}, onSettings: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Largest text") {
    DiagnoseHomeView(
        left: SpeakerSummary(position: .left, name: "Left", report: DiagnoseFixtures.buzzing),
        right: .notHeard(.right, name: "Right"),
        primaryTitle: "Listen to the right speaker",
        onPrimary: {}, onOpenSpeaker: { _ in }, onQuickCheck: {}, onSettings: {}
    )
    .dynamicTypeSize(.accessibility2)
    .preferredColorScheme(.dark)
}
#endif
