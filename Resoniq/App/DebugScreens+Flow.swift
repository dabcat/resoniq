#if DEBUG
import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqDSP
import ResoniqStore
import SwiftUI

/// The Aim, Listening and Paused screens and their no-mockup states, each in a fixed representative state, for
/// looking at in the simulator. `-screen <name>` is routed here by the app's debug entry; `flow` is the live flow
/// on simulated audio (add `-simulatedNoise YES` to see Paused). Debug builds only.
enum FlowDebugScreens {
    static let names = [
        "aim", "aim-soundbar", "listening", "listening-level", "paused", "paused-named", "denied", "repeating", "failed", "failed-noisy", "failed-not-connected", "flow",
    ]

    @MainActor
    static func view(named name: String) -> AnyView? {
        switch name {
        case "aim":
            AnyView(AimHost())
        case "aim-soundbar":
            AnyView(SoundbarAimHost())
        case "listening-level":
            AnyView(ListeningScreen(display: .previewLevelAndMoving, onStop: {}).preferredColorScheme(.dark))
        case "paused-named":
            AnyView(PausedScreen(display: .previewPausedNamed, onStop: {}).preferredColorScheme(.dark))
        case "listening":
            AnyView(ListeningScreen(display: .previewListening, onStop: {}).preferredColorScheme(.dark))
        case "paused":
            AnyView(PausedScreen(display: .previewPaused, onStop: {}).preferredColorScheme(.dark))
        case "denied":
            AnyView(MicrophoneDeniedScreen(onOpenSettings: {}, onBack: {}).preferredColorScheme(.dark))
        case "repeating":
            AnyView(ListeningScreen(display: .previewRepeating, onStop: {}).preferredColorScheme(.dark))
        case "failed":
            AnyView(
                DiagnoseFailedScreen(failure: .unusable(.didNotArrive), onTryAgain: {}, onClose: {})
                    .preferredColorScheme(.dark)
            )
        case "failed-noisy":
            AnyView(
                DiagnoseFailedScreen(failure: .tooNoisy, onTryAgain: {}, onClose: {})
                    .preferredColorScheme(.dark)
            )
        case "failed-not-connected":
            AnyView(
                DiagnoseFailedScreen(
                    failure: .speakersNotConnected(AudioOutputRoute(kind: .builtInSpeaker, name: "iPhone Speaker")),
                    onTryAgain: {}, onClose: {}
                )
                .preferredColorScheme(.dark)
            )
        case "flow":
            AnyView(LiveFlowHost())
        default:
            nil
        }
    }
}

private struct AimHost: View {
    @State private var position = SpeakerPosition.left

    var body: some View {
        AimScreen(position: $position, onStart: {}, onClose: {})
            .preferredColorScheme(.dark)
    }
}

private struct SoundbarAimHost: View {
    @State private var position = SpeakerPosition.single

    var body: some View {
        AimScreen(position: $position, choices: [.single], singleName: "Soundbar", onStart: {}, onClose: {})
            .preferredColorScheme(.dark)
    }
}

/// The live flow on simulated audio, with a placeholder where the Result screen goes.
private struct LiveFlowHost: View {
    @State private var flow = DiagnoseFlow(audio: .simulated(noise: UserDefaults.standard.bool(forKey: "simulatedNoise")))

    var body: some View {
        DiagnoseFlowView(flow: flow, onClose: {}) { completed in
            VStack(spacing: ResoniqSpace.s3) {
                Text("Result goes here")
                    .font(ResoniqFont.title3)
                Text(completed.report.verdict)
                    .font(ResoniqFont.body)
                    .foregroundStyle(ResoniqColor.muted)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(ResoniqColor.ivory)
            .padding(ResoniqSpace.screenInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ResoniqColor.ink)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Fixed states

extension RunDisplay {
    /// A speaker that measured evenly, drawn up to 1.02 kHz (57 % of the height) in 241 steps.
    private static func partialWidths(upTo fraction: Double) -> [Double] {
        (0..<241).map { index in
            let t = Double(index) / 240
            guard t <= fraction else { return 0 }
            let taper = min(1, t * 10)
            return taper * (0.52 + 0.1 * sin(t * 14))
        }
    }

    private static let heldFraction = FrequencyRuler.fraction(forFrequency: 1_020)

    /// Run 2 of 3 on the left speaker at 1.02 kHz, in a quiet room (V3Listening).
    static let previewListening = RunDisplay(
        title: "Left speaker · run 2 of 3",
        widths: partialWidths(upTo: heldFraction),
        portrait: .drawing(progress: heldFraction),
        portraitLabel: DiagnoseText.portraitLabel(.drawing(progress: heldFraction), hertz: 1_020),
        frequency: Frequency(value: "1.02", unit: "kHz", detail: "Middle driver"),
        room: Reading(title: "Room", value: "Quiet · 34 dB", spoken: "Room: quiet, about 34 decibels."),
        level: Reading(title: "Level", value: "Good, no clipping", spoken: "Level: good, no clipping."),
        phone: Reading(title: "Phone", value: "Steady", spoken: "Phone: steady."),
        roomNoise: RoomNoise(value: "34 dB", level: 0.49, mark: 0.55, isQuiet: true)
    )

    /// Before the first run: the room's floor is being measured.
    static let previewFloor = RunDisplay(
        title: "Left speaker · run 1 of 3",
        widths: [],
        portrait: .notHeard,
        portraitLabel: DiagnoseText.portraitLabel(.notHeard, hertz: nil),
        frequency: Frequency(value: "–", unit: nil, detail: "Listening to the room first"),
        room: Reading(title: "Room", value: "Quiet · 31 dB", spoken: "Room: quiet, about 31 decibels."),
        level: Reading(title: "Level", value: "Good, no clipping", spoken: "Level: good, no clipping."),
        phone: Reading(title: "Phone", value: "Steady", spoken: "Phone: steady."),
        roomNoise: RoomNoise(value: "31 dB", level: 0.44, mark: 0.55, isQuiet: true)
    )

    /// The first recording of run 2 was too quiet, so it plays again.
    static let previewRepeating: RunDisplay = {
        var display = previewListening
        display.note = .repeating(.unusable(.tooQuiet(level: Level(peak: 0.005, rms: 0.001, dcOffset: 0))))
        return display
    }()

    /// Too quiet, and the phone moving: what each says to do, and the readings' hints.
    static let previewLevelAndMoving: RunDisplay = {
        var display = previewListening
        display.level = Reading(
            title: "Level", value: "Too quiet",
            spoken: "Level: too quiet. Turn the volume up or hold the phone closer.",
            hint: "Turn the volume up or hold the phone closer."
        )
        display.phone = Reading(title: "Phone", value: "Moving", spoken: "Phone: moving.")
        return display
    }()

    /// Paused, with what the sound classifier heard in the pause.
    static let previewPausedNamed: RunDisplay = {
        var display = previewPaused
        display.interference = InterferenceNote(
            sentence: "It sounds like someone talking.", tagLine: "Inferred · sound classifier, 82 %"
        )
        return display
    }()

    /// Paused at 1 kHz by noise at 52 dB (V3Paused).
    static let previewPaused = RunDisplay(
        title: "Left speaker · run 2 of 3",
        widths: partialWidths(upTo: heldFraction),
        portrait: .paused(progress: heldFraction),
        portraitLabel: DiagnoseText.portraitLabel(.paused(progress: heldFraction), hertz: 1_000),
        frequency: Frequency(value: "–", unit: nil, detail: "Paused"),
        room: Reading(title: "Room", value: "Noisy · 52 dB", spoken: "Room: noisy, about 52 decibels."),
        level: Reading(title: "Level", value: "Good, no clipping", spoken: "Level: good, no clipping."),
        phone: Reading(title: "Phone", value: "Steady", spoken: "Phone: steady."),
        roomNoise: RoomNoise(value: "52 dB", level: 0.78, mark: 0.55, isQuiet: false),
        resumeFrequency: "1 kHz"
    )
}
#endif
