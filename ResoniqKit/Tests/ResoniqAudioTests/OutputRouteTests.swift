import Foundation
import Testing
@testable import ResoniqAudio

/// With nothing connected the sound comes out of the phone itself; measuring that as "your left speaker" would be
/// wrong, so every measurement fails before any sound and says why.
@MainActor
@Suite struct OutputRouteTests {
    static func io(_ kind: AudioOutputRoute.Kind) -> SimulatedAudioIO {
        SimulatedAudioIO(configuration: .init(
            pacing: .immediate,
            outputRoute: AudioOutputRoute(kind: kind, name: "Simulated \(kind)")
        ))
    }

    @Test(arguments: [AudioOutputRoute.Kind.builtInReceiver, .builtInSpeaker])
    func `a speaker test through the phone itself fails before any sound`(kind: AudioOutputRoute.Kind) async {
        let io = Self.io(kind)
        let final = await Fixture.session(io: io).run()
        #expect(final == .failed(.speakersNotConnected(AudioOutputRoute(kind: kind, name: "Simulated \(kind)"))))
        #expect(io.scheduledBufferCount == 0 && !io.isRunning)
    }

    @Test func `a seat measurement through the phone itself fails before any sound`() async {
        let io = Self.io(.builtInReceiver)
        let final = await SeatFixture.session(io: io).run()
        guard case .failed(.speakersNotConnected) = final else {
            Issue.record("ended \(final)")
            return
        }
        #expect(io.scheduledBufferCount == 0 && !io.isRunning)
    }

    @Test func `hold to hear through the phone itself says so`() async {
        let io = Self.io(.builtInSpeaker)
        await #expect(throws: TonePlayerError.speakersNotConnected) {
            try await TonePlayer(io: io).start(frequency: 440, on: .left)
        }
        #expect(io.scheduledBufferCount == 0 && !io.isRunning)
    }

    @Test(arguments: [AudioOutputRoute.Kind.wired, .bluetooth, .airPlay, .other])
    func `the user's own speakers are measured`(kind: AudioOutputRoute.Kind) {
        #expect(!AudioOutputRoute(kind: kind, name: "x").isPhone)
    }

    @Test func `the simulated IO reports its route, simulated speakers by default`() {
        #expect(SimulatedAudioIO().outputRoute == .simulatedSpeakers)
        #expect(Self.io(.wired).outputRoute?.kind == .wired)
    }
}
