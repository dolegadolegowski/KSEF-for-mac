import Foundation
import Security

/// Dostęp do Keychain. Token KSeF nie jest przechowywany nigdzie indziej —
/// ani w UserDefaults, ani w cache, ani w dzienniku.
enum Keychain {
    static let service = "pl.ksef.faktury.token"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "nieznany błąd"
                return "Błąd Keychain (\(status)): \(msg)"
            }
        }
    }

    /// Zapisuje token dla danego NIP-u. Nadpisuje istniejący wpis.
    static func saveToken(_ token: String, forNip nip: String) throws {
        let account = Nip.normalize(nip)
        guard let data = token.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            Log.shared.registerSecret(token)
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
        Log.shared.registerSecret(token)
    }

    /// Odczytuje token dla danego NIP-u. Zwraca nil, gdy wpisu nie ma.
    static func loadToken(forNip nip: String) throws -> String? {
        let account = Nip.normalize(nip)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        Log.shared.registerSecret(token)
        return token
    }

    /// Usuwa token dla danego NIP-u — wywoływane przy zmianie kontekstu i przy czyszczeniu danych.
    static func deleteToken(forNip nip: String) throws {
        let account = Nip.normalize(nip)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func hasToken(forNip nip: String) -> Bool {
        ((try? loadToken(forNip: nip)) ?? nil) != nil
    }
}
