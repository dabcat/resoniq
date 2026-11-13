import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqStore
import SwiftUI

/// The Diagnose tab: home, and over it, without the tab bar, the full-screen cover that holds a test, a result and
/// the findings pushed from it. `DiagnoseCoordinator` decides what is shown; this only lays it out.
struct DiagnoseTab: View {
    @Environment(DiagnoseCoordinator.self) private var coordinator
    @Environment(\.systemsChanged) private var systemsChanged
    @State private var showsSettings = false

    var body: some View {
        DiagnoseHomeContainer(
            onListen: { coordinator.startTest($0) },
            onOpenSpeaker: coordinator.openSpeaker,
            onQuickCheck: coordinator.startQuickCheck,
            onSettings: { showsSettings = true }
        )
        // A sheet: Settings is a side trip from an icon button, and it draws its own header with "Done". "Delete
        // everything" recreates the default room and system, so closing it refreshes what belongs to the system.
        .sheet(isPresented: $showsSettings, onDismiss: { systemsChanged() }) {
            SettingsScreen(onClose: { showsSettings = false })
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { coordinator.content != nil },
                set: { if !$0 { coordinator.close() } }
            )
        ) {
            DiagnoseCover()
        }
    }
}

// MARK: - The cover

/// One navigation stack with a typed path. Its root is the test (Aim to Result), a kept result, or the note about a
/// result that cannot be read. The system navigation bar stays hidden: the screens draw their own headers.
private struct DiagnoseCover: View {
    @Environment(DiagnoseCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        NavigationStack(path: $coordinator.path) {
            root
                .toolbarVisibility(.hidden, for: .navigationBar)
                .navigationDestination(for: DiagnoseCoordinator.Route.self) { route in
                    switch route {
                    case .finding(let index):
                        finding(at: index)
                            .toolbarVisibility(.hidden, for: .navigationBar)
                    }
                }
        }
        .background(ResoniqColor.ink)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var root: some View {
        switch coordinator.content {
        case .test(let flow):
            TestRoot(flow: flow)
                .id(coordinator.contentID)
        case .external(let flow):
            ExternalTestRoot(flow: flow)
                .id(coordinator.contentID)
        case .stored:
            ResultRoot()
                .id(coordinator.contentID)
        case .unreadable(let position):
            UnreadableResultScreen(
                onTestAgain: { coordinator.testAgain(position) },
                onClose: coordinator.close
            )
            .id(coordinator.contentID)
        case nil:
            // The cover is on its way out.
            ResoniqColor.ink.ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func finding(at index: Int) -> some View {
        if let outcome = coordinator.outcome, outcome.report.findings.indices.contains(index) {
            FindingHost(
                finding: outcome.report.findings[index], report: outcome.report, speaker: outcome.position,
                makeTone: coordinator.makeTonePlayer, onClose: coordinator.closeFinding
            )
        }
    }
}

/// Holds the tone player for as long as the finding is on screen: the destination closure runs again whenever the
/// path or the state changes, and a new player each time would cut the tone off.
private struct FindingHost: View {
    let finding: Finding
    let report: SpeakerReport
    let speaker: SpeakerPosition
    let onClose: () -> Void
    @State private var tone: LazyTonePlayer

    init(
        finding: Finding, report: SpeakerReport, speaker: SpeakerPosition,
        makeTone: @escaping () -> any FindingTonePlaying, onClose: @escaping () -> Void
    ) {
        self.finding = finding
        self.report = report
        self.speaker = speaker
        self.onClose = onClose
        _tone = State(initialValue: LazyTonePlayer(make: makeTone))
    }

    var body: some View {
        FindingScreen(
            finding: finding, report: report, speaker: speaker, tone: tone, onClose: onClose,
            onShowNumbers: {}
        )
    }
}

/// Makes the real player the first time a tone is wanted, so building the screen opens no audio.
@Observable
private final class LazyTonePlayer: FindingTonePlaying {
    @ObservationIgnored private let make: () -> any FindingTonePlaying
    private var player: (any FindingTonePlaying)?

    init(make: @escaping () -> any FindingTonePlaying) {
        self.make = make
    }

    var failure: TonePlayerError? { player?.failure }
    var endedByItself: Int { player?.endedByItself ?? 0 }

    func start(frequency: Double, on channel: SpeakerChannel) {
        let player = player ?? make()
        self.player = player
        player.start(frequency: frequency, on: channel)
    }

    func stop() { player?.stop() }
}

// MARK: - Roots

/// A test: the flow's screens, and its result when it finishes.
private struct TestRoot: View {
    let flow: DiagnoseFlow
    @Environment(DiagnoseCoordinator.self) private var coordinator

    var body: some View {
        DiagnoseFlowView(flow: flow, onClose: coordinator.close, onExternal: { coordinator.switchToExternal(from: flow) }) { _ in
            ResultRoot()
        }
        .onChange(of: flow.step) { _, step in
            if case .finished(let completed) = step { coordinator.testFinished(completed) }
        }
        // VoiceOver starts at the top of each new screen of the flow.
        .onChange(of: flow.step.screen) { old, new in
            if old == .paused, new == .listening {
                // A run carrying on is a change worth hearing: say it instead of only moving focus.
                AccessibilityNotification.Announcement("The room is quiet again. Carrying on.").post()
            } else if new != .finished {
                // The Result screen puts VoiceOver on its verdict itself.
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
        }
        #if DEBUG
        .task(id: flow.step.screen) { await autostartIfAsked() }
        #endif
    }

    #if DEBUG
    /// `-autostart YES` presses "Start listening" one second after Aim appears, so an unattended launch runs a
    /// whole test to the Result screen.
    private func autostartIfAsked() async {
        guard UserDefaults.standard.bool(forKey: "autostart"), case .aim = flow.step else { return }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, case .aim = flow.step else { return }
        flow.start()
    }
    #endif
}

/// A test whose sound another device plays: the flow's screens, and its result when it finishes. The counterpart of
/// `TestRoot`; the result is the same `ResultRoot`.
private struct ExternalTestRoot: View {
    let flow: ExternalDiagnoseFlow
    @Environment(DiagnoseCoordinator.self) private var coordinator

    var body: some View {
        ExternalDiagnoseFlowView(flow: flow, onClose: coordinator.close) { _ in
            ResultRoot()
        }
        .onChange(of: flow.step) { _, step in
            if case .finished(let completed) = step { coordinator.testFinished(completed) }
        }
        // VoiceOver starts at the top of each new screen of the flow; what changes inside the listening screen
        // announces itself.
        .onChange(of: flow.step.screen) { _, new in
            if new != .finished { UIAccessibility.post(notification: .screenChanged, argument: nil) }
        }
        #if DEBUG
        .task(id: flow.step.screen) { await autostartIfAsked() }
        #endif
    }

    #if DEBUG
    /// `-autostart YES` presses "I have the file" one second after the files appear; the simulated player then presses
    /// play by itself (`simulatedPlayer`), so an unattended launch runs a whole test to the Result screen.
    private func autostartIfAsked() async {
        guard UserDefaults.standard.bool(forKey: "autostart"), case .files = flow.step else { return }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, case .files = flow.step else { return }
        flow.start()
    }
    #endif
}

/// The Result screen of `coordinator.outcome`, with the rename alert.
private struct ResultRoot: View {
    @Environment(DiagnoseCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        if let outcome = coordinator.outcome {
            ResultScreen(
                report: outcome.report,
                speaker: outcome.position,
                keptIn: coordinator.keptIn,
                phoneMovedNote: ReadingText.phoneMovedNote(runs: outcome.movedRuns),
                sourceNote: DiagnosisText.sourceNote(outcome.report.source),
                primaryTitle: outcome.next.title,
                onPrimary: coordinator.primary,
                onOpenFinding: coordinator.openFinding,
                onRename: coordinator.beginRename,
                onDontKeep: coordinator.dontKeep,
                onClose: coordinator.close
            )
            .alert("Rename this system", isPresented: $coordinator.isRenaming) {
                TextField("System name", text: $coordinator.renameDraft)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { coordinator.commitRename() }
            } message: {
                Text("Its name shows at the top of every tab.")
            }
        } else {
            // The test has finished and the result is being kept: one frame.
            ResoniqColor.ink.ignoresSafeArea()
        }
    }
}

// MARK: - A result that cannot be read

/// A kept result that can no longer be read. There is no mockup for it; it follows the design system's plain
/// screen: a title, one sentence, the primary action and a way back.
struct UnreadableResultScreen: View {
    let onTestAgain: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
            Spacer(minLength: 0)
            Text("I can't open this result.")
                .resoniqTitle(.medium)
                .accessibilityAddTraits(.isHeader)
            Text("The saved file is damaged or from a version I don't know. Listen to the speaker again and I'll make a fresh one.")
                .font(ResoniqFont.body)
                .foregroundStyle(ResoniqColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(spacing: ResoniqSpace.s1) {
                Button("Listen again", action: onTestAgain)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
                Button("Back", action: onClose)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
        }
        .padding(.horizontal, ResoniqSpace.screenInset)
        .padding(.vertical, ResoniqSpace.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ResoniqColor.ink)
        .accessibilityAction(.escape, onClose)
    }
}

#Preview("Unreadable result") {
    UnreadableResultScreen(onTestAgain: {}, onClose: {})
        .preferredColorScheme(.dark)
}
