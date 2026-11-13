import Foundation

/// Where the "intro finished" flag lives.
public protocol IntroFlagStore {
    var isFinished: Bool { get nonmutating set }
}

/// The flag in `UserDefaults`.
public struct UserDefaultsIntroFlag: IntroFlagStore {
    public static let key = "introFinished"
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isFinished: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// Whether the three intro screens are shown: until they have been finished (or skipped) once. Settings can
/// show them again with `reset()`; a debug build's launch argument `-resetIntro YES` does the same at launch.
public struct IntroGate {
    private let flag: any IntroFlagStore

    public init(flag: any IntroFlagStore = UserDefaultsIntroFlag()) {
        self.flag = flag
    }

    /// The gate on the standard defaults, reset first when `resetRequested`. The Kit cannot see the app's build
    /// configuration, so it never reads a launch argument itself: the app reads `-resetIntro` under `#if DEBUG` and
    /// passes the answer in, and a Release build always passes false.
    public static func standard(defaults: UserDefaults = .standard, resetRequested: Bool = false) -> IntroGate {
        let gate = IntroGate(flag: UserDefaultsIntroFlag(defaults))
        if resetRequested { gate.reset() }
        return gate
    }

    public var isShown: Bool { !flag.isFinished }

    /// After "Try it on a speaker" or "Skip intro".
    public func finish() { flag.isFinished = true }

    /// "Show the intro again".
    public func reset() { flag.isFinished = false }
}
