import Foundation

/// Where the service is, from the build setting `RESONIQ_SHARE_URL` (read through `Info.plist`). A build without a
/// usable URL has no sharing at all: `init` returns nil, so the app makes no client, no transport and no queue, and
/// Settings shows no row.
///
/// Usable means `https://` with a host, or `http://` to `localhost` or `127.0.0.1` for a Worker run on the Mac with
/// `wrangler dev`. Anything else (empty, blank, an unexpanded `$(RESONIQ_SHARE_URL)`, another scheme) is no URL.
public struct ShareConfiguration: Sendable, Equatable {
    /// The `Info.plist` key that carries the build setting.
    public static let infoKey = "ResoniqShareURL"

    public let baseURL: URL

    public init?(baseURLString: String?) {
        guard let text = baseURLString?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.contains("$("),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil, components.user == nil, components.password == nil,
              let url = components.url
        else { return nil }
        let isLocal = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && isLocal) else { return nil }
        baseURL = url
    }

    /// The configuration of the running app, or nil when its build has none.
    public static func main(bundle: Bundle = .main) -> ShareConfiguration? {
        ShareConfiguration(baseURLString: bundle.object(forInfoDictionaryKey: infoKey) as? String)
    }
}
