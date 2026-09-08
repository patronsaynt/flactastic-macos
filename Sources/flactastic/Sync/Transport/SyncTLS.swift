import Foundation
import Network
import CryptoKit

/// Builds the TLS parameters for a sync connection.
///
/// ### Why pre-shared keys rather than certificates
/// Mutual authentication between two devices that already share a secret is
/// exactly what TLS-PSK is for. The alternative — generating a self-signed
/// `SecIdentity` per device and pinning it — means hand-rolling certificate
/// creation through the Security framework, which is a great deal of code, is
/// meaningfully different between macOS and iOS, and would then need its own
/// trust-evaluation callback anyway. PSK is a few lines, is identical API on
/// both platforms, and authenticates *both* directions for free: a peer that
/// does not hold the paired key cannot complete the handshake at all, so
/// revoking a device by deleting its key is absolute rather than advisory.
///
/// ### The pairing channel
/// First contact has no shared secret yet, so it uses a **fixed, publicly
/// known** PSK. That provides encryption against a passive eavesdropper and
/// nothing else — it is explicitly *not* authentication, and an active attacker
/// can complete it just as easily as a real peer. All of the security for that
/// phase comes from the commitment protocol in `PairingCrypto`, which is
/// designed for exactly this: an unauthenticated channel plus a short code.
/// Nothing but pairing messages may ever cross a pairing-PSK connection.
enum SyncTLS {

    /// PSK identity for a pairing connection. Paired connections instead use
    /// the connecting device's own ID, so the listener can register one key per
    /// peer and TLS itself picks the right one.
    private static let pairingIdentity = "flactastic-pairing-v1"

    private static func pairedIdentity(for deviceID: UUID) -> String {
        "flactastic-peer-v1:\(deviceID.uuidString)"
    }

    /// The public pairing key. Being in the source is not a weakness — see the
    /// note above. It exists so the pairing handshake runs over TLS rather than
    /// cleartext, not to authenticate anyone.
    private static var pairingKey: SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("flactastic-public-pairing-key-v1".utf8)))
    }

    // MARK: - Parameters

    /// Parameters for dialling an already-paired peer.
    ///
    /// The identity is **our own** device ID, because that is the key the peer
    /// filed us under. It travels in the clear in the TLS handshake, which is
    /// why the ID is a random UUID rather than anything about the user.
    static func pairedParameters(key: SymmetricKey, localDeviceID: UUID) -> NWParameters {
        parameters(key: key, identity: pairedIdentity(for: localDeviceID))
    }

    /// Parameters for a listener, carrying one PSK per paired peer plus, when
    /// the user has a code on screen, the public pairing key.
    ///
    /// Registering every paired key up front is what makes revocation absolute:
    /// a device whose key has been deleted is simply not in this list, so its
    /// TLS handshake cannot complete at all. There is no application-level
    /// check to forget.
    static func listenerParameters(
        pairedKeys: [UUID: SymmetricKey],
        allowPairing: Bool
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        for (deviceID, key) in pairedKeys.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            addPSK(key: key, identity: pairedIdentity(for: deviceID), to: tls)
        }
        if allowPairing {
            addPSK(key: pairingKey, identity: pairingIdentity, to: tls)
        }
        return assemble(tls: tls)
    }

    /// Parameters for first contact. Encryption only; authentication comes from
    /// the pairing handshake carried inside.
    static func pairingParameters() -> NWParameters {
        parameters(key: pairingKey, identity: pairingIdentity)
    }

    private static func parameters(key: SymmetricKey, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        addPSK(key: key, identity: identity, to: tls)
        return assemble(tls: tls)
    }

    private static func addPSK(key: SymmetricKey, identity: String, to tls: NWProtocolTLS.Options) {
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            dispatchData(key.withUnsafeBytes { Data($0) }),
            dispatchData(Data(identity.utf8))
        )
    }

    private static func assemble(tls: NWProtocolTLS.Options) -> NWParameters {
        // PSK requires naming the ciphersuite explicitly; AES-128-GCM-SHA256 is
        // the AEAD suite available for PSK on both platforms.
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t.AES_128_GCM_SHA256
        )
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        // A stalled transfer should surface as an error the user can act on
        // rather than a spinner that never resolves.
        tcp.connectionTimeout = 15
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    /// `sec_protocol_options_add_pre_shared_key` takes the Objective-C
    /// `dispatch_data_t`. Swift's `DispatchData` reaches it through the
    /// `__DispatchData` bridge rather than a plain `as` cast.
    private static func dispatchData(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}
