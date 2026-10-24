import Foundation
import Security

/// Thin wrapper around the Keychain Services API for storing small secrets (PM2 env
/// vars) locally and encrypted, instead of in the plaintext JSON files under
/// Application Support. Scoped to this app via a fixed service name.
enum KeychainService {
    private static let service = "com.virus-dev-official.vpsmanager"

    static func save(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary) // clear any existing value first — SecItemAdd fails if one exists
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// PM2 env vars specifically — these are the one place in the app likely to hold
/// real secrets (DB passwords, API keys, JWT secrets), so they get their own
/// dedicated Keychain-backed store rather than living in plaintext JSON.
enum SecretsStore {
    private static func account(for configID: UUID) -> String { "pm2env-\(configID.uuidString)" }

    static func saveEnv(_ env: [String: String], for configID: UUID) {
        guard let data = try? JSONEncoder().encode(env) else { return }
        KeychainService.save(data, account: account(for: configID))
    }

    static func loadEnv(for configID: UUID) -> [String: String] {
        guard let data = KeychainService.load(account: account(for: configID)),
              let env = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return env
    }

    static func deleteEnv(for configID: UUID) {
        KeychainService.delete(account: account(for: configID))
    }
}