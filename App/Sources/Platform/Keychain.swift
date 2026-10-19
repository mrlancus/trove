import Foundation
import Security

/// Minimal generic-password Keychain wrapper. The vault keys and relay device token live here and
/// nowhere else on disk.
///
/// The data protection keychain needs a signed app with a team. The Mac app built on CI is only
/// ad-hoc signed (no Apple Silicon Mac to sign with), so there it gets errSecMissingEntitlement and
/// falls back to the login keychain, which still keeps the secrets encrypted and per-user.
enum Keychain {
    static let service = "com.mrlancus.trove"

    private static func base(_ account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    /// Data protection keychain first; on macOS also the login keychain when that isn't allowed.
    private static var modes: [Bool] {
        #if os(macOS)
        [true, false]
        #else
        [true]
        #endif
    }

    static func set(_ data: Data, for account: String) throws {
        var last: OSStatus = errSecSuccess
        for dataProtection in modes {
            let query = base(account, dataProtection: dataProtection)
            SecItemDelete(query as CFDictionary)
            var add = query
            add[kSecValueData as String] = data
            // Available after first unlock so background sync/enrichment can run; never syncs via iCloud Keychain.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            last = SecItemAdd(add as CFDictionary, nil)
            if last == errSecSuccess { return }
            if last != errSecMissingEntitlement { break }
        }
        throw KeychainError(status: last)
    }

    static func get(_ account: String) -> Data? {
        for dataProtection in modes {
            var query = base(account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data { return data }
        }
        return nil
    }

    static func delete(_ account: String) {
        for dataProtection in modes { SecItemDelete(base(account, dataProtection: dataProtection) as CFDictionary) }
    }

    static func setCodable<T: Encodable>(_ value: T, for account: String) throws {
        try set(JSONEncoder().encode(value), for: account)
    }

    static func codable<T: Decodable>(_ type: T.Type, for account: String) -> T? {
        get(account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    struct KeychainError: Error, CustomStringConvertible {
        var status: OSStatus
        var description: String { "Keychain error \(status)" }
    }
}
