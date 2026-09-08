import Foundation
import CryptoKit

/// The cryptography behind first contact between two devices.
///
/// ### The problem
/// Two devices on a café Wi-Fi need to agree on a long-term shared key, with
/// nothing to authenticate each other by except a short number the user reads
/// off one screen and types into the other. A plain Diffie-Hellman exchange
/// gives them a shared key but no assurance about *who* it is shared with: an
/// attacker on the same network can sit in the middle, complete a separate
/// exchange with each side, and relay everything. Eight digits of entropy is
/// not enough to fix that by itself — an attacker who sees both public keys
/// before choosing their own can grind offline for the code.
///
/// ### The fix: commit before you see
/// The host publishes `SHA256(hostPublicKey ‖ hostNonce)` *before* the guest
/// sends anything. It is then bound to a key it chose blind. An attacker in the
/// middle must commit to its own key before learning the guest's, so it cannot
/// tune the exchange to match a guessed code. It gets exactly **one** online
/// guess per attempt, and a wrong guess destroys the code
/// (`SyncProtocol.pairingFailureLimit` then locks the listener out entirely).
///
/// ### Binding
/// The derived key is bound to the full transcript — commitment, both public
/// keys, the nonce — so an attacker cannot splice messages from one session
/// into another. The confirmation MAC additionally covers the role, so a
/// reflected host MAC cannot be replayed back as a guest MAC.
///
/// Pure and synchronous, with no I/O, so every failure path below is directly
/// testable. `CryptoKit` only — identical API on macOS and iOS.
enum PairingCrypto {

    // MARK: - Constants

    /// Domain-separation labels for the confirmation MAC. Part of the wire
    /// contract: both sides must agree on the exact bytes.
    enum Role: String, Sendable {
        case host
        case guest

        var opposite: Role { self == .host ? .guest : .host }
    }

    static let nonceBytes = 32

    // MARK: - Code generation

    /// A fresh pairing code, uniformly random over all
    /// `SyncProtocol.pairingCodeDigits`-digit strings.
    ///
    /// Uses rejection sampling rather than `% 10`: the modulo bias would make
    /// low digits slightly likelier, and there is no reason to hand an attacker
    /// even a small edge on a one-shot guess.
    static func generateCode(digits: Int = SyncProtocol.pairingCodeDigits) -> String {
        var code = ""
        code.reserveCapacity(digits)
        for _ in 0 ..< digits {
            code.append(String(uniformRandomDigit()))
        }
        return code
    }

    private static func uniformRandomDigit() -> Int {
        // 250 is the largest multiple of 10 below 256, so values above it are
        // discarded rather than folded back in unevenly.
        while true {
            var byte: UInt8 = 0
            _ = withUnsafeMutableBytes(of: &byte) { buffer in
                SecRandomCopyBytes(kSecRandomDefault, 1, buffer.baseAddress!)
            }
            if byte < 250 { return Int(byte) % 10 }
        }
    }

    static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceBytes)
        _ = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, nonceBytes, buffer.baseAddress!)
        }
        return Data(bytes)
    }

    // MARK: - Commitment

    /// `SHA256(publicKey ‖ nonce)`.
    ///
    /// The nonce is what makes the commitment hiding: without it the
    /// commitment is just a hash of a public value and reveals the key
    /// immediately to anyone who can guess it.
    static func commitment(publicKey: Data, nonce: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: publicKey)
        hasher.update(data: nonce)
        return Data(hasher.finalize())
    }

    /// Verifies a revealed key/nonce against the earlier commitment, in
    /// constant time.
    static func verifyCommitment(_ commitment: Data, publicKey: Data, nonce: Data) -> Bool {
        constantTimeEquals(commitment, self.commitment(publicKey: publicKey, nonce: nonce))
    }

    // MARK: - Key agreement

    /// Everything both sides saw, in a fixed order, length-prefixed.
    ///
    /// Length prefixes matter: without them, an attacker could shift bytes
    /// between adjacent fields and produce the same transcript from different
    /// messages.
    static func transcript(commitment: Data, hostPublicKey: Data, hostNonce: Data, guestPublicKey: Data) -> Data {
        var data = Data()
        for field in [commitment, hostPublicKey, hostNonce, guestPublicKey] {
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(field)
        }
        return data
    }

    /// X25519 agreement, run through HKDF and salted with the transcript.
    ///
    /// The raw shared secret is never used directly — HKDF both spreads it into
    /// a uniform key and, via the salt, ties it to this exact exchange.
    static func deriveKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data,
        transcript: Data,
        info: String = SyncProtocol.pairingKDFInfo
    ) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data(info.utf8),
            outputByteCount: 32
        )
    }

    // MARK: - Confirmation

    /// `HMAC(key, role ‖ code)` — proof that this side knows both the derived
    /// key and the code the user typed.
    ///
    /// The role label is what stops a reflection attack: without it, an
    /// attacker could take the host's MAC and send it straight back as the
    /// guest's, proving nothing but passing the check.
    static func confirmationMAC(key: SymmetricKey, code: String, role: Role) -> Data {
        var message = Data(role.rawValue.utf8)
        message.append(0x00)          // separator; a role label cannot contain NUL
        message.append(Data(code.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    /// Constant-time verification of a peer's confirmation MAC.
    static func verifyConfirmation(_ mac: Data, key: SymmetricKey, code: String, role: Role) -> Bool {
        constantTimeEquals(mac, confirmationMAC(key: key, code: code, role: role))
    }

    // MARK: - Long-term key

    /// Derives the durable key the two devices will use as a TLS pre-shared
    /// key for every later session.
    ///
    /// Separated from the pairing key by a different HKDF info string, so that
    /// a compromise of one does not hand over the other, and so a captured
    /// pairing transcript cannot be replayed into a session key.
    static func deriveLongTermKey(from pairingKey: SymmetricKey, transcript: Data) -> SymmetricKey {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: pairingKey,
            salt: transcript,
            info: Data(SyncProtocol.sessionKDFInfo.utf8),
            outputByteCount: 32
        )
        return derived
    }

    // MARK: - Helpers

    /// Comparison whose running time does not depend on where the first
    /// difference is. Every comparison of attacker-supplied material in this
    /// file goes through it.
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }

    /// Normalises a user-typed code: strips the spaces and dashes people add
    /// when reading digits off a screen, and nothing else.
    static func normalizeTypedCode(_ raw: String) -> String {
        raw.filter { $0.isNumber }
    }

    static func isWellFormedCode(_ code: String) -> Bool {
        code.count == SyncProtocol.pairingCodeDigits && code.allSatisfy { $0.isNumber }
    }
}
