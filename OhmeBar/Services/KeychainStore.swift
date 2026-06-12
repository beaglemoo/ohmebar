import Foundation
import Security

/// Stores the Ohme account password in the macOS Keychain.
/// The email lives in UserDefaults; only the password is a secret.
enum KeychainStore {
    private static let service = "com.cb.ohmebar"
    private static let ohmePasswordAccount = "ohme-password"
    static let bmwRefreshTokenAccount = "bmw-refresh-token"

    static var email: String? {
        get { UserDefaults.standard.string(forKey: "ohmeEmail") }
        set { UserDefaults.standard.set(newValue, forKey: "ohmeEmail") }
    }

    static func savePassword(_ password: String) {
        save(password, account: ohmePasswordAccount)
    }

    static func loadPassword() -> String? {
        load(account: ohmePasswordAccount)
    }

    static func deletePassword() {
        delete(account: ohmePasswordAccount)
    }

    // MARK: - Generic secret storage

    static func save(_ secret: String, account: String) {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
