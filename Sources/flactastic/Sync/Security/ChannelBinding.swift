import Foundation
import CryptoKit

/// Proves, inside an established TLS session, that the dialling device holds
/// the long-term key the listener filed it under.
///
/// ### Why TLS alone is not enough here
/// The listener registers every paired peer's PSK *and*, while a code is on
/// screen, the public pairing PSK. Network.framework completes the handshake
/// with whichever one matches and does not say which — so from the accepted
/// connection alone, a device that dialled with the public key is
/// indistinguishable from a paired one. Without this check, anyone on the
/// network could open a sync while a pairing code was showing.
///
/// ### How
/// Both ends derive the same TLS exporter secret (RFC 5705). It is unique to
/// this session and is a function of whichever PSK the handshake actually used.
/// The initiator MACs it with the long-term key; the responder recomputes that
/// with the key it holds for the claimed device ID. A device that is not
/// paired has no key to MAC with, and one that is paired cannot replay a proof
/// from another session because the exporter differs.
enum ChannelBinding {

    /// Exporter label. Part of the wire contract: both sides must use it.
    static let exporterLabel = "EXPORTER-flactastic-channel-v1"
    static let exporterLength = 32

    /// `HMAC(longTermKey, "flactastic-hello-v1" ‖ 0x00 ‖ deviceID ‖ exporter)`.
    ///
    /// The device ID is bound in so a proof made for one identity cannot be
    /// presented under another.
    static func proof(key: SymmetricKey, exporter: Data, deviceID: UUID) -> Data {
        var message = Data("flactastic-hello-v1".utf8)
        message.append(0x00)
        withUnsafeBytes(of: deviceID.uuid) { message.append(contentsOf: $0) }
        message.append(exporter)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    /// Constant-time check of a peer's proof.
    static func verify(_ proof: Data?, key: SymmetricKey, exporter: Data, deviceID: UUID) -> Bool {
        guard let proof else { return false }
        return PairingCrypto.constantTimeEquals(proof, self.proof(key: key, exporter: exporter, deviceID: deviceID))
    }
}
