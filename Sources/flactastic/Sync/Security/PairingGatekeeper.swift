import Foundation

/// Owns the lifetime of the displayed pairing code, and the policy that keeps
/// eight digits from being brute-forced.
///
/// `PairingCrypto`'s commitment scheme limits an attacker to one *offline*
/// guess per handshake. This type is what limits the *online* ones: a code is
/// single-use, expires on a timer, and a run of failures shuts the door
/// entirely for a while. Without it, an attacker on the LAN could simply
/// reconnect ten million times.
///
/// Not `@MainActor`-isolated state hidden behind a service — it *is* the
/// policy, kept small and synchronous so the rules are readable in one screen
/// and testable without a clock or a network.
@Observable
@MainActor
final class PairingGatekeeper {

    // MARK: - State

    /// The code currently on screen, if any.
    private(set) var activeCode: String?
    private(set) var codeExpiresAt: Date?
    /// Set while the gatekeeper is locked out after repeated failures.
    private(set) var lockedOutUntil: Date?
    private(set) var consecutiveFailures = 0

    /// Injected so tests do not have to wait out real timeouts.
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: - Queries

    var isPairingOpen: Bool { activeCode != nil && !isExpired }

    var isLockedOut: Bool {
        guard let lockedOutUntil else { return false }
        return now() < lockedOutUntil
    }

    private var isExpired: Bool {
        guard let codeExpiresAt else { return true }
        return now() >= codeExpiresAt
    }

    // MARK: - Lifecycle

    /// Generates and displays a fresh code. Returns `nil` while locked out, so
    /// the UI can explain the wait rather than showing a code that will be
    /// refused.
    @discardableResult
    func openPairing() -> String? {
        guard !isLockedOut else { return nil }

        let code = PairingCrypto.generateCode()
        activeCode = code
        codeExpiresAt = now().addingTimeInterval(SyncProtocol.pairingCodeLifetime)

        expiryTask?.cancel()
        expiryTask = Task { [lifetime = SyncProtocol.pairingCodeLifetime] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled else { return }
            self.closePairing()
        }
        return code
    }

    /// Closes the window — on success, on cancellation, on expiry, or when the
    /// user leaves the screen.
    func closePairing() {
        expiryTask?.cancel()
        expiryTask = nil
        activeCode = nil
        codeExpiresAt = nil
    }

    /// The code an incoming attempt must match, or `nil` if none is live.
    ///
    /// Reading it does not consume it — `recordSuccess`/`recordFailure` decide
    /// that — but an expired code is never handed out.
    func currentCode() -> String? {
        guard !isLockedOut, !isExpired else { return nil }
        return activeCode
    }

    // MARK: - Outcomes

    func recordSuccess() {
        consecutiveFailures = 0
        lockedOutUntil = nil
        closePairing()
    }

    /// Burns the code. **Every** failed attempt consumes it, whatever the
    /// cause — a typo, a tampered message, a dropped connection mid-handshake.
    /// Leaving a code live after a failure would hand an attacker unlimited
    /// tries at the one number the user is looking at.
    func recordFailure() {
        closePairing()
        consecutiveFailures += 1
        if consecutiveFailures >= SyncProtocol.pairingFailureLimit {
            lockedOutUntil = now().addingTimeInterval(SyncProtocol.pairingLockoutDuration)
        }
    }

    /// Seconds left on a lockout, for the UI countdown.
    var lockoutSecondsRemaining: Int {
        guard let lockedOutUntil else { return 0 }
        return max(0, Int(lockedOutUntil.timeIntervalSince(now()).rounded(.up)))
    }

    /// Clears a lockout once it has elapsed. Called by the UI on a tick so the
    /// failure counter resets without needing another attempt to notice.
    func refreshLockout() {
        guard let lockedOutUntil, now() >= lockedOutUntil else { return }
        self.lockedOutUntil = nil
        consecutiveFailures = 0
    }
}
