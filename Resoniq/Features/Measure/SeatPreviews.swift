#if DEBUG
import ResoniqAudio
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqDSP

/// Fixed states of Three spots and Paused for previews and the debug screens. The traces are the first spot of a real
/// report (`MeasureFixtures.mockup`), so what is drawn is what the Kit made, not a sketch.
extension SeatRunDisplay {
    private static func pills(_ states: [SpotsDiagram.SpotState]) -> [Pill] {
        zip(["Seat", "Left", "Right"], states).map { title, state in
            let words = switch state {
            case .done: "done"
            case .active: "measuring now"
            case .upcoming: "still to do"
            }
            return Pill(title: title, state: state, spoken: "\(title), \(words)")
        }
    }

    private static let firstTrace: [Double] = (MeasureFixtures.mockup.spotCurves.first ?? nil).map { $0.map(Double.init) } ?? []

    private static let quietRoom = RunDisplay.Reading(title: "Room", value: "Quiet · 33 dB", spoken: "Room: quiet, about 33 decibels.")
    private static let goodLevel = RunDisplay.Reading(title: "Level", value: "Good", spoken: "Level: good.")
    private static let quietNoise = RunDisplay.RoomNoise(value: "33 dB", level: 0.47, mark: 0.55, isQuiet: true)

    /// V3MRunning: the seat is done, the phone is on its way to the left spot, one trace is in.
    static let previewMoving = SeatRunDisplay(
        pills: pills([.done, .active, .upcoming]),
        instruction: "Now move the phone 30 cm to your left.",
        spots: [.active, .done, .upcoming],
        phoneSpot: 0,
        diagramLabel: MeasureText.diagramLabel(captured: [.seat], active: .left),
        capturedCount: 1,
        progressLabel: "1 of 3 in",
        traces: [firstTrace],
        average: firstTrace,
        curveLabel: MeasureText.curveLabel(captured: 1, drawn: 1, of: 3),
        room: quietRoom,
        level: goodLevel,
        roomNoise: quietNoise
    )

    /// The left spot's left speaker is playing.
    static let previewPlaying: SeatRunDisplay = {
        var display = previewMoving
        display.instruction = "Hold still. The left speaker is playing."
        display.footerLine = MeasureText.playingLine
        return display
    }()

    /// The first recording of a spot was too quiet, so it plays again.
    static let previewRepeating: SeatRunDisplay = {
        var display = previewPlaying
        display.note = .repeating(.unusable(.tooQuiet(level: Level(peak: 0.005, rms: 0.001, dcOffset: 0))))
        return display
    }()

    /// Paused at 1 kHz by noise at 52 dB.
    static let previewPaused = SeatRunDisplay(
        pills: pills([.done, .active, .upcoming]),
        instruction: "It got noisy, so I stopped the left speaker.",
        spots: [.active, .done, .upcoming],
        phoneSpot: 0,
        diagramLabel: MeasureText.diagramLabel(captured: [.seat], active: .left),
        capturedCount: 1,
        progressLabel: "1 of 3 in",
        traces: [firstTrace],
        average: firstTrace,
        curveLabel: MeasureText.curveLabel(captured: 1, drawn: 1, of: 3),
        room: RunDisplay.Reading(title: "Room", value: "Noisy · 52 dB", spoken: "Room: noisy, about 52 decibels."),
        level: goodLevel,
        roomNoise: RunDisplay.RoomNoise(value: "52 dB", level: 0.78, mark: 0.55, isQuiet: false),
        pausedTitle: "Left spot · left speaker",
        resumeFrequency: "1 kHz"
    )
}
#endif
