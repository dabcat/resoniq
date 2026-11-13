#if DEBUG
import Foundation
import ResoniqDiagnostics
import ResoniqRoom
import ResoniqStore

/// Data for the Optimize screens' previews and debug entries. The room is built with the Kit's own initialisers; the
/// suggestion is what the real `PlacementAdvisor` returns for it; the seat and comparison reports are what the real
/// Diagnostics code produced from its simulated listening room (the mockup's: a boom at 41 Hz and a missing note at
/// 61 Hz), decoded from JSON written once by a throwaway test. To keep the strings short the curves are rounded to a
/// tenth of a decibel and the left, right, spread and per-spot curves are left out (the screens read none of them).
enum OptimizeFixtures {
    // MARK: Rooms

    /// The mockups' living room: 4.20 × 5.60 m, a window in the wall behind the speakers, a door in the left wall, a
    /// sofa facing the speakers, a pair 1.40 m from the wall behind them 2 m apart, and the seat at the apex of an
    /// equilateral triangle. Everything is confirmed.
    static let room: RoomModel = {
        var room = emptyRoom
        let seat = PlanPoint(x: 0, z: -1.4 + 3.0.squareRoot())
        let left = PlanPoint(x: -1, z: -1.4), right = PlanPoint(x: 1, z: -1.4)
        room.seats = [Seat(position: seat, isConfirmed: true)]
        room.speakers = [
            PlacedSpeaker(id: rightID, role: .right, position: right, facing: (seat - right).angle, isConfirmed: true),
            PlacedSpeaker(id: leftID, role: .left, position: left, facing: (seat - left).angle, isConfirmed: true),
        ]
        return room
    }()

    /// The same room as a scan leaves it: the walls and the sofa, with the pair and the seat guessed by
    /// `LayoutGuess` and unconfirmed.
    static let guessedRoom: RoomModel = {
        var scanned = emptyRoom
        scanned.source = .scanned
        return LayoutGuess.place(in: scanned)
    }()

    static let rightID = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!
    static let leftID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!

    /// The walls, the window, the door and the sofa, with nothing placed.
    private static var emptyRoom: RoomModel {
        var room = ManualRoom(width: 4.2, length: 5.6, height: 2.4).model()!
        // Walls run back (−z), right (+x), front (+z), left (−x): the window is in the back wall, the door in the left
        // wall near the front corner (that wall runs from front to back).
        room.walls[0].openings = [Opening(kind: .window, offset: 2.1, width: 1.4)]
        room.walls[3].openings = [Opening(kind: .door, offset: 0.85, width: 0.8)]
        room.furniture = [
            Furniture(
                category: .sofa,
                footprint: OrientedRect(centre: PlanPoint(x: 0, z: 1.2), width: 2.0, depth: 0.9, heading: -.pi / 2))
        ]
        return room
    }

    // MARK: Advice

    /// The missing note at 61 Hz, 11 dB down, as the seat report states it.
    static let problems = [AcousticProblem(frequency: 61, deviation: 11, kind: .dip)]

    /// What the real advisor suggests for `problems` in `room`.
    static let suggestion: PlacementSuggestion = {
        guard let first = PlacementAdvisor.advice(room: room, problems: problems).suggestions.first else {
            preconditionFailure("the advisor suggests nothing for the fixture room")
        }
        return first
    }()

    // MARK: Reports

    static let before = decode(SeatReport.self, beforeJSON)
    static let after = decode(SeatReport.self, afterJSON)
    /// A second measurement in which both the boom and the missing note got worse.
    static let worseAfter = decode(SeatReport.self, worseAfterJSON)
    /// A room with nothing to find.
    static let even = decode(SeatReport.self, evenJSON)

    /// "The missing bass note is back." (the mockup's).
    static let improved = decode(ComparisonReport.self, improvedJSON)
    static let worse = decode(ComparisonReport.self, worseJSON)
    static let unchanged = decode(ComparisonReport.self, unchangedJSON)

    // MARK: Home states

    private static let scanned = OptimizeProgress(scanned: true)
    private static let measured = OptimizeProgress(scanned: true, measured: true)

    static let homeNoRoom = OptimizeHomeState.make(OptimizeHomeInput(layout: nil, seat: nil, progress: OptimizeProgress())).state
    static let homeNotMeasured = OptimizeHomeState.make(OptimizeHomeInput(layout: room, seat: nil, progress: scanned)).state
    /// The mockup.
    static let homeSuggestion = OptimizeHomeState.make(OptimizeHomeInput(layout: room, seat: before, progress: measured)).state
    static let homeNothing = OptimizeHomeState.make(OptimizeHomeInput(layout: room, seat: even, progress: measured)).state
    static let homeMoved = OptimizeHomeState.make(
        OptimizeHomeInput(layout: room, seat: before, progress: OptimizeProgress(scanned: true, measured: true, moved: true))
    ).state
    static let homeVerified = OptimizeHomeState.make(
        OptimizeHomeInput(
            layout: room, seat: after, progress: OptimizeProgress(scanned: true, measured: true, moved: true, verified: true),
            comparison: improved)
    ).state

    // MARK: Stored forms

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            preconditionFailure("fixture JSON for \(type) does not decode: \(error)")
        }
    }

    private static let beforeJSON = #"{"bassDecay":{"lower":20,"seconds":0.7,"upper":80},"curve":[-3.9,-3.8,-3.5,-3.2,-2.9,-2.6,-2.3,-2.0,-1.8,-1.6,-1.3,-1.1,-0.9,-0.6,-0.5,-0.3,-0.0,0.3,0.6,0.9,1.4,2.1,3.4,5.3,7.5,9.2,7.2,4.8,2.9,1.5,0.6,-0.1,-1.0,-1.9,-2.6,-3.9,-5.6,-7.9,-10.4,-11.4,-9.5,-7.2,-5.3,-4.0,-3.2,-2.6,-2.2,-1.9,-1.8,-1.7,-1.6,-1.6,-1.6,-1.6,-1.6,-1.7,-1.7,-1.8,-1.8,-1.9,-1.9,-2.0,-2.0,-2.1,-2.1,-2.1,-2.1,-2.1,-2.0,-2.0,-1.9,-1.8,-1.6,-1.5,-1.3,-1.2,-1.0,-0.8,-0.6,-0.4,-0.2,-0.0,0.2,0.3,0.5,0.6,0.7,0.8,0.8,0.8,0.8,0.8,0.7,0.7,0.6,0.4,0.3,0.1,-0.1,-0.2,-0.4,-0.5,-0.6,-0.6,-0.6,-0.6,-0.5,-0.4,-0.3,-0.2,-0.1,-0.1,-0.1,-0.0,-0.0,-0.1,-0.1,-0.1,-0.0,0.0,0.0,0.1,0.1,0.1,-0.0,-0.1,-0.2,-0.3,-0.3,-0.3,-0.2,-0.1,-0.1,-0.0,0.0,0.0,0.0,-0.0,-0.1,-0.2,-0.2,-0.2,-0.1,-0.0,0.1,0,-0.1,-0.2,-0.1,0.1,0.1,-0.0,-0.3,-0.3,-0.0,0.2,0.1,-0.1,-0.2,-0.1,0.1,0.1,0.1,-0.0,-0.0,0.1,0.1,0.1,0.1,0.1,0.2,0.2,0.1,0.2,0.2,0.2,0.3,0.3,0.3,0.3,0.4,0.3,0.3,0.4,0.3,0.4,0.4,0.4,0.4,0.5,0.4,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.6,0.6,0.5,0.5,0.5,0.6,0.6,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.6,0.5,0.6,0.6,0.5,0.6,0.6,0.6,0.5,0.5,0.6,0.5,0.6,0.5,0.5,0.5],"distortionPercent":0.4,"evenBandDecibels":3,"extremes":[{"deviation":9.2,"frequency":41.0,"kind":"peak","range":{"lower":37.3,"upper":44.7},"spread":4.7},{"deviation":-11.4,"frequency":61.2,"kind":"dip","range":{"lower":53.7,"upper":71.6},"spread":3.7}],"findings":[{"detail":"41 Hz is 9 dB louder than the middle. 61 Hz is 11 dB quieter.","headline":"One bass note booms, one nearly vanishes","isDeviation":true,"kind":"bass","strength":11.4,"tag":"measured","tagLine":"Measured"},{"detail":"Above the bass, everything stays within 3 dB of the middle. Above the bass, the two speakers stay within 1.2 dB of each other.","headline":"Voices and treble are even, left matches right","isDeviation":false,"kind":"rest","strength":0,"tag":"measured","tagLine":"Measured · within 1.2 dB"},{"basis":"roomSize","detail":"41 Hz and 61 Hz are where this room's size makes the bass resonate. That points to the room, though I can't be certain.","headline":"It's the room, not the speakers","isDeviation":false,"kind":"roomCause","strength":0,"tag":"inferred","tagLine":"Inferred from room size. Moving speakers should help."}],"isConclusive":true,"leftRightDifference":1.2,"numbers":[{"kind":"peak","label":"41 Hz","tag":"measured","value":"+9.2 dB","word":"peak"},{"kind":"dip","label":"61 Hz","tag":"measured","value":"−11.4 dB","word":"dip"},{"kind":"leftRight","label":"L / R","tag":"measured","value":"±1.2 dB","word":"match"},{"kind":"distortion","label":"1 kHz","tag":"measured","value":"0.4 %","word":"distortion"},{"kind":"decay","label":"< 80 Hz","tag":"estimate","value":"≈ 0.7 s","word":"decay"}],"requiredSpotCount":3,"schemaVersion":1,"spotCurves":[null,null,null],"spots":[{"left":{"valid":{"signalToNoise":49.9}},"right":{"valid":{"signalToNoise":50.2}}},{"left":{"valid":{"signalToNoise":49.7}},"right":{"valid":{"signalToNoise":50.0}}},{"left":{"valid":{"signalToNoise":49.4}},"right":{"valid":{"signalToNoise":49.8}}}],"validSpotCount":3,"verdict":"From your seat, the bass is uneven. The rest is balanced."}"#
    private static let afterJSON = #"{"bassDecay":{"lower":20,"seconds":0.5,"upper":80},"curve":[-3.9,-3.8,-3.5,-3.2,-2.9,-2.6,-2.3,-2.1,-1.8,-1.6,-1.3,-1.1,-0.9,-0.7,-0.5,-0.4,-0.2,0.0,0.2,0.5,0.8,1.3,2.1,3.2,4.5,5.5,4.4,3.1,2.0,1.3,0.8,0.5,0.1,-0.2,-0.5,-1.0,-1.8,-2.7,-3.6,-3.9,-3.4,-2.5,-1.8,-1.4,-1.1,-1.0,-0.9,-0.9,-0.9,-0.9,-1.0,-1.0,-1.1,-1.2,-1.3,-1.4,-1.5,-1.5,-1.6,-1.7,-1.8,-1.8,-1.9,-2.0,-2.0,-2.0,-2.0,-2.0,-2.0,-1.9,-1.8,-1.7,-1.6,-1.4,-1.3,-1.1,-0.9,-0.7,-0.6,-0.4,-0.2,0.0,0.2,0.3,0.5,0.6,0.7,0.8,0.8,0.8,0.8,0.8,0.8,0.7,0.6,0.4,0.3,0.1,-0.1,-0.2,-0.4,-0.5,-0.6,-0.6,-0.6,-0.6,-0.5,-0.4,-0.3,-0.2,-0.1,-0.1,-0.1,-0.0,-0.0,-0.1,-0.1,-0.1,-0.0,0,0.0,0.1,0.1,0.1,-0.0,-0.1,-0.2,-0.3,-0.3,-0.3,-0.2,-0.1,-0.1,-0.0,0.0,0.0,0.0,-0.0,-0.1,-0.2,-0.2,-0.2,-0.1,-0.0,0.1,-0.0,-0.1,-0.2,-0.1,0.1,0.1,-0.0,-0.3,-0.3,-0.0,0.2,0.1,-0.1,-0.2,-0.1,0.1,0.1,0.1,-0.1,-0.0,0.1,0.1,0.1,0.1,0.1,0.2,0.2,0.1,0.2,0.2,0.2,0.3,0.3,0.2,0.3,0.4,0.3,0.3,0.4,0.3,0.4,0.4,0.4,0.4,0.5,0.4,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.6,0.6,0.5,0.5,0.5,0.5,0.6,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.6,0.5,0.6,0.5,0.5,0.6,0.6,0.6,0.5,0.5,0.5,0.5,0.6,0.5,0.5,0.5],"distortionPercent":0.4,"evenBandDecibels":3,"extremes":[{"deviation":5.5,"frequency":41.0,"kind":"peak","range":{"lower":38.6,"upper":43.6},"spread":2.2},{"deviation":-3.9,"frequency":61.2,"kind":"dip","range":{"lower":58.6,"upper":64.1},"spread":0.8}],"findings":[{"detail":"41 Hz is 5 dB louder than the middle. 61 Hz is 4 dB quieter.","headline":"One bass note booms, one is quiet","isDeviation":true,"kind":"bass","strength":5.5,"tag":"measured","tagLine":"Measured"},{"detail":"Above the bass, everything stays within 3 dB of the middle. Above the bass, the two speakers stay within 1.2 dB of each other.","headline":"Voices and treble are even, left matches right","isDeviation":false,"kind":"rest","strength":0,"tag":"measured","tagLine":"Measured · within 1.2 dB"},{"basis":"roomSize","detail":"41 Hz and 61 Hz are where this room's size makes the bass resonate. That points to the room, though I can't be certain.","headline":"It's the room, not the speakers","isDeviation":false,"kind":"roomCause","strength":0,"tag":"inferred","tagLine":"Inferred from room size. Moving speakers should help."}],"isConclusive":true,"leftRightDifference":1.2,"numbers":[{"kind":"peak","label":"41 Hz","tag":"measured","value":"+5.5 dB","word":"peak"},{"kind":"dip","label":"61 Hz","tag":"measured","value":"−3.9 dB","word":"dip"},{"kind":"leftRight","label":"L / R","tag":"measured","value":"±1.2 dB","word":"match"},{"kind":"distortion","label":"1 kHz","tag":"measured","value":"0.4 %","word":"distortion"},{"kind":"decay","label":"< 80 Hz","tag":"estimate","value":"≈ 0.5 s","word":"decay"}],"requiredSpotCount":3,"schemaVersion":1,"spotCurves":[null,null,null],"spots":[{"left":{"valid":{"signalToNoise":49.1}},"right":{"valid":{"signalToNoise":49.5}}},{"left":{"valid":{"signalToNoise":49.0}},"right":{"valid":{"signalToNoise":49.4}}},{"left":{"valid":{"signalToNoise":48.9}},"right":{"valid":{"signalToNoise":49.3}}}],"validSpotCount":3,"verdict":"From your seat, the bass is uneven. The rest is balanced."}"#
    private static let worseAfterJSON = #"{"curve":[0,0,0,0,0,0,0,0,0,0,0,0,0,0.0,0.0,0.0,0.0,0.0,0.0,0.2,0.7,1.9,4.3,7.6,10.7,11.9,10.4,7.2,4.0,1.7,0.6,0.1,-0.0,-0.3,-1.1,-3.1,-6.6,-11.1,-14.8,-15.6,-13.1,-8.7,-4.6,-1.9,-0.6,-0.2,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"evenBandDecibels":3,"extremes":[{"deviation":11.9,"frequency":41.0,"kind":"peak","range":{"lower":37.1,"upper":45.3},"spread":0},{"deviation":-15.7,"frequency":61.0,"kind":"dip","range":{"lower":54.7,"upper":68.2},"spread":0}],"findings":[{"detail":"41 Hz is 12 dB louder than the middle. 61 Hz is 16 dB quieter.","headline":"One bass note booms, one nearly vanishes","isDeviation":true,"kind":"bass","strength":15.7,"tag":"measured","tagLine":"Measured"},{"detail":"Above the bass, everything stays within 3 dB of the middle. Above the bass, the two speakers stay within 0.0 dB of each other.","headline":"Voices and treble are even, left matches right","isDeviation":false,"kind":"rest","strength":0,"tag":"measured","tagLine":"Measured · within 0.0 dB"}],"isConclusive":true,"leftRightDifference":0,"numbers":[{"kind":"peak","label":"41 Hz","tag":"measured","value":"+11.9 dB","word":"peak"},{"kind":"dip","label":"61 Hz","tag":"measured","value":"−15.7 dB","word":"dip"},{"kind":"leftRight","label":"L / R","tag":"measured","value":"±0.0 dB","word":"match"}],"requiredSpotCount":3,"schemaVersion":1,"spotCurves":[null,null,null],"spots":[{"left":{"valid":{"signalToNoise":40}},"right":{"valid":{"signalToNoise":40}}},{"left":{"valid":{"signalToNoise":40}},"right":{"valid":{"signalToNoise":40}}},{"left":{"valid":{"signalToNoise":40}},"right":{"valid":{"signalToNoise":40}}}],"validSpotCount":3,"verdict":"From your seat, the bass is uneven. The rest is balanced."}"#
    private static let evenJSON = #"{"bassDecay":{"lower":20,"seconds":0.2,"upper":80},"curve":[-3.8,-3.8,-3.5,-3.2,-2.9,-2.6,-2.3,-2.0,-1.8,-1.6,-1.3,-1.2,-1.0,-0.8,-0.6,-0.5,-0.4,-0.3,-0.2,-0.1,0.0,0.1,0.1,0.2,0.2,0.3,0.3,0.3,0.3,0.3,0.3,0.3,0.3,0.3,0.3,0.2,0.2,0.2,0.1,0.1,0.0,-0.0,-0.1,-0.2,-0.2,-0.3,-0.4,-0.5,-0.5,-0.6,-0.7,-0.8,-0.9,-1.0,-1.1,-1.2,-1.3,-1.4,-1.5,-1.6,-1.7,-1.7,-1.8,-1.9,-1.9,-1.9,-1.9,-1.9,-1.9,-1.8,-1.7,-1.6,-1.5,-1.4,-1.2,-1.0,-0.9,-0.7,-0.5,-0.3,-0.1,0.1,0.3,0.4,0.6,0.7,0.8,0.8,0.9,0.9,0.9,0.9,0.8,0.7,0.6,0.5,0.3,0.2,-0.0,-0.2,-0.3,-0.4,-0.5,-0.6,-0.6,-0.5,-0.5,-0.4,-0.3,-0.2,-0.1,-0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.1,0.1,0.1,0.2,0.1,0.1,-0.0,-0.1,-0.2,-0.2,-0.2,-0.2,-0.1,-0.0,0.1,0.1,0.1,0.1,0.1,-0.0,-0.1,-0.2,-0.2,-0.1,0.1,0.1,0.0,-0.1,-0.2,-0.1,0.1,0.2,-0.0,-0.2,-0.2,0.0,0.2,0.1,-0.1,-0.2,-0.1,0.0,0.1,0.0,-0.1,-0.1,0.0,0.0,-0.0,-0.0,-0.1,-0.0,0,-0.1,0.0,-0.0,-0.1,0.0,-0.0,-0.1,-0.0,0.0,-0.1,-0.0,0.0,-0.1,-0.0,-0.0,-0.0,-0.1,0.0,-0.1,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,0.0,-0.0,-0.0,-0.0,-0.0,-0.0,0.0,-0.0,-0.1,-0.1,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0,-0.0],"distortionPercent":0.4,"evenBandDecibels":3,"extremes":[],"findings":[{"detail":"Above the bass, everything stays within 3 dB of the middle. Above the bass, the two speakers stay within 0.0 dB of each other.","headline":"Voices and treble are even, left matches right","isDeviation":false,"kind":"rest","strength":0,"tag":"measured","tagLine":"Measured · within 0.0 dB"}],"isConclusive":true,"leftRightDifference":0.0,"numbers":[{"kind":"leftRight","label":"L / R","tag":"measured","value":"±0.0 dB","word":"match"},{"kind":"distortion","label":"1 kHz","tag":"measured","value":"0.4 %","word":"distortion"},{"kind":"decay","label":"< 80 Hz","tag":"estimate","value":"≈ 0.2 s","word":"decay"}],"requiredSpotCount":3,"schemaVersion":1,"spotCurves":[null,null,null],"spots":[{"left":{"valid":{"signalToNoise":48.9}},"right":{"valid":{"signalToNoise":48.9}}},{"left":{"valid":{"signalToNoise":48.9}},"right":{"valid":{"signalToNoise":48.9}}},{"left":{"valid":{"signalToNoise":48.9}},"right":{"valid":{"signalToNoise":48.9}}}],"validSpotCount":3,"verdict":"From your seat, it all sounds even."}"#
    private static let improvedJSON = #"{"isConclusive":true,"nextTarget":{"deviation":5.5,"frequency":41.0,"kind":"peak","range":{"lower":38.6,"upper":43.6},"spread":2.2},"note":"All measured just now. The 41 Hz boom is still a little strong; the next suggestion targets it.","outcome":"improved","rows":[{"after":"−4 dB","afterDecibels":-3.9,"before":"−11 dB","beforeDecibels":-11.4,"change":"improved","frequency":61.2,"label":"Missing note, 61 Hz","tag":"measured"},{"after":"+5 dB","afterDecibels":5.4,"before":"+9 dB","beforeDecibels":9.2,"change":"improved","frequency":41.0,"label":"Booming note, 41 Hz","tag":"measured"},{"afterDecibels":0,"beforeDecibels":0,"change":"unchanged","label":"Voices and treble","status":"Unchanged, still even","tag":"measured"}],"schemaVersion":1,"tag":"measured","verdict":"The missing bass note is back."}"#
    private static let worseJSON = #"{"isConclusive":true,"nextTarget":{"deviation":-15.7,"frequency":61.0,"kind":"dip","range":{"lower":54.7,"upper":68.2},"spread":0},"note":"All measured just now. Putting the speaker back where it was is the safe choice.","outcome":"worse","rows":[{"after":"+12 dB","afterDecibels":11.8,"before":"+9 dB","beforeDecibels":9.2,"change":"worse","frequency":41.0,"label":"Booming note, 41 Hz","tag":"measured"},{"after":"−16 dB","afterDecibels":-15.6,"before":"−11 dB","beforeDecibels":-11.4,"change":"worse","frequency":61.2,"label":"Missing note, 61 Hz","tag":"measured"},{"afterDecibels":0,"beforeDecibels":0,"change":"unchanged","label":"Voices and treble","status":"Unchanged, still even","tag":"measured"}],"schemaVersion":1,"tag":"measured","verdict":"It sounds worse from your seat than before."}"#
    private static let unchangedJSON = #"{"isConclusive":true,"nextTarget":{"deviation":-11.4,"frequency":61.2,"kind":"dip","range":{"lower":53.7,"upper":71.6},"spread":3.7},"note":"All measured just now. The 61 Hz dip is still deep; the next suggestion targets it.","outcome":"unchanged","rows":[{"after":"+9 dB","afterDecibels":9.1,"before":"+9 dB","beforeDecibels":9.2,"change":"unchanged","frequency":41.0,"label":"Booming note, 41 Hz","tag":"measured"},{"after":"−11 dB","afterDecibels":-11.3,"before":"−11 dB","beforeDecibels":-11.4,"change":"unchanged","frequency":61.2,"label":"Missing note, 61 Hz","tag":"measured"},{"afterDecibels":0,"beforeDecibels":0,"change":"unchanged","label":"Voices and treble","status":"Unchanged, still even","tag":"measured"}],"schemaVersion":1,"tag":"measured","verdict":"Nothing changed that I can measure."}"#
}
#endif
