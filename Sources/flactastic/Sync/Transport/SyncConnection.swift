import Foundation
import Network
import CryptoKit

/// An authenticated, framed message channel to one peer.
///
/// Wraps `NWConnection` in an `actor` with `async` send/receive, so the engine
/// above can be written as straight-line code rather than nested callbacks —
/// the same split the rest of the app uses, where `@MainActor @Observable`
/// stores drive the UI and bare actors do the I/O.
///
/// Framing is applied here with `FrameCodec` rather than through an
/// `NWProtocolFramer`. A custom framer is the more idiomatic Network.framework
/// answer, but it forces the parser into a synchronous callback with its own
/// buffering rules, and the parser is the part most worth testing in isolation.
/// Reading bytes and feeding `FrameCodec.Decoder` keeps that testability and
/// costs one buffer copy per read.
actor SyncConnection {

    // MARK: - Errors

    enum ConnectionError: Error, CustomStringConvertible {
        case notReady
        case cancelled
        case handshakeFailed(String)
        case network(NWError)
        case closedByPeer
        case timedOut
        case protocolViolation(String)

        var description: String {
            switch self {
            case .notReady:                  return "The connection isn't ready."
            case .cancelled:                 return "The connection was cancelled."
            case .handshakeFailed(let why):  return "Couldn't establish a secure connection: \(why)"
            case .network(let error):        return error.localizedDescription
            case .closedByPeer:              return "The other device closed the connection."
            case .timedOut:                  return "The other device stopped responding."
            case .protocolViolation(let why): return "The other device misbehaved: \(why)"
            }
        }

        /// Whether a retry could plausibly succeed. A failed PSK handshake
        /// never can — it means the peer does not hold the paired key, which is
        /// revocation working as designed, not a transient fault.
        var isRetryable: Bool {
            switch self {
            case .network, .timedOut, .closedByPeer: return true
            case .notReady, .cancelled, .handshakeFailed, .protocolViolation: return false
            }
        }
    }

    // MARK: - State

    private let connection: NWConnection
    private var decoder = FrameCodec.Decoder()
    /// Frames parsed but not yet handed to a caller.
    private var pending: [FrameCodec.Frame] = []
    private var isStarted = false
    private var failure: ConnectionError?

    /// A `receive()` waiting on bytes that have not arrived yet. Only one at a
    /// time — the protocol is strictly request/response per direction, so a
    /// second concurrent receive would be a bug in the caller.
    private var waiter: CheckedContinuation<FrameCodec.Frame, any Error>?
    private var readyWaiters: [CheckedContinuation<Void, any Error>] = []

    // MARK: - Lifecycle

    /// Dials a peer we have already paired with.
    init(endpoint: NWEndpoint, key: SymmetricKey, localDeviceID: UUID) {
        self.connection = NWConnection(to: endpoint, using: SyncTLS.pairedParameters(key: key, localDeviceID: localDeviceID))
    }

    /// Dials a peer for first contact. Carries no authentication — only
    /// pairing messages may cross this.
    init(pairingWith endpoint: NWEndpoint) {
        self.connection = NWConnection(to: endpoint, using: SyncTLS.pairingParameters())
    }

    /// Adopts a connection handed over by the listener.
    init(accepted connection: NWConnection) {
        self.connection = connection
    }

    /// Starts the connection and waits for the TLS handshake to complete.
    ///
    /// The wait matters: with PSK, a peer holding the wrong key fails *here*,
    /// which is precisely how a revoked device is turned away.
    ///
    /// The timeout is not optional dressing. Network.framework treats an
    /// unreachable or unresponsive peer as a *path* problem, parking the
    /// connection in `.waiting` and retrying indefinitely rather than failing —
    /// so without a bound here, dialling a device that has gone to sleep, or
    /// one whose key we no longer hold, would hang forever with the UI showing
    /// a spinner and no way back.
    func start(timeout: Duration = .seconds(20)) async throws {
        guard !isStarted else { return }
        isStarted = true

        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(state: state) }
        }
        connection.start(queue: .global(qos: .userInitiated))

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.awaitReady() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ConnectionError.timedOut
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            // A connection that never came up must not be left running in the
            // background, still retrying against a peer nobody is waiting for.
            connection.stateUpdateHandler = nil
            connection.cancel()
            let failure = (error as? ConnectionError) ?? (error is CancellationError ? .cancelled : .timedOut)
            fail(with: failure)
            throw failure
        }
        receiveLoop()
    }

    /// Cancellation-aware on purpose. `start()` races this against a sleep in a
    /// task group, and a task group waits for *every* child before returning —
    /// so if this ignored cancellation, the timeout would win the race and then
    /// wait forever for the loser, which is exactly the spinner it exists to
    /// prevent.
    private func awaitReady() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                readyWaiters.append(continuation)
                // If the state already settled before this ran, resolve immediately.
                resolveReadyWaitersIfSettled()
            }
        } onCancel: {
            Task { await self.releaseWaitersForCancellation() }
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
        fail(with: .cancelled)
    }

    // MARK: - Sending

    func send(_ message: WireMessage) async throws {
        try await send(frame: .init(type: .control, payload: try message.encoded()))
    }

    func send(chunk: Data) async throws {
        try await send(frame: .init(type: .fileChunk, payload: chunk))
    }

    private func send(frame: FrameCodec.Frame) async throws {
        if let failure { throw failure }
        let data = try FrameCodec.encode(frame)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ConnectionError.network(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Receiving

    /// The next frame, waiting for it if necessary.
    ///
    /// `timeout` guards against a peer that opens a connection and then simply
    /// stops — without it a stalled sync would hang the UI indefinitely rather
    /// than reporting a failure the user can retry.
    func receiveFrame(timeout: Duration = .seconds(60)) async throws -> FrameCodec.Frame {
        if let failure, pending.isEmpty { throw failure }
        if !pending.isEmpty { return pending.removeFirst() }

        return try await withThrowingTaskGroup(of: FrameCodec.Frame.self) { group in
            group.addTask { try await self.waitForFrame() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ConnectionError.timedOut
            }
            defer { group.cancelAll() }
            guard let frame = try await group.next() else { throw ConnectionError.timedOut }
            return frame
        }
    }

    /// Convenience for the many places that require a control message and
    /// treat a raw chunk as a protocol violation.
    func receiveMessage(timeout: Duration = .seconds(60)) async throws -> WireMessage {
        let frame = try await receiveFrame(timeout: timeout)
        guard frame.type == .control else {
            throw ConnectionError.protocolViolation("Expected a control message, got a file chunk.")
        }
        do {
            return try WireMessage.decoded(from: frame.payload)
        } catch {
            throw ConnectionError.protocolViolation("Unreadable control message.")
        }
    }

    /// Cancellation-aware for the same reason as `awaitReady()`: it is the
    /// losing child when `receiveFrame`'s timeout fires.
    private func waitForFrame() async throws -> FrameCodec.Frame {
        if !pending.isEmpty { return pending.removeFirst() }
        if let failure { throw failure }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Checked here, on the actor, so a cancellation that landed
                // before the continuation existed is not lost: the handler's
                // hop to the actor cannot run until this closure returns.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiter = continuation
            }
        } onCancel: {
            Task { await self.releaseWaitersForCancellation() }
        }
    }

    /// Resumes anything parked on this connection with `CancellationError`,
    /// without failing the connection itself — a receive that timed out
    /// leaves the channel usable for whoever reads next.
    private func releaseWaitersForCancellation() {
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: CancellationError())
        }
        let ready = readyWaiters
        readyWaiters = []
        for continuation in ready { continuation.resume(throwing: CancellationError()) }
    }

    // MARK: - Channel binding

    /// The TLS exporter secret for this session (see `ChannelBinding`), or
    /// `nil` before the handshake has completed.
    func exporterSecret() -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        let label = ChannelBinding.exporterLabel
        let secret = label.withCString { pointer in
            sec_protocol_metadata_create_secret(
                metadata.securityProtocolMetadata,
                label.utf8.count,
                pointer,
                ChannelBinding.exporterLength
            )
        }
        return secret.map { Data($0 as DispatchData) }
    }

    // MARK: - Internals

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { await self?.ingest(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func ingest(data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            fail(with: .network(error))
            return
        }
        if let data, !data.isEmpty {
            decoder.append(data)
            do {
                while let frame = try decoder.next() { deliver(frame) }
            } catch {
                // A malformed length prefix or unknown frame type is not
                // recoverable: the stream position is unknown from here on.
                fail(with: .protocolViolation(String(describing: error)))
                connection.cancel()
                return
            }
        }
        if isComplete {
            fail(with: .closedByPeer)
            return
        }
        receiveLoop()
    }

    private func deliver(_ frame: FrameCodec.Frame) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: frame)
        } else {
            pending.append(frame)
        }
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            resolveReadyWaiters(with: nil)
        case .failed(let error):
            // With PSK, a peer that does not hold the key fails the handshake
            // here. That is revocation working, not a transient fault.
            let failure = ConnectionError.handshakeFailedOrNetwork(error)
            resolveReadyWaiters(with: failure)
            fail(with: failure)
        case .cancelled:
            resolveReadyWaiters(with: .cancelled)
            fail(with: .cancelled)
        case .waiting(let error):
            // `.waiting` means Network.framework will keep retrying: no route,
            // peer asleep, or a TLS rejection it treats as retryable. A refused
            // or reset connection is not going to get better on its own, so
            // surface those immediately instead of waiting out the timeout.
            switch error {
            case .posix(.ECONNREFUSED), .posix(.ECONNRESET), .posix(.EHOSTUNREACH), .tls:
                let failure = ConnectionError.handshakeFailedOrNetwork(error)
                resolveReadyWaiters(with: failure)
                fail(with: failure)
                connection.cancel()
            default:
                print("[SyncConnection] Waiting: \(error)")
            }
        default:
            break
        }
    }

    private func resolveReadyWaitersIfSettled() {
        switch connection.state {
        case .ready: resolveReadyWaiters(with: nil)
        case .failed(let error): resolveReadyWaiters(with: .handshakeFailedOrNetwork(error))
        case .cancelled: resolveReadyWaiters(with: .cancelled)
        default: break
        }
    }

    private func resolveReadyWaiters(with error: ConnectionError?) {
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    private func fail(with error: ConnectionError) {
        guard failure == nil else { return }
        failure = error
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: error)
        }
    }
}

private extension SyncConnection.ConnectionError {
    /// A TLS handshake failure and a transport failure arrive through the same
    /// `NWError`. Telling them apart matters because only one of them means
    /// "this peer is not who it claims to be".
    static func handshakeFailedOrNetwork(_ error: NWError) -> SyncConnection.ConnectionError {
        if case .tls(let status) = error {
            return .handshakeFailed("TLS status \(status). The other device may no longer be paired.")
        }
        return .network(error)
    }
}
