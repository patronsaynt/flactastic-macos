import Foundation
import CryptoKit

/// A device this one has successfully paired with.
///
/// Deliberately does **not** carry the shared key: keys live in the Keychain
/// via `PeerKeyStore`, and this record is written to ordinary JSON so the UI
/// can list peers without ever loading key material. Separating them means a
/// stray log line, a crash report, or a support export of the peer list cannot
/// leak the secret.
struct PairedPeer: Codable, Sendable, Hashable, Identifiable {
    let deviceID: UUID
    var displayName: String
    var kind: SyncDeviceKind
    var pairedAt: Date
    var lastSyncedAt: Date?

    var id: UUID { deviceID }
}

/// What the caller should do next after feeding a message to a pairing session.
enum PairingStep: Sendable {
    /// Send this and keep waiting.
    case send(WireMessage)
    /// Send this; pairing is then complete on our side.
    case sendAndFinish(WireMessage, PairedPeer, SymmetricKey)
    /// Pairing is complete with nothing further to send.
    case finish(PairedPeer, SymmetricKey)
}

enum PairingError: Error, Equatable, CustomStringConvertible {
    case malformedCode
    case unexpectedMessage
    case sessionAlreadyFinished
    case invalidPublicKey
    case commitmentMismatch
    case confirmationFailed
    case peerReportedFailure(String?)

    var description: String {
        switch self {
        case .malformedCode:          return "That isn't a valid pairing code."
        case .unexpectedMessage:      return "The other device sent something unexpected."
        case .sessionAlreadyFinished: return "This pairing attempt has already finished."
        case .invalidPublicKey:       return "The other device sent an invalid key."
        case .commitmentMismatch:     return "The other device changed its key mid-handshake."
        case .confirmationFailed:     return "The codes didn't match."
        case .peerReportedFailure:    return "The other device rejected the pairing."
        }
    }

    /// What the user is told. Every failure that could plausibly be an attacker
    /// probing the code reads identically, so the message never reveals how
    /// close a guess was or which step failed.
    var userFacingMessage: String {
        switch self {
        case .malformedCode:
            return "That isn't a valid pairing code."
        case .unexpectedMessage, .sessionAlreadyFinished:
            return "Pairing didn't complete. Try again."
        case .invalidPublicKey, .commitmentMismatch, .confirmationFailed, .peerReportedFailure:
            return "Pairing failed. Check the code and try again."
        }
    }
}

/// Identity a device offers during pairing. Only believed once the peer's
/// confirmation MAC has verified — before that it is unauthenticated text.
struct PairingIdentity: Sendable, Hashable {
    let deviceID: UUID
    let displayName: String
    let kind: SyncDeviceKind
}

// MARK: - Host

/// The side that **displays** the code.
///
/// Message order (see `PairingCrypto` for why):
/// ```
/// host  → pairCommit(SHA256(hostPub ‖ nonce))
/// guest → pairGuestKey(guestPub)
/// host  → pairReveal(hostPub, nonce)
/// guest → pairConfirm(HMAC(k, "guest" ‖ code))     [guest checked the commitment]
/// host  → pairConfirm(HMAC(k, "host" ‖ code))      [host checked the guest's MAC]
/// guest → pairResult(success)                       [guest checked the host's MAC]
/// ```
/// Not thread-safe by design — one session is driven by one connection, from
/// the transport's actor.
final class HostPairingSession {

    private enum State {
        case fresh
        case awaitingGuestKey
        case awaitingGuestConfirm(guestPublicKey: Data)
        case awaitingResult(peer: PairedPeer, key: SymmetricKey)
        case finished
    }

    let code: String
    private let identity: PairingIdentity
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let nonce: Data
    private let commitment: Data
    private var state: State = .fresh

    init(code: String, identity: PairingIdentity) {
        self.code = code
        self.identity = identity
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.nonce = PairingCrypto.randomNonce()
        self.commitment = PairingCrypto.commitment(
            publicKey: privateKey.publicKey.rawRepresentation,
            nonce: nonce
        )
    }

    /// The first message. Sent before the guest has sent anything at all —
    /// that ordering is the entire security argument.
    func begin() -> WireMessage {
        state = .awaitingGuestKey
        return .pairCommit(.init(commitment: commitment))
    }

    func receive(_ message: WireMessage) throws -> PairingStep {
        switch (state, message) {

        case (.awaitingGuestKey, .pairGuestKey(let payload)):
            // Validate the key before storing it — an invalid point must fail
            // here, not later inside key agreement.
            guard (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: payload.publicKey)) != nil else {
                state = .finished
                throw PairingError.invalidPublicKey
            }
            state = .awaitingGuestConfirm(guestPublicKey: payload.publicKey)
            return .send(.pairReveal(.init(
                publicKey: privateKey.publicKey.rawRepresentation,
                nonce: nonce
            )))

        case (.awaitingGuestConfirm(let guestPublicKey), .pairConfirm(let payload)):
            let key = try derivedKey(guestPublicKey: guestPublicKey)
            guard PairingCrypto.verifyConfirmation(payload.mac, key: key, code: code, role: .guest) else {
                state = .finished
                throw PairingError.confirmationFailed
            }
            // Only now is the guest's claimed identity worth recording.
            let peer = PairedPeer(
                deviceID: payload.deviceID,
                displayName: TXTRecordCodec.sanitizeDisplayName(payload.displayName,
                                                                fallback: payload.deviceKind.displayName),
                kind: payload.deviceKind,
                pairedAt: .now,
                lastSyncedAt: nil
            )
            let longTerm = PairingCrypto.deriveLongTermKey(
                from: key,
                transcript: transcript(guestPublicKey: guestPublicKey)
            )
            state = .awaitingResult(peer: peer, key: longTerm)
            return .send(.pairConfirm(.init(
                mac: PairingCrypto.confirmationMAC(key: key, code: code, role: .host),
                deviceID: identity.deviceID,
                displayName: identity.displayName,
                deviceKind: identity.kind
            )))

        case (.awaitingResult(let peer, let key), .pairResult(let payload)):
            state = .finished
            guard payload.success else { throw PairingError.peerReportedFailure(payload.failureReason) }
            return .finish(peer, key)

        case (.finished, _):
            throw PairingError.sessionAlreadyFinished

        default:
            state = .finished
            throw PairingError.unexpectedMessage
        }
    }

    private func transcript(guestPublicKey: Data) -> Data {
        PairingCrypto.transcript(
            commitment: commitment,
            hostPublicKey: privateKey.publicKey.rawRepresentation,
            hostNonce: nonce,
            guestPublicKey: guestPublicKey
        )
    }

    private func derivedKey(guestPublicKey: Data) throws -> SymmetricKey {
        do {
            return try PairingCrypto.deriveKey(
                privateKey: privateKey,
                peerPublicKey: guestPublicKey,
                transcript: transcript(guestPublicKey: guestPublicKey)
            )
        } catch {
            throw PairingError.invalidPublicKey
        }
    }
}

// MARK: - Guest

/// The side that **types** the code.
final class GuestPairingSession {

    private enum State {
        case awaitingCommit
        case awaitingReveal(commitment: Data)
        case awaitingHostConfirm(key: SymmetricKey, longTermKey: SymmetricKey)
        case finished
    }

    private let code: String
    private let identity: PairingIdentity
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private var state: State = .awaitingCommit

    /// Fails immediately on a malformed code rather than burning a network
    /// round trip — and, more importantly, rather than burning one of the
    /// host's limited attempts on a typo.
    init(typedCode: String, identity: PairingIdentity) throws {
        let normalized = PairingCrypto.normalizeTypedCode(typedCode)
        guard PairingCrypto.isWellFormedCode(normalized) else { throw PairingError.malformedCode }
        self.code = normalized
        self.identity = identity
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    func receive(_ message: WireMessage) throws -> PairingStep {
        switch (state, message) {

        case (.awaitingCommit, .pairCommit(let payload)):
            state = .awaitingReveal(commitment: payload.commitment)
            return .send(.pairGuestKey(.init(publicKey: privateKey.publicKey.rawRepresentation)))

        case (.awaitingReveal(let commitment), .pairReveal(let payload)):
            // The host must open the commitment it made before it saw our key.
            // A middle-man that swapped keys fails here.
            guard PairingCrypto.verifyCommitment(commitment,
                                                 publicKey: payload.publicKey,
                                                 nonce: payload.nonce) else {
                state = .finished
                throw PairingError.commitmentMismatch
            }
            let transcript = PairingCrypto.transcript(
                commitment: commitment,
                hostPublicKey: payload.publicKey,
                hostNonce: payload.nonce,
                guestPublicKey: privateKey.publicKey.rawRepresentation
            )
            let key: SymmetricKey
            do {
                key = try PairingCrypto.deriveKey(
                    privateKey: privateKey,
                    peerPublicKey: payload.publicKey,
                    transcript: transcript
                )
            } catch {
                state = .finished
                throw PairingError.invalidPublicKey
            }
            state = .awaitingHostConfirm(
                key: key,
                longTermKey: PairingCrypto.deriveLongTermKey(from: key, transcript: transcript)
            )
            return .send(.pairConfirm(.init(
                mac: PairingCrypto.confirmationMAC(key: key, code: code, role: .guest),
                deviceID: identity.deviceID,
                displayName: identity.displayName,
                deviceKind: identity.kind
            )))

        case (.awaitingHostConfirm(let key, let longTermKey), .pairConfirm(let payload)):
            state = .finished
            guard PairingCrypto.verifyConfirmation(payload.mac, key: key, code: code, role: .host) else {
                // Tell the host explicitly, so it can burn the code rather than
                // leaving it on screen for another attempt.
                throw PairingError.confirmationFailed
            }
            let peer = PairedPeer(
                deviceID: payload.deviceID,
                displayName: TXTRecordCodec.sanitizeDisplayName(payload.displayName,
                                                                fallback: payload.deviceKind.displayName),
                kind: payload.deviceKind,
                pairedAt: .now,
                lastSyncedAt: nil
            )
            return .sendAndFinish(.pairResult(.init(success: true, failureReason: nil)), peer, longTermKey)

        case (.finished, _):
            throw PairingError.sessionAlreadyFinished

        default:
            state = .finished
            throw PairingError.unexpectedMessage
        }
    }
}
