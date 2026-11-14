import Foundation

extension RecordingManifest {
    /// The manifest as it may leave the phone ("Share recordings for research", phase 10): everything that describes
    /// the measurement, nothing that names the person, their home or their devices.
    ///
    /// | Field | Shared as |
    /// |---|---|
    /// | `createdAt` | The day only: the calendar day in `calendar`'s time zone, written as midnight UTC, so neither the time of day nor the time zone goes |
    /// | `audioRoute` | Each route's kind; its name (it can hold a person's or a device's name) is left out |
    /// | `system` | Its kind; the name the person typed is left out |
    /// | `room` | Left out: its only field is the name the person typed |
    /// | `speaker` | Position and channel; make, model and unit id (never written yet, and free text once they are) are left out |
    /// | `label` | Its value, how and confidence; `givenBy` (a person) is left out |
    /// | `device` | Kept: the hardware model ("iPhone18,2"), the system and its version, the app's version. The device's given name is never read, here or anywhere |
    /// | everything else | Kept: the sweep, the noise floor, each run's numbers and check, and the report, which is made from the measurement alone |
    ///
    /// A field added to the manifest later is kept by default here, so the test of this function lists every field and
    /// fails until the new one is decided (`SharedManifestTests`).
    public func shared(calendar: Calendar = .current) -> RecordingManifest {
        var shared = self
        shared.createdAt = Self.day(of: createdAt, in: calendar)
        shared.audioRoute = Route(
            output: audioRoute.output.map { Route.Output(kind: $0.kind) },
            input: audioRoute.input.map { Route.Input(kind: $0.kind) }
        )
        shared.system = System(name: nil, kind: system.kind)
        shared.room = nil
        shared.speaker = Speaker(position: speaker.position, channel: speaker.channel)
        shared.label = label.map { Label(value: $0.value, givenBy: nil, how: $0.how, confidence: $0.confidence) }
        return shared
    }

    /// Midnight UTC of the day `date` falls on in `calendar`'s time zone.
    static func day(of date: Date, in calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return utc.date(from: DateComponents(year: components.year, month: components.month, day: components.day)) ?? date
    }
}
