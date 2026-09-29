import Foundation
import Network
import CryptoKit

/// What a device that dialled us wants, read from its opening `hello`.
///
/// Every connection opens with `hello` from the dialler — for a sync and for a
/// pairing attempt alike — so the listener can tell the two apart before it
/// says anything. `isPaired: false` means "I am here to pair"; the host
/// answers it with `pairCommit`.
///
/// This is shared rather than written into each app's accept path because the
/// order of the first messages is the part both apps must agree on exactly.
/// When each app had its own copy, both waited for the other to speak first
/// and pairing hung in every direction.
enum IncomingRequest {
    case pairing(WireMessage.Hello)
    case sync(WireMessage.Hello)

    /// Starts an accepted connection and reads its opening message.
    static func read(from connection: SyncConnection) async throws -> IncomingRequest {
        try await connection.start()
        let first = try await connection.receiveMessage(timeout: .seconds(30))
        guard case .hello(let hello) = first else {
            try? await connection.send(.protocolError(.init(
                code: .unexpectedMessage, message: "Expected hello."
            )))
            throw SyncConnection.ConnectionError.protocolViolation("The first message was not hello.")
        }
        return hello.isPaired ? .sync(hello) : .pairing(hello)
    }
}

/// Drives both ends of a pairing handshake over a `SyncConnection`. The
/// cryptography lives in `PairingSession`; this is the message plumbing.
///
/// ### Both sides save, or neither does
/// The handshake proves both devices hold the same key, but each still has to
/// write it to its own Keychain, and that write can fail. If one side saved
/// and the other did not, the first would believe it was paired and every
/// sync would be refused with "not paired". So saving is committed in order:
///
/// ```
/// guest → pairResult(success)   only after the guest has saved
/// host  → pairResult(success)   only after the host has saved   [ack]
/// ```
/// A guest that does not receive the ack rolls its own save back.
enum PairingExchange {

    /// Saves a completed pairing. Throwing means "could not save".
    typealias Persist = @Sendable (PairedPeer, SymmetricKey) async throws -> Void
    /// Undoes a `Persist` for the given peer.
    typealias Rollback = @Sendable (UUID) async -> Void

    /// How long either side waits for the other's next pairing message. Both
    /// devices are already on screen with the code entered, so each step is a
    /// network round trip, not a human.
    static let stepTimeout: Duration = .seconds(30)

    // MARK: - Guest

    /// Dials a device showing a code and pairs with it.
    ///
    /// The code is checked for shape before anything touches the network, so a
    /// typo never burns one of the host's limited attempts.
    static func runGuest(
        endpoint: NWEndpoint,
        code: String,
        identity: PairingIdentity,
        persist: Persist,
        rollback: Rollback
    ) async throws -> PairedPeer {
        let session = try GuestPairingSession(typedCode: code, identity: identity)
        let connection = SyncConnection(pairingWith: endpoint)
        defer { Task { await connection.cancel() } }
        return try await runGuest(
            on: connection, session: session, identity: identity,
            persist: persist, rollback: rollback
        )
    }

    /// The guest side over an existing, not-yet-started connection. Split out
    /// so loopback tests can drive it against a real listener.
    static func runGuest(
        on connection: SyncConnection,
        session: GuestPairingSession,
        identity: PairingIdentity,
        persist: Persist,
        rollback: Rollback
    ) async throws -> PairedPeer {
        do {
            try await connection.start()
        } catch let error as SyncConnection.ConnectionError {
            // The pairing PSK is only on the host's listener while a code is
            // showing, so a refused handshake means exactly that. It arrives
            // as a TLS alert when the listener holds other keys, and as a
            // reset when it holds none.
            switch error {
            case .handshakeFailed, .network(.posix(.ECONNRESET)):
                throw PairingError.notAcceptingPairing
            default:
                throw error
            }
        }

        // The guest speaks first. The host cannot send its commitment until it
        // knows this is a pairing attempt rather than a sync.
        try await connection.send(.hello(.init(
            version: SyncProtocol.version,
            deviceID: identity.deviceID,
            displayName: identity.displayName,
            deviceKind: identity.kind,
            isPaired: false
        )))

        while true {
            let message = try await connection.receiveMessage(timeout: stepTimeout)
            switch message {
            case .protocolError(let failure):
                throw failure.code == .pairingClosed
                    ? PairingError.notAcceptingPairing
                    : PairingError.peerReportedFailure(failure.message)
            case .pairResult(let result) where !result.success:
                throw PairingError.peerReportedFailure(result.failureReason)
            default:
                break
            }
            switch try session.receive(message) {
            case .send(let next):
                try await connection.send(next)
            case .sendAndFinish(let next, let peer, let key):
                try await commitAsGuest(
                    peer: peer, key: key, success: next,
                    connection: connection, persist: persist, rollback: rollback
                )
                return peer
            case .finish(let peer, let key):
                try await commitAsGuest(
                    peer: peer, key: key, success: nil,
                    connection: connection, persist: persist, rollback: rollback
                )
                return peer
            }
        }
    }

    private static func commitAsGuest(
        peer: PairedPeer,
        key: SymmetricKey,
        success: WireMessage?,
        connection: SyncConnection,
        persist: Persist,
        rollback: Rollback
    ) async throws {
        do {
            try await persist(peer, key)
        } catch {
            try? await connection.send(.pairResult(.init(
                success: false, failureReason: PairingError.storageFailedReason
            )))
            throw PairingError.storageFailed
        }
        do {
            try await connection.send(success ?? .pairResult(.init(success: true, failureReason: nil)))
            let ack = try await connection.receiveMessage(timeout: stepTimeout)
            guard case .pairResult(let result) = ack else { throw PairingError.unexpectedMessage }
            guard result.success else {
                throw result.failureReason == PairingError.storageFailedReason
                    ? PairingError.storageFailed
                    : PairingError.peerReportedFailure(result.failureReason)
            }
        } catch {
            // The host never confirmed it saved. Keeping our half would leave
            // this device believing it is paired with one that refuses it.
            await rollback(peer.deviceID)
            throw error
        }
    }

    // MARK: - Host

    /// Answers a guest's `hello(isPaired: false)`.
    ///
    /// - Parameter code: the code on screen when the connection arrived, or
    ///   `nil` if none is. With no code the guest is told pairing is closed
    ///   and `PairingError.notAcceptingPairing` is thrown — the caller should
    ///   not count that against the lockout, since there was nothing to guess.
    ///   Every other failure is reported to the guest before being rethrown,
    ///   and the caller must burn the code.
    static func runHost(
        on connection: SyncConnection,
        opening: WireMessage.Hello,
        code: String?,
        identity: PairingIdentity,
        persist: Persist
    ) async throws -> PairedPeer {
        guard let code else {
            try? await connection.send(.protocolError(.init(
                code: .pairingClosed, message: "Not pairing."
            )))
            throw PairingError.notAcceptingPairing
        }

        let session = HostPairingSession(code: code, identity: identity)
        do {
            guard SyncProtocol.version.isCompatible(with: opening.version) else {
                try? await connection.send(.protocolError(.init(
                    code: .incompatibleVersion, message: "Version \(SyncProtocol.version) required."
                )))
                throw PairingError.unexpectedMessage
            }

            try await connection.send(session.begin())
            while true {
                let message = try await connection.receiveMessage(timeout: stepTimeout)
                let completed: (PairedPeer, SymmetricKey)
                switch try session.receive(message) {
                case .send(let next):
                    try await connection.send(next)
                    continue
                case .sendAndFinish(let next, let peer, let key):
                    try await connection.send(next)
                    completed = (peer, key)
                case .finish(let peer, let key):
                    completed = (peer, key)
                }
                // The guest has saved. Save here, then acknowledge — the guest
                // rolls back unless this arrives.
                do {
                    try await persist(completed.0, completed.1)
                } catch {
                    throw PairingError.storageFailed
                }
                try await connection.send(.pairResult(.init(success: true, failureReason: nil)))
                return completed.0
            }
        } catch {
            let reason = (error as? PairingError) == .storageFailed
                ? PairingError.storageFailedReason
                : "Pairing failed."
            try? await connection.send(.pairResult(.init(success: false, failureReason: reason)))
            throw error
        }
    }
}
