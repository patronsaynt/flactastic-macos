import Foundation
import CryptoKit
import Testing
@testable import flactastic

// Tests for the pairing handshake. The happy path is one test; the rest of this
// file is the attacks it has to survive, because pairing is the only moment in
// the whole feature where two devices trust each other on the strength of eight
// digits typed by a human on a network anyone can join.

private let hostIdentity = PairingIdentity(deviceID: UUID(), displayName: "Studio Mac", kind: .mac)
private let guestIdentity = PairingIdentity(deviceID: UUID(), displayName: "iPhone", kind: .iPhone)

/// Runs a complete handshake between two sessions, optionally letting a
/// man-in-the-middle rewrite each message as it passes.
@discardableResult
private func runHandshake(
    hostCode: String,
    guestCode: String,
    tamper: (WireMessage) -> WireMessage = { $0 }
) throws -> (host: (PairedPeer, SymmetricKey)?, guest: (PairedPeer, SymmetricKey)?) {
    let host = HostPairingSession(code: hostCode, identity: hostIdentity)
    let guest = try GuestPairingSession(typedCode: guestCode, identity: guestIdentity)

    var hostResult: (PairedPeer, SymmetricKey)?
    var guestResult: (PairedPeer, SymmetricKey)?
    var inFlight: WireMessage? = tamper(host.begin())
    var toGuest = true

    while let message = inFlight {
        let step: PairingStep = toGuest ? try guest.receive(message) : try host.receive(message)
        switch step {
        case .send(let next):
            inFlight = tamper(next)
        case .sendAndFinish(let next, let peer, let key):
            if toGuest { guestResult = (peer, key) } else { hostResult = (peer, key) }
            inFlight = tamper(next)
        case .finish(let peer, let key):
            if toGuest { guestResult = (peer, key) } else { hostResult = (peer, key) }
            inFlight = nil
        }
        toGuest.toggle()
    }
    return (hostResult, guestResult)
}

// MARK: - Happy path

@Test("A correct code pairs both sides on the same key")
func pairingSucceeds() throws {
    let code = PairingCrypto.generateCode()
    let result = try runHandshake(hostCode: code, guestCode: code)

    let (hostPeer, hostKey) = try #require(result.host)
    let (guestPeer, guestKey) = try #require(result.guest)

    // Each side records the *other* device.
    #expect(hostPeer.deviceID == guestIdentity.deviceID)
    #expect(guestPeer.deviceID == hostIdentity.deviceID)
    #expect(hostPeer.kind == .iPhone)
    #expect(guestPeer.kind == .mac)

    // And both derived the same long-term key without it ever crossing the wire.
    #expect(hostKey.withUnsafeBytes { Data($0) } == guestKey.withUnsafeBytes { Data($0) })
}

@Test("Spaces and dashes in a typed code are tolerated")
func typedCodeIsNormalized() throws {
    let code = "12345678"
    let result = try runHandshake(hostCode: code, guestCode: "1234 - 5678")
    #expect(result.host != nil)
    #expect(result.guest != nil)
}

@Test("Two runs of the same code produce different keys")
func keysAreFreshPerSession() throws {
    let code = "11111111"
    let first = try #require(try runHandshake(hostCode: code, guestCode: code).host)
    let second = try #require(try runHandshake(hostCode: code, guestCode: code).host)
    // Ephemeral keys mean a recorded session cannot be replayed into a later
    // one even if the same code is somehow reused.
    #expect(first.1.withUnsafeBytes { Data($0) } != second.1.withUnsafeBytes { Data($0) })
}

// MARK: - Wrong code

@Test("A wrong code fails at the confirmation step")
func wrongCodeFails() {
    #expect(throws: PairingError.confirmationFailed) {
        try runHandshake(hostCode: "12345678", guestCode: "87654321")
    }
}

@Test("A malformed code is rejected before any network round trip")
func malformedCodeRejectedEarly() {
    // Rejecting locally matters: a typo must not consume one of the host's
    // three attempts and lock the user out of their own device.
    for bad in ["", "123", "123456789", "abcdefgh", "1234567a"] {
        #expect(throws: PairingError.malformedCode) {
            try GuestPairingSession(typedCode: bad, identity: guestIdentity)
        }
    }
}

// MARK: - Man in the middle

@Test("A middle-man that substitutes its own key is caught by the commitment")
func mitmKeySubstitutionFails() {
    // The attack the commit-then-reveal scheme exists to stop: an attacker
    // relays the handshake but swaps in its own public key so it shares a
    // separate secret with each side. The host committed to its real key
    // before seeing anything, so the reveal no longer matches.
    let attackerKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let code = "12345678"

    #expect(throws: PairingError.commitmentMismatch) {
        try runHandshake(hostCode: code, guestCode: code) { message in
            if case .pairReveal(let payload) = message {
                return .pairReveal(.init(publicKey: attackerKey, nonce: payload.nonce))
            }
            return message
        }
    }
}

@Test("Tampering with the commitment is caught at reveal")
func tamperedCommitmentFails() {
    #expect(throws: PairingError.commitmentMismatch) {
        try runHandshake(hostCode: "12345678", guestCode: "12345678") { message in
            if case .pairCommit = message {
                return .pairCommit(.init(commitment: Data(repeating: 0xFF, count: 32)))
            }
            return message
        }
    }
}

@Test("Swapping the guest's key breaks the derived secret")
func tamperedGuestKeyFails() {
    // The guest key is not committed to, but it *is* mixed into the transcript
    // that salts the key derivation — so substituting it makes the two sides
    // derive different keys and the confirmation MAC fails.
    let attackerKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    #expect(throws: PairingError.confirmationFailed) {
        try runHandshake(hostCode: "12345678", guestCode: "12345678") { message in
            if case .pairGuestKey = message {
                return .pairGuestKey(.init(publicKey: attackerKey))
            }
            return message
        }
    }
}

@Test("A garbage public key is rejected rather than crashing key agreement")
func invalidPublicKeyRejected() {
    #expect(throws: PairingError.invalidPublicKey) {
        try runHandshake(hostCode: "12345678", guestCode: "12345678") { message in
            if case .pairGuestKey = message {
                return .pairGuestKey(.init(publicKey: Data([1, 2, 3])))
            }
            return message
        }
    }
}

@Test("A reflected host MAC cannot pass as the guest's")
func reflectionAttackFails() throws {
    // Without the role label in the MAC, an attacker could echo one side's
    // confirmation back at it and authenticate having proved nothing.
    let key = SymmetricKey(size: .bits256)
    let code = "12345678"
    let hostMAC = PairingCrypto.confirmationMAC(key: key, code: code, role: .host)
    #expect(!PairingCrypto.verifyConfirmation(hostMAC, key: key, code: code, role: .guest))
    #expect(PairingCrypto.verifyConfirmation(hostMAC, key: key, code: code, role: .host))
}

// MARK: - State machine

@Test("Messages arriving out of order are refused")
func outOfOrderMessagesRefused() throws {
    let host = HostPairingSession(code: "12345678", identity: hostIdentity)
    _ = host.begin()
    // A confirm before a key exchange.
    #expect(throws: PairingError.unexpectedMessage) {
        try host.receive(.pairConfirm(.init(mac: Data(), deviceID: UUID(),
                                            displayName: "x", deviceKind: .mac)))
    }
}

@Test("A finished session refuses further messages")
func finishedSessionIsClosed() throws {
    let host = HostPairingSession(code: "12345678", identity: hostIdentity)
    _ = host.begin()
    _ = try? host.receive(.pairGuestKey(.init(publicKey: Data([1]))))   // fails, closes
    #expect(throws: PairingError.sessionAlreadyFinished) {
        try host.receive(.pairGuestKey(.init(publicKey: Data([1]))))
    }
}

@Test("An unrelated message type is refused")
func unrelatedMessageRefused() throws {
    let guest = try GuestPairingSession(typedCode: "12345678", identity: guestIdentity)
    #expect(throws: PairingError.unexpectedMessage) {
        try guest.receive(.cancel(.init(reason: "nope")))
    }
}

// MARK: - Primitives

@Test("Generated codes are the right shape and well distributed")
func codeGeneration() {
    var seen = Set<String>()
    var digitCounts = [Int](repeating: 0, count: 10)
    for _ in 0 ..< 2000 {
        let code = PairingCrypto.generateCode()
        #expect(PairingCrypto.isWellFormedCode(code))
        seen.insert(code)
        for character in code { digitCounts[character.wholeNumberValue!] += 1 }
    }
    // 2000 eight-digit codes colliding would mean the generator is badly broken.
    #expect(seen.count > 1990)
    // Rejection sampling, not modulo — so no digit should be visibly favoured.
    // 16000 digits over 10 buckets is 1600 expected; this bound is loose enough
    // never to flake but tight enough to catch a systematic bias.
    for count in digitCounts { #expect(count > 1300 && count < 1900) }
}

@Test("The commitment hides the key until it is opened")
func commitmentIsBinding() {
    let keyA = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let keyB = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let nonce = PairingCrypto.randomNonce()
    let commitment = PairingCrypto.commitment(publicKey: keyA, nonce: nonce)

    #expect(PairingCrypto.verifyCommitment(commitment, publicKey: keyA, nonce: nonce))
    #expect(!PairingCrypto.verifyCommitment(commitment, publicKey: keyB, nonce: nonce))
    #expect(!PairingCrypto.verifyCommitment(commitment, publicKey: keyA, nonce: PairingCrypto.randomNonce()))
}

@Test("The transcript is unambiguous under field shifting")
func transcriptIsUnambiguous() {
    // Without length prefixes, moving a byte from one field to the next would
    // produce an identical transcript from two different handshakes.
    let a = PairingCrypto.transcript(commitment: Data([1, 2]), hostPublicKey: Data([3]),
                                     hostNonce: Data([4]), guestPublicKey: Data([5]))
    let b = PairingCrypto.transcript(commitment: Data([1]), hostPublicKey: Data([2, 3]),
                                     hostNonce: Data([4]), guestPublicKey: Data([5]))
    #expect(a != b)
}

@Test("The long-term key is not the pairing key")
func longTermKeyIsSeparated() {
    let pairingKey = SymmetricKey(size: .bits256)
    let transcript = Data("transcript".utf8)
    let longTerm = PairingCrypto.deriveLongTermKey(from: pairingKey, transcript: transcript)
    #expect(longTerm.withUnsafeBytes { Data($0) } != pairingKey.withUnsafeBytes { Data($0) })
}
