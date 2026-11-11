import Foundation
import Security

/// Device tokens for server profiles, in the Keychain only (§6). Like
/// `PeerKeyStore`, items are `WhenUnlockedThisDeviceOnly` and there is no
/// plaintext fallback: if the Keychain fails, signing in fails.
enum ServerTokenStore {
    static let service = "com.flactastic.server.token"

    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
    }

    static func store(_ token: String, for profileID: UUID) throws {
        try delete(profileID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Nil when no token is stored; throws only when the Keychain itself fails.
    static func token(for profileID: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    static func delete(_ profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
