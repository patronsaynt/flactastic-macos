import Foundation
import Security
import CryptoKit

/// Keychain storage for the long-term key shared with each paired device.
///
/// ### Why the Keychain, given `SpotifyAuthController` deliberately avoids it
/// That decision (see `Networking/SpotifyAuthController.swift`) is sound for
/// what it covers: an ad-hoc-signed build changes code identity between
/// rebuilds, so a Keychain ACL re-prompts constantly, and an OAuth token that
/// only reaches a public playlist API is not worth that friction.
///
/// A sync key is a different proposition. It authenticates a peer that may
/// write files into the user's library, and it is long-lived rather than
/// refreshable. `UserDefaults` is a world-readable plist in the user's home
/// directory: any process running as the user, any backup, and any support
/// bundle would carry it. So this store uses the Keychain and accepts the
/// prompt on ad-hoc builds. There is deliberately **no plaintext fallback** —
/// if the Keychain is unavailable, pairing fails loudly rather than quietly
/// downgrading the security of every future connection.
///
/// Items are `ThisDeviceOnly` so they never travel to iCloud Keychain or into
/// an encrypted backup restored onto different hardware. A key is meant to
/// attest "this specific machine"; syncing it elsewhere would defeat that.
enum PeerKeyStore {

    private static let service = "com.flactastic.sync.peerKey"

    enum StoreError: Error, CustomStringConvertible {
        case keychainFailure(OSStatus)
        case malformedStoredKey

        var description: String {
            switch self {
            case .keychainFailure(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(detail)"
            case .malformedStoredKey:
                return "The stored key for this device is unreadable. Pair the device again."
            }
        }
    }

    // MARK: - Write

    /// Stores (or replaces) the key for a peer.
    ///
    /// Delete-then-add rather than `SecItemUpdate`: it is one code path instead
    /// of two, and re-pairing an existing device must overwrite cleanly rather
    /// than fail with a duplicate-item error.
    static func store(key: SymmetricKey, for deviceID: UUID) throws {
        try? delete(deviceID: deviceID)

        let bytes = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID.uuidString,
            kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychainFailure(status) }
    }

    // MARK: - Read

    /// Returns the stored key, or `nil` when this device has never paired with
    /// that peer. Throws only on a genuine Keychain failure, so "not paired"
    /// and "Keychain is broken" stay distinguishable — the first is a normal
    /// state, the second must be shown to the user.
    static func key(for deviceID: UUID) throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else {
                throw StoreError.malformedStoredKey
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.keychainFailure(status)
        }
    }

    static func hasKey(for deviceID: UUID) -> Bool {
        (try? key(for: deviceID)) .flatMap { $0 } != nil
    }

    // MARK: - Delete

    /// Revokes a peer. After this the peer cannot complete a TLS handshake
    /// with us at all — revocation is not advisory.
    static func delete(deviceID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychainFailure(status)
        }
    }

    /// Removes every sync key. Backs "Forget all devices".
    static func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychainFailure(status)
        }
    }
}
