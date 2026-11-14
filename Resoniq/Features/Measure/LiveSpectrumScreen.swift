import Foundation
import Observation
import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import SwiftUI

// MARK: - The model

/// "Watch the sound live": follows `LiveSpectrum` on the app's audio. It plays nothing. The stream starts with
/// `start()` and ends with `stop()`, which is safe in any state: the screen calls it when it appears and disappears,
/// and the app's lifecycle hook calls it when the scene leaves the foreground.
@MainActor
@Observable
final class LiveSpectrumModel {
    enum State: Equatable {
        /// Not started, or stopped.
        case idle
        /// Asking for the microphone or waiting for the first update.
        case starting
        case listening
        case denied
        /// The audio could not start, or stopped under the stream (a call, a route change).
        case unavailable
    }

    private(set) var state: State = .idle
    /// Third-octave levels in dBFS, 20 Hz to 20 kHz; empty before the first update.
    private(set) var levels: [Double] = []
    /// One sentence for VoiceOver, refreshed at most every `summaryInterval` so it does not chatter.
    private(set) var summary = "Listening. No sound yet."

    @ObservationIgnored private let audio: AudioEnvironment
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastSummary: ContinuousClock.Instant?

    /// Seconds between one spoken summary and the next.
    static let summaryInterval = 2.0

    init(audio: AudioEnvironment = .current) {
        self.audio = audio
    }

    func start() {
        guard task == nil else { return }
        state = .starting
        levels = []
        lastSummary = nil
        task = Task { [weak self] in await self?.listen() }
    }

    func stop() {
        task?.cancel()
        task = nil
        if state != .denied { state = .idle }
        levels = []
    }

    private func listen() async {
        let permission = audio.permission
        var granted = permission.status == .granted
        if permission.status == .undetermined { granted = await permission.request() }
        guard !Task.isCancelled else { return }
        guard granted else {
            state = .denied
            task = nil
            return
        }
        for await update in LiveSpectrum(io: audio.makeLiveIO()).bands() {
            if Task.isCancelled { return }
            levels = update.decibels.map(Double.init)
            state = .listening
            refreshSummary(update.frequencies, update.decibels)
        }
        // The stream ended on its own: the audio could not start or went away.
        guard !Task.isCancelled else { return }
        state = .unavailable
        levels = []
        task = nil
    }

    /// "Loudest around 90 hertz." (The figure is the Kit's band centre in its own words, `SeatText.frequency`.)
    private func refreshSummary(_ frequencies: [Float], _ decibels: [Float]) {
        let now = ContinuousClock.now
        if let lastSummary, now - lastSummary < .seconds(Self.summaryInterval) { return }
        lastSummary = now
        guard let loudest = decibels.indices.max(by: { decibels[$0] < decibels[$1] }) else { return }
        let spoken = SeatText.frequency(frequencies[loudest])
            .replacingOccurrences(of: " kHz", with: " kilohertz")
            .replacingOccurrences(of: " Hz", with: " hertz")
        summary = "Loudest around \(spoken)."
    }
}

// MARK: - The screen

/// Watch the sound live (no mockup; design/DESIGN_SYSTEM.md): the microphone's third-octave bars filling the height,
/// the frequency axis under them, one sentence about what they show, and a close button. The stream starts when the
/// screen appears and stops when it disappears or the scene leaves the foreground. Nothing is played.
struct LiveSpectrumScreen: View {
    let model: LiveSpectrumModel
    var onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        FlowScaffold {
            HStack(spacing: ResoniqSpace.s3) {
                Button(action: onClose) {
                    ResoniqIconView(.back)
                }
                .buttonStyle(ResoniqIconButtonStyle())
                .accessibilityLabel("Close")
                Text("Live")
                    .resoniqCapsLabel()
            }
        } content: {
            switch model.state {
            case .denied:
                MeasureMessage(headline: "I can't hear without the microphone.", message: Words.denied) { EmptyView() }
                    .padding(.top, ResoniqSpace.s6)
            case .unavailable:
                MeasureMessage(headline: "I couldn't listen just now.", message: Words.unavailable) { EmptyView() }
                    .padding(.top, ResoniqSpace.s6)
            default:
                VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
                    VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
                        Text(SeatWords.watchLive)
                            .resoniqTitle(.medium)
                            .accessibilityAddTraits(.isHeader)
                        Text(Words.explanation)
                            .font(ResoniqFont.body)
                            .foregroundStyle(ResoniqColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .resoniqTitleRise()

                    SpectrumBars(
                        levels: model.levels,
                        title: model.state == .listening ? "Live" : "Waiting for sound",
                        detail: "dB per third octave",
                        fillsHeight: true,
                        accessibilityLabel: model.summary
                    )
                    .resoniqPanel()
                    .frame(minHeight: Metrics.panelMinHeight, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } footer: {
            if model.state == .denied {
                VStack(spacing: ResoniqSpace.s1) {
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(ResoniqPrimaryButtonStyle())
                    Button("Not now", action: onClose)
                        .buttonStyle(ResoniqTextLinkStyle())
                }
            } else if model.state == .unavailable {
                VStack(spacing: ResoniqSpace.s1) {
                    Button("Try again", action: model.start)
                        .buttonStyle(ResoniqPrimaryButtonStyle())
                    Button("Not now", action: onClose)
                        .buttonStyle(ResoniqTextLinkStyle())
                }
            } else {
                Text(Words.footnote)
                    .font(ResoniqFont.caption)
                    .foregroundStyle(ResoniqColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityAction(.escape, onClose)
        .keepsScreenAwake(while: model.state == .starting || model.state == .listening)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() } else { model.stop() }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private enum Metrics {
        /// Enough bars to read at the largest type sizes, where the sentence takes the rest.
        static let panelMinHeight: CGFloat = 220
    }

    /// The copy of this screen (no mockup).
    private enum Words {
        static let explanation = "This is what the microphone hears right now, from the deepest bass on the left to the highest treble on the right. Nothing is played."
        static let footnote = "The iPhone's microphone isn't calibrated, so trust the shape of the bars more than the decibels."
        static let denied = "I show the sound by listening to it, so I need the microphone. Sound stays on this iPhone. You can allow it in Settings."
        static let unavailable = "This iPhone wouldn't let me use the microphone just now. Close anything else that records sound, then try again."
    }
}

#if DEBUG
#Preview("Live") {
    LiveSpectrumScreen(model: .preview(.listening), onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Live, microphone denied") {
    LiveSpectrumScreen(model: .preview(.denied), onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Live, large type") {
    LiveSpectrumScreen(model: .preview(.listening), onClose: {})
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}

extension LiveSpectrumModel {
    /// A model for previews, on simulated audio: it hears the simulation's hiss, or is denied the microphone.
    @MainActor
    static func preview(_ state: State) -> LiveSpectrumModel {
        let permission: MicrophoneAccess = state == .denied ? .denied : .granted
        return LiveSpectrumModel(audio: .simulated(access: permission))
    }
}
#endif
