import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// Which file is playing, told from its timing, when the player does not play it exactly as written: many DACs and
/// receivers mute the first few hundred milliseconds of sound after silence, and some players skip the tone.
@MainActor
@Suite(.timeLimit(.minutes(5))) struct ExternalFileIdentityTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var kind: TestSoundFile.Kind
        var mute: Double
        var testDescription: String { "\(ExternalSessionText.fileTitle(for: kind)), first \(mute) s of the tone muted" }
    }

    nonisolated static let cases: [Case] = TestSoundFile.allKinds.flatMap { kind in [0.3, 0.5, 1.0].map { Case(kind: kind, mute: $0) } }

    /// Every sweep the listener hears in `signal`, with the identity it gave it, and the files it took the play for.
    static func listen(_ signal: [Float], expecting kind: TestSoundFile.Kind) -> (identities: [SweepIdentity?], wrong: [TestSoundFile.Kind]) {
        var listener = ExternalListener(sampleRate: 48000, sweep: Fixture.sweep, expected: kind, configuration: Fixture.configuration)
        var identities: [SweepIdentity?] = []
        var wrong: [TestSoundFile.Kind] = []
        var position = 0
        while position + 4800 <= signal.count {
            let block = CapturedBlock(position: Int64(position), samples: Array(signal[position..<(position + 4800)]))
            for event in listener.consume(block, steady: true) {
                if case .sweepStarted(_, let identity) = event { identities.append(identity) }
                if case .wrongFile(_, let heard) = event { wrong.append(heard) }
            }
            position += 4800
        }
        // The identities as they stand at the end: a later sweep's spacing may have relabelled earlier ones.
        let final = listener.plays.flatMap { $0.sweeps.map(\.identity) }
        return (final.count == identities.count ? final : identities, wrong)
    }

    static func muted(_ kind: TestSoundFile.Kind, by seconds: Double, room: DenseRoom? = nil) -> [Float] {
        heardFile(TestSoundFile(kind: kind), after: 10, room: room) { mono, layout in
            for index in layout.tone.offset..<(layout.tone.offset + Int(seconds * 48000)) { mono[index] = 0 }
        }
    }

    static func expected(_ kind: TestSoundFile.Kind) -> [SweepIdentity?] {
        TestSoundFile(kind: kind).layout.sweeps.indices.map { SweepIdentity(kind: kind, index: $0) }
    }

    @Test(arguments: cases)
    func `a muted start of the tone does not change which file it is`(testCase: Case) {
        let heard = Self.listen(Self.muted(testCase.kind, by: testCase.mute), expecting: testCase.kind)
        #expect(heard.identities == Self.expected(testCase.kind))
        #expect(heard.wrong.isEmpty, "taken for \(heard.wrong.map(ExternalSessionText.fileTitle(for:)))")
    }

    @Test func `a muted start in a reverberant room does not change which file it is`() {
        for kind in TestSoundFile.allKinds {
            let heard = Self.listen(Self.muted(kind, by: 0.5, room: DenseRoom(directToReverberant: -8, reverberationTime: 0.8)), expecting: kind)
            #expect(heard.identities == Self.expected(kind), "\(ExternalSessionText.fileTitle(for: kind))")
            #expect(heard.wrong.isEmpty)
        }
    }

    /// Without the tone the spacing of two sweeps tells the file; the seat file of one speaker has one sweep, so it is
    /// told only by the tone and stays unplaced without it.
    @Test(arguments: TestSoundFile.allKinds)
    func `without the tone the spacing tells the file`(kind: TestSoundFile.Kind) {
        let silent = heardFile(TestSoundFile(kind: kind), after: 10) { mono, layout in
            for index in layout.tone.offset..<(layout.tone.offset + layout.tone.count) { mono[index] = 0 }
        }
        let heard = Self.listen(silent, expecting: kind)
        if TestSoundFile(kind: kind).layout.sweeps.count > 1 {
            #expect(heard.identities == Self.expected(kind))
        } else {
            #expect(heard.identities == [nil])
        }
        #expect(heard.wrong.isEmpty)
    }

    /// The review's case, through the whole session: the right speaker's file with the tone's first half second
    /// muted was announced as the left speaker's.
    @Test func `the right speaker's file with a muted tone start is measured, not refused`() async throws {
        let signal = Self.muted(.speakerTest(.right), by: 0.5)
        let session = ExternalMeasurementSession(
            io: PreparedAudioIO(signal), channel: .right, permission: SimulatedMicrophonePermission(.granted),
            stillness: ConstantStillnessMonitor(), configuration: Fixture.configuration
        )
        let log = ExternalStateLog(session)
        let final = await session.run()
        #expect(final.result?.runs.count == 3, "\(log.summary)")
        #expect(log.anotherPlays.isEmpty, "\(log.summary)")
    }

    /// When the tone's timing points to one file and the sweeps' spacing to another, the spacing decides.
    @Test func `the sweeps' spacing overrules the tone's timing`() {
        // The left file's sweeps, with its tone moved half a second earlier: the tone's timing reads as the right
        // file's at the first sweep, the spacing as the left file's from the second.
        let file = TestSoundFile(kind: .speakerTest(.left))
        let shifted = heardFile(file, after: 10) { mono, layout in
            let range = layout.tone.offset..<(layout.tone.offset + layout.tone.count)
            let tone = Array(mono[range])
            for index in range { mono[index] = 0 }
            mono.replaceSubrange((range.lowerBound - 24000)..<(range.upperBound - 24000), with: tone)
        }
        let heard = Self.listen(shifted, expecting: .speakerTest(.left))
        #expect(heard.wrong == [.speakerTest(.right)])
        #expect(heard.identities == Self.expected(.speakerTest(.left)))
    }
}
