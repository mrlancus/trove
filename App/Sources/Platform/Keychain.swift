import Foundation
import Security

/// Minimal generic-password Keychain wrapper. The vault keys and relay device token live here and
/// nowhere else on disk.
///
/// The data protection keychain needs a signed app with a team. The Mac app built on CI is signed
/// with Trove's own certificate but has no team, so there it gets errSecMissingEntitlement and falls
/// back to the login keychain, which still keeps the secrets encrypted and per-user. The login
/// keychain asks "Trove wants to access key…" for each item whenever the app's code changes (each
/// update) and for any read it hasn't been allowed yet, so on the Mac every secret lives in **one**
/// item that's read **once** per launch and then served from memory: at most one question per
/// update instead of one per secret per read.
@MainActor
enum Keychain {
    static let service = "com.mrlancus.trove"
    /// The Mac's single item holding every secret (a JSON object of account → base64).
    private static let bundleAccount = "secrets"
    /// What's been read or written this launch, so the keychain is asked once.
    private static var cache: [String: Data] = [:]
    private static var bundleLoaded = false

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

    private static func rawSet(_ data: Data, for account: String) throws {
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

    private static func rawGet(_ account: String) -> Data? {
        for dataProtection in modes {
            var query = base(account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data { return data }
        }
        return nil
    }

    private static func rawDelete(_ account: String) {
        for dataProtection in modes { SecItemDelete(base(account, dataProtection: dataProtection) as CFDictionary) }
    }

    #if os(macOS)
    /// Reads the single item once. Secrets saved by older builds (one item each) move into it.
    private static func loadBundle() {
        guard !bundleLoaded else { return }
        bundleLoaded = true
        if let data = rawGet(bundleAccount), let object = try? JSONDecoder().decode([String: Data].self, from: data) {
            cache.merge(object) { mine, _ in mine }
            return
        }
        var moved = false
        for account in legacyAccounts {
            if let data = rawGet(account) { cache[account] = data; moved = true }
        }
        if moved, (try? saveBundle()) != nil { for account in legacyAccounts { rawDelete(account) } }
    }

    private static func saveBundle() throws {
        try rawSet(JSONEncoder().encode(cache), for: bundleAccount)
    }

    /// The accounts older builds kept as items of their own.
    static let legacyAccounts = ["vault.keys", "relay.deviceToken"]
    #endif

    static func set(_ data: Data, for account: String) throws {
        #if os(macOS)
        loadBundle()
        let before = cache[account]
        cache[account] = data
        do { try saveBundle() } catch { cache[account] = before; throw error }
        #else
        try rawSet(data, for: account)
        cache[account] = data
        #endif
    }

    static func get(_ account: String) -> Data? {
        #if os(macOS)
        loadBundle()
        return cache[account]
        #else
        if let hit = cache[account] { return hit }
        let data = rawGet(account)
        if let data { cache[account] = data }
        return data
        #endif
    }

    static func delete(_ account: String) {
        cache[account] = nil
        #if os(macOS)
        loadBundle()
        if cache.isEmpty { rawDelete(bundleAccount) } else { try? saveBundle() }
        rawDelete(account)
        #else
        rawDelete(account)
        #endif
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
