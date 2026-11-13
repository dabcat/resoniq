import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

@MainActor
@Suite struct ExternalSessionTextTests {
    let left = TestSoundFile.Kind.speakerTest(.left)

    @Test func `the speaker test says what is happening`() {
        #expect(ExternalSessionText.headline(for: .waitingForSound, runCount: 3) == "Press play now.")
        #expect(ExternalSessionText.headline(for: .hearing(run: 2), runCount: 3) == "Listening to run 2 of 3.")
        #expect(ExternalSessionText.headline(for: .needsAnotherPlay(have: 2, reason: nil), runCount: 3) == "Play the file once more.")
        #expect(ExternalSessionText.waitingLine(isSilenceLong: false, file: left)
            == "Play \"Resoniq test sound - left speaker.wav\" on your system. I'll find the tones by myself, whenever they start.")
        #expect(ExternalSessionText.waitingLine(isSilenceLong: true, file: left)
            == "I can't hear the test sound yet. Check that \"Resoniq test sound - left speaker.wav\" is playing, that the volume is up and that your amplifier is on the right input.")
    }

    @Test func `another play says why`() {
        #expect(ExternalSessionText.anotherPlayText(.run(.unusable(.clipped(ClippingDetector.detect([1, 1, 1, 1])))), have: 2, needed: 3, file: left)
            == "I have 2 of 3. One was too loud and the microphone clipped it. Turn the volume down a little, then play the file again from the start.")
        #expect(ExternalSessionText.anotherPlayText(.wrongFile(heard: .speakerTest(.right)), have: 0, needed: 3, file: left)
            == "That sounds like the right speaker file. Please play \"Resoniq test sound - left speaker.wav\" instead.")
        #expect(ExternalSessionText.anotherPlayText(.clockUnknown, have: 0, needed: 3, file: left).contains("short tone at the start"))
    }

    @Test func `every failure has words, cancelled none`() {
        let failures: [ExternalMeasurementFailure] = [
            .nothingHeard, .playerClockOff(ratio: 1.088), .listeningTimeUp(lastProblem: .missedSweeps),
            .measurement(.permissionDenied), .measurement(.interrupted), .measurement(.tooNoisy), .measurement(.phoneNeverStill),
        ]
        for failure in failures {
            #expect(!ExternalSessionText.failureHeadline(failure).isEmpty, "\(failure)")
            #expect(!ExternalSessionText.failureBody(failure, file: left).isEmpty, "\(failure)")
        }
        #expect(ExternalSessionText.failureHeadline(.measurement(.cancelled)).isEmpty)
        #expect(ExternalSessionText.failureBody(.playerClockOff(ratio: 1.088), file: left).hasPrefix("It plays the file 8.8 % fast"))
    }

    @Test func `the seat says what is happening`() {
        #expect(ExternalSessionText.seatHeadline(for: .waitingForSound(spot: .left), wait: nil, channels: [.left, .right]) == "Press play now.")
        #expect(ExternalSessionText.seatHeadline(for: .hearing(spot: .seat, channel: .right), wait: nil, channels: [.left, .right])
            == "Hold still. The right speaker is playing.")
        #expect(ExternalSessionText.seatHeadline(for: .waitingForStillness(spot: .left), wait: .waitingForMove, channels: [.left, .right])
            == "Now move the phone 30 cm to your left.")
    }
}
