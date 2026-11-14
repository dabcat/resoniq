#if DEBUG
import ResoniqAudio
import ResoniqDesign
import ResoniqDSP
import SwiftUI

/// The screens of the option "play the test sound from another device", each in a fixed representative state, for
/// looking at in the simulator, and the two flows running unattended. `-screen <name>` is routed here by the app's
/// debug entry. Debug builds only.
///
/// - `test-sound`, `test-sound-seat`: the files screen, for a pair and for the seat.
/// - `external-waiting`, `external-hearing`, `external-again`, `external-not-recognised`: the listening screen
///   waiting for "Press play now.", hearing run 2 of 3, asking for the file once more with the reason, and the
///   failure for sound that was not the test sound.
/// - `external-flow`: the real Diagnose tab on an in-memory store and simulated audio, already listening for the left
///   speaker. A small "Simulate pressing play" button plays the file into the simulated room. With `-autostart YES`
///   the simulated player presses play by itself two seconds after "Press play now." appears (and again when another
///   play is asked for), 300 ppm fast with a route delay, so the test runs to the Result screen unattended.
/// - `external-seat-flow`: the same for the seat: the real Measure tab, listening at the three spots, ending on Measure
///   home. With `-autostart YES` it also presses "I have the file" if the file is on screen.
enum ExternalDebugScreens {
    static let names = [
        "test-sound", "test-sound-seat", "external-waiting", "external-hearing", "external-again",
        "external-not-recognised", "external-flow", "external-seat-flow",
    ]

    @MainActor
    static func view(named name: String) -> AnyView? {
        switch name {
        case "test-sound":
            AnyView(
                TestSoundScreen(context: .speaker(choices: [.left, .right]), onContinue: {}, onClose: {})
                    .preferredColorScheme(.dark)
            )
        case "test-sound-seat":
            AnyView(
                TestSoundScreen(context: .seat(channels: [.left, .right]), onContinue: {}, onClose: {})
                    .preferredColorScheme(.dark)
            )
        case "external-waiting":
            AnyView(ExternalListeningScreen(display: .previewWaiting, onStop: {}).preferredColorScheme(.dark))
        case "external-hearing":
            AnyView(ExternalListeningScreen(display: .previewHearing, onStop: {}).preferredColorScheme(.dark))
        case "external-again":
            AnyView(ExternalListeningScreen(display: .previewAgain, onStop: {}).preferredColorScheme(.dark))
        case "external-not-recognised":
            AnyView(
                ExternalFailedScreen(failure: .soundNotRecognised, file: .speakerTest(.left), onTryAgain: {}, onClose: {})
                    .preferredColorScheme(.dark)
            )
        case "external-flow":
            AnyView(ExternalFlowHost())
        case "external-seat-flow":
            AnyView(ExternalSeatFlowHost())
        default:
            nil
        }
    }

    /// The real Diagnose tab, already listening for the left speaker (not through the files screen).
    private struct ExternalFlowHost: View {
        @State private var composition = AppComposition.launch(inMemory: true, audio: .simulated())
        @State private var tab = AppTab.diagnose

        var body: some View {
            if let composition {
                VStack(spacing: 0) {
                    DiagnoseTab()
                    ResoniqTabBar(AppTab.allCases.map(\.item), selection: $tab)
                }
                .background(ResoniqColor.ink)
                .appEnvironment(composition)
                .preferredColorScheme(.dark)
                .task {
                    let coordinator = composition.coordinator
                    coordinator.startExternalTest(.left)
                    if case .external(let flow) = coordinator.content { flow.start() }
                }
            } else {
                StoreUnavailableScreen()
            }
        }
    }

    /// The real Measure tab, already listening for the seat (not through the file screen).
    private struct ExternalSeatFlowHost: View {
        @State private var composition = AppComposition.launch(inMemory: true, audio: .simulated())
        @State private var tab = AppTab.measure

        var body: some View {
            if let composition {
                VStack(spacing: 0) {
                    MeasureTab()
                    ResoniqTabBar(AppTab.allCases.map(\.item), selection: $tab)
                }
                .background(ResoniqColor.ink)
                .appEnvironment(composition)
                .preferredColorScheme(.dark)
                .task {
                    let measure = composition.measure
                    measure.startExternalMeasurement()
                    if case .externalMeasurement(let flow) = measure.content { flow.start() }
                }
            } else {
                StoreUnavailableScreen()
            }
        }
    }
}

// MARK: - The simulated player

extension View {
    /// The debug "simulated player": while the session is asking for the file to be played (`asking` says for which
    /// states), a small "Simulate pressing play" button plays it into the simulated room, and with `-autostart YES` the
    /// same happens by itself two seconds after the request appears (and again when it is made again).
    func simulatedPlayer<State: Equatable>(
        state: State?,
        isListening: Bool,
        isAvailable: Bool,
        play: @escaping () -> Void,
        asking: @escaping (State) -> Bool
    ) -> some View {
        modifier(SimulatedPlayer(state: state, isListening: isListening, isAvailable: isAvailable, play: play, asking: asking))
    }
}

private struct SimulatedPlayer<State: Equatable>: ViewModifier {
    let state: State?
    let isListening: Bool
    let isAvailable: Bool
    let play: () -> Void
    let asking: (State) -> Bool

    private var isAsking: Bool {
        guard isAvailable, isListening, let state else { return false }
        return asking(state)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if isAsking {
                    Button(action: play) {
                        Text("DEBUG · Simulate pressing play")
                            .font(ResoniqFont.axis)
                            .foregroundStyle(ResoniqColor.muted)
                            .padding(.horizontal, ResoniqSpace.s3)
                            .frame(minHeight: ResoniqSize.touchMin)
                            .overlay(Capsule().strokeBorder(ResoniqColor.line, lineWidth: ResoniqSize.strokeHairline))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, ResoniqSpace.screenInset)
                    .padding(.bottom, ResoniqSpace.s2)
                }
            }
            // Two seconds after the request appears; a state that changes in between starts the wait over.
            .task(id: state) {
                guard UserDefaults.standard.bool(forKey: "autostart"), isAsking else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, isAsking else { return }
                play()
            }
    }
}

// MARK: - Fixed states

extension ExternalRunDisplay {
    private static let file = TestSoundFile.Kind.speakerTest(.left)

    /// "Press play now.": the floor is known, nothing heard yet.
    static let previewWaiting: ExternalRunDisplay = {
        var run = RunDisplay.previewFloor
        run.title = DiagnoseText.speakerName(.left)
        run.frequency = RunDisplay.Frequency(value: "–", unit: nil, detail: TestSoundText.notHeardYet)
        return ExternalRunDisplay(
            run: run,
            headline: ExternalSessionText.headline(for: .waitingForSound, runCount: 3),
            detail: ExternalSessionText.waitingLine(isSilenceLong: false, file: file),
            announcement: ExternalSessionText.headline(for: .waitingForSound, runCount: 3)
        )
    }()

    /// Run 2 of 3 being heard, at 1.02 kHz.
    static let previewHearing: ExternalRunDisplay = {
        let run = RunDisplay.previewListening
        return ExternalRunDisplay(
            run: run,
            headline: ExternalSessionText.headline(for: .hearing(run: 2), runCount: 3),
            detail: ExternalSessionText.hearingLine,
            announcement: ExternalSessionText.headline(for: .hearing(run: 2), runCount: 3)
        )
    }()

    /// The third run was too quiet: two are in hand, the file is to be played once more.
    static let previewAgain: ExternalRunDisplay = {
        var run = RunDisplay.previewFloor
        run.title = DiagnoseText.speakerName(.left)
        run.frequency = RunDisplay.Frequency(value: "–", unit: nil, detail: TestSoundText.notHeardYet)
        let problem = ExternalPlayProblem.run(.unusable(.tooQuiet(level: Level(peak: 0.005, rms: 0.001, dcOffset: 0))))
        let text = ExternalSessionText.anotherPlayText(problem, have: 2, needed: 3, file: file)
        let headline = ExternalSessionText.headline(for: .needsAnotherPlay(have: 2, reason: problem), runCount: 3)
        return ExternalRunDisplay(
            run: run, headline: headline,
            notice: ExternalNotice(title: TestSoundText.againNoticeTitle, text: text),
            announcement: "\(headline) \(text)"
        )
    }()

    /// Sound that is not the test sound is heard while waiting.
    static let previewNotTheTestSound: ExternalRunDisplay = {
        var display = previewWaiting
        display.notice = ExternalRunDisplay.hearingNotice(.notTheTestSound, isSilenceLong: false, file: file)
        return display
    }()
}
#endif
