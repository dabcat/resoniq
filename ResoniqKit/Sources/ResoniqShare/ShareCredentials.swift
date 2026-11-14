import Foundation
import Security
import Synchronization

/// Where the installation's id and token are kept between launches. The Keychain in the app; memory in tests.
public protocol ShareCredentialStore: Sendable {
    func load() -> ShareInstallation?
    func save(_ installation: ShareInstallation) throws
    func delete()
}

/// The installation in the Keychain: one generic password item holding the id and the token together, readable after
/// the phone's first unlock, on this device only (never synced to iCloud Keychain, never restored to another phone).
///
/// A Keychain item outlives the app's deletion. That is on purpose: a person who deletes Resoniq and installs it again
/// can still "Delete what I shared".
public struct KeychainShareCredentials: ShareCredentialStore {
    public static let service = "com.matovic.resoniq.share"
    static let account = "installation"

    public init() {}

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func load() -> ShareInstallation? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ShareInstallation.self, from: data)
    }

    public func save(_ installation: ShareInstallation) throws {
        let data = try JSONEncoder().encode(installation)
        delete()
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// The installation in memory, for tests and previews.
public final class MemoryShareCredentials: ShareCredentialStore {
    private let stored: Mutex<ShareInstallation?>

    public init(_ installation: ShareInstallation? = nil) {
        stored = Mutex(installation)
    }

    public func load() -> ShareInstallation? { stored.withLock { $0 } }
    public func save(_ installation: ShareInstallation) throws { stored.withLock { $0 = installation } }
    public func delete() { stored.withLock { $0 = nil } }
}
