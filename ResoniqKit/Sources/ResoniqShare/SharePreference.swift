import Foundation

/// "Share recordings for research" in Settings: off until the person confirms the consent screen. Kept in
/// `UserDefaults`, as `RecordingPreference` keeps "Keep recordings".
///
/// Turning it on records when, and which version of the consent screen was confirmed. Reading never writes anything.
/// Sharing counts as on only while the recorded version is the current one: when the consent screen says something new,
/// `currentConsentVersion` goes up and sharing is off again until the person confirms the new words.
public struct SharePreference {
    /// The version of the consent screen's words. Raise it whenever what is sent, or where it goes, changes.
    public static let currentConsentVersion = 1

    public static let key = "shareRecordings"
    public static let consentDateKey = "shareRecordings.consentDate"
    public static let consentVersionKey = "shareRecordings.consentVersion"

    public struct Consent: Sendable, Equatable {
        public var date: Date
        public var version: Int
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether kept tests are shared now.
    public var isOn: Bool {
        defaults.bool(forKey: Self.key) && defaults.integer(forKey: Self.consentVersionKey) == Self.currentConsentVersion
    }

    /// The last consent given, kept after sharing is turned off; nil if it was never given.
    public var consent: Consent? {
        guard let date = defaults.object(forKey: Self.consentDateKey) as? Date else { return nil }
        return Consent(date: date, version: defaults.integer(forKey: Self.consentVersionKey))
    }

    /// The person confirmed the consent screen (and nothing else calls this).
    public func turnOn(consentedAt date: Date = .now) {
        defaults.set(date, forKey: Self.consentDateKey)
        defaults.set(Self.currentConsentVersion, forKey: Self.consentVersionKey)
        defaults.set(true, forKey: Self.key)
    }

    public func turnOff() {
        defaults.set(false, forKey: Self.key)
    }
}
