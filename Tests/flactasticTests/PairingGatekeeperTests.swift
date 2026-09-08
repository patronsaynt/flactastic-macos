import Foundation
import CryptoKit
import Testing
@testable import flactastic

// Tests for the pairing window policy and Keychain-backed key storage.
// PairingCrypto stops an attacker guessing offline; these are the rules that
// stop them guessing online.

/// A clock the test moves by hand, so lockout and expiry are exercised without
/// sleeping through real timeouts.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: @Sendable () -> Date {
        { [self] in lock.lock(); defer { lock.unlock() }; return current }
    }

    func advance(_ interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current += interval
    }
}

// MARK: - Code lifetime

@Test("Opening pairing yields a well-formed code")
@MainActor
func opensWithValidCode() {
    let gatekeeper = PairingGatekeeper()
    let code = gatekeeper.openPairing()
    #expect(code != nil)
    #expect(PairingCrypto.isWellFormedCode(code!))
    #expect(gatekeeper.isPairingOpen)
    #expect(gatekeeper.currentCode() == code)
    gatekeeper.closePairing()
}

@Test("Reopening replaces the code rather than reusing it")
@MainActor
func reopeningRotatesCode() {
    let gatekeeper = PairingGatekeeper()
    let first = gatekeeper.openPairing()
    let second = gatekeeper.openPairing()
    #expect(first != second)
    #expect(gatekeeper.currentCode() == second)
    gatekeeper.closePairing()
}

@Test("A code stops being offered once it expires")
@MainActor
func codeExpires() {
    let clock = TestClock()
    let gatekeeper = PairingGatekeeper(now: clock.now)
    _ = gatekeeper.openPairing()
    #expect(gatekeeper.currentCode() != nil)

    clock.advance(SyncProtocol.pairingCodeLifetime + 1)
    #expect(gatekeeper.currentCode() == nil)
    #expect(!gatekeeper.isPairingOpen)
    gatekeeper.closePairing()
}

@Test("Closing pairing withdraws the code immediately")
@MainActor
func closingWithdrawsCode() {
    let gatekeeper = PairingGatekeeper()
    _ = gatekeeper.openPairing()
    gatekeeper.closePairing()
    #expect(gatekeeper.currentCode() == nil)
    #expect(!gatekeeper.isPairingOpen)
}

// MARK: - Failure policy

@Test("A single failure burns the code")
@MainActor
func failureBurnsCode() {
    // The attack this blocks: a hostile peer guessing repeatedly against the
    // one number the user is currently looking at.
    let gatekeeper = PairingGatekeeper()
    let code = gatekeeper.openPairing()
    gatekeeper.recordFailure()
    #expect(gatekeeper.currentCode() == nil)
    #expect(gatekeeper.activeCode != code)
}

@Test("Repeated failures lock the door")
@MainActor
func repeatedFailuresLockOut() {
    let clock = TestClock()
    let gatekeeper = PairingGatekeeper(now: clock.now)

    for _ in 0 ..< SyncProtocol.pairingFailureLimit {
        _ = gatekeeper.openPairing()
        gatekeeper.recordFailure()
    }
    #expect(gatekeeper.isLockedOut)
    // No new code is issued while locked out, so the UI must explain the wait
    // rather than display a number that will be refused.
    #expect(gatekeeper.openPairing() == nil)
    #expect(gatekeeper.lockoutSecondsRemaining > 0)
}

@Test("A lockout lifts on its own")
@MainActor
func lockoutExpires() {
    let clock = TestClock()
    let gatekeeper = PairingGatekeeper(now: clock.now)
    for _ in 0 ..< SyncProtocol.pairingFailureLimit {
        _ = gatekeeper.openPairing()
        gatekeeper.recordFailure()
    }
    #expect(gatekeeper.isLockedOut)

    clock.advance(SyncProtocol.pairingLockoutDuration + 1)
    gatekeeper.refreshLockout()
    #expect(!gatekeeper.isLockedOut)
    #expect(gatekeeper.consecutiveFailures == 0)
    #expect(gatekeeper.openPairing() != nil)
    gatekeeper.closePairing()
}

@Test("Success resets the failure counter")
@MainActor
func successResetsFailures() {
    let gatekeeper = PairingGatekeeper()
    _ = gatekeeper.openPairing()
    gatekeeper.recordFailure()
    _ = gatekeeper.openPairing()
    gatekeeper.recordSuccess()
    #expect(gatekeeper.consecutiveFailures == 0)
    #expect(!gatekeeper.isPairingOpen)      // the window closes on success too
}

// MARK: - Keychain

@Test("A stored key round-trips and can be revoked")
func keyStoreRoundTrips() throws {
    let deviceID = UUID()
    let key = SymmetricKey(size: .bits256)
    defer { try? PeerKeyStore.delete(deviceID: deviceID) }

    #expect(try PeerKeyStore.key(for: deviceID) == nil)   // unpaired is not an error

    try PeerKeyStore.store(key: key, for: deviceID)
    let loaded = try #require(try PeerKeyStore.key(for: deviceID))
    #expect(loaded.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })

    // Revocation must be real: after this the peer cannot complete a handshake.
    try PeerKeyStore.delete(deviceID: deviceID)
    #expect(try PeerKeyStore.key(for: deviceID) == nil)
}

@Test("Re-pairing a device replaces its key instead of failing")
func keyStoreOverwrites() throws {
    let deviceID = UUID()
    defer { try? PeerKeyStore.delete(deviceID: deviceID) }

    try PeerKeyStore.store(key: SymmetricKey(size: .bits256), for: deviceID)
    let replacement = SymmetricKey(size: .bits256)
    try PeerKeyStore.store(key: replacement, for: deviceID)

    let loaded = try #require(try PeerKeyStore.key(for: deviceID))
    #expect(loaded.withUnsafeBytes { Data($0) } == replacement.withUnsafeBytes { Data($0) })
}

@Test("Deleting an unknown device is not an error")
func deletingUnknownDeviceSucceeds() throws {
    try PeerKeyStore.delete(deviceID: UUID())
}
