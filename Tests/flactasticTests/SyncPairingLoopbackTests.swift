import Foundation
import Network
import CryptoKit
import Testing
@testable import flactastic

// End-to-end pairing over a real listener and a real TLS connection, driven
// through `IncomingRequest` and `PairingExchange` — the same calls both apps'
// accept paths make. The older pairing tests pass messages between the two
// state machines in memory, which is how a bug where each side waited for the
// other to speak first shipped with every test green.

/// A listener that hands each accepted connection to `onConnection`.
private func startListener(
    pairedKeys: [UUID: SymmetricKey] = [:],
    allowPairing: Bool,
    onConnection: @escaping @Sendable (SyncConnection) async -> Void
) async throws -> (listener: NWListener, endpoint: NWEndpoint) {
    let listener = try NWListener(
        using: SyncTLS.listenerParameters(pairedKeys: pairedKeys, allowPairing: allowPairing), on: .any
    )
    listener.newConnectionHandler = { raw in
        Task {
            let connection = SyncConnection(accepted: raw)
            await onConnection(connection)
            await connection.cancel()
        }
    }
    listener.start(queue: .global())
    for _ in 0 ..< 100 {
        if case .ready = listener.state, let port = listener.port {
            return (listener, .hostPort(host: .ipv4(.loopback), port: port))
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    listener.cancel()
    throw LoopbackError.listenerNeverBecameReady
}

private enum LoopbackError: Error { case listenerNeverBecameReady }

private let hostIdentity = PairingIdentity(deviceID: UUID(), displayName: "Host Mac", kind: .mac)
private let guestIdentity = PairingIdentity(deviceID: UUID(), displayName: "Guest Phone", kind: .iPhone)

/// Records what a side saved and whether it was rolled back.
private actor SavedKeys {
    private(set) var keys: [UUID: SymmetricKey] = [:]
    private(set) var rolledBack: [UUID] = []
    func save(_ peer: PairedPeer, _ key: SymmetricKey) { keys[peer.deviceID] = key }
    func rollback(_ id: UUID) { keys[id] = nil; rolledBack.append(id) }
}

private struct SaveFailed: Error {}

private func guestPersist(_ store: SavedKeys) -> PairingExchange.Persist {
    { peer, key in await store.save(peer, key) }
}
private func guestRollback(_ store: SavedKeys) -> PairingExchange.Rollback {
    { id in await store.rollback(id) }
}

/// Runs the host side exactly as the apps do and records how it ended.
private func hostOutcome(
    code: String?,
    into box: AsyncBox<Result<PairedPeer, PairingError>>,
    persist: @escaping PairingExchange.Persist = { _, _ in }
) -> @Sendable (SyncConnection) async -> Void {
    { connection in
        do {
            guard case .pairing(let hello) = try await IncomingRequest.read(from: connection) else {
                await box.set(.failure(.unexpectedMessage))
                return
            }
            let peer = try await PairingExchange.runHost(
                on: connection, opening: hello, code: code, identity: hostIdentity, persist: persist
            )
            await box.set(.success(peer))
        } catch let error as PairingError {
            await box.set(.failure(error))
        } catch {
            await box.set(.failure(.unexpectedMessage))
        }
    }
}

// MARK: - Pairing

@Test("Pairing completes end to end over a real connection", .timeLimit(.minutes(1)))
func pairingCompletesOverLoopback() async throws {
    let code = PairingCrypto.generateCode()
    let hostResult = AsyncBox<Result<PairedPeer, PairingError>>()
    let (listener, endpoint) = try await startListener(allowPairing: true, onConnection: hostOutcome(code: code, into: hostResult))
    defer { listener.cancel() }

    let saved = SavedKeys()
    let hostAsSeenByGuest = try await PairingExchange.runGuest(
        endpoint: endpoint, code: code, identity: guestIdentity,
        persist: guestPersist(saved), rollback: guestRollback(saved)
    )
    #expect(await saved.keys[hostIdentity.deviceID] != nil)
    #expect(hostAsSeenByGuest.deviceID == hostIdentity.deviceID)
    #expect(hostAsSeenByGuest.displayName == "Host Mac")

    let host = try #require(await hostResult.waitForValue(timeout: .seconds(10)))
    let guestAsSeenByHost = try host.get()
    #expect(guestAsSeenByHost.deviceID == guestIdentity.deviceID)
    #expect(guestAsSeenByHost.kind == .iPhone)
}

@Test("Both sides derive the same long-term key, and it works as the paired PSK", .timeLimit(.minutes(1)))
func pairedKeyAuthenticatesALaterSync() async throws {
    let code = PairingCrypto.generateCode()
    let hostKey = AsyncBox<SymmetricKey>()
    let (listener, endpoint) = try await startListener(allowPairing: true) { connection in
        guard case .pairing(let hello)? = try? await IncomingRequest.read(from: connection) else { return }
        _ = try? await PairingExchange.runHost(
            on: connection, opening: hello, code: code, identity: hostIdentity,
            persist: { _, key in await hostKey.set(key) }
        )
    }
    defer { listener.cancel() }

    let saved = SavedKeys()
    _ = try await PairingExchange.runGuest(
        endpoint: endpoint, code: code, identity: guestIdentity,
        persist: guestPersist(saved), rollback: guestRollback(saved)
    )
    let guestKey = try #require(await saved.keys[hostIdentity.deviceID])
    let key = try #require(await hostKey.waitForValue(timeout: .seconds(10)))
    #expect(key.withUnsafeBytes { Data($0) } == guestKey.withUnsafeBytes { Data($0) })
}

@Test("A wrong code fails on both sides without hanging", .timeLimit(.minutes(1)))
func wrongCodeFailsPromptly() async throws {
    let hostResult = AsyncBox<Result<PairedPeer, PairingError>>()
    let (listener, endpoint) = try await startListener(
        allowPairing: true, onConnection: hostOutcome(code: "12345678", into: hostResult)
    )
    defer { listener.cancel() }

    await #expect(throws: PairingError.self) {
        _ = try await PairingExchange.runGuest(
            endpoint: endpoint, code: "87654321", identity: guestIdentity,
            persist: { _, _ in }, rollback: { _ in }
        )
    }
    let host = try #require(await hostResult.waitForValue(timeout: .seconds(10)))
    #expect(throws: PairingError.self) { try host.get() }
}

@Test("A guest is told when the host's code has gone", .timeLimit(.minutes(1)))
func closedPairingIsReported() async throws {
    // The listener still holds the pairing PSK (as it would for a moment
    // after a code expires) but no code is live.
    let hostResult = AsyncBox<Result<PairedPeer, PairingError>>()
    let (listener, endpoint) = try await startListener(allowPairing: true, onConnection: hostOutcome(code: nil, into: hostResult))
    defer { listener.cancel() }

    await #expect(throws: PairingError.notAcceptingPairing) {
        _ = try await PairingExchange.runGuest(
            endpoint: endpoint, code: "12345678", identity: guestIdentity,
            persist: { _, _ in }, rollback: { _ in }
        )
    }
    let host = try #require(await hostResult.waitForValue(timeout: .seconds(10)))
    #expect(throws: PairingError.notAcceptingPairing) { try host.get() }
}

@Test("A guest is told when the host isn't pairing at all", .timeLimit(.minutes(1)))
func pairingKeyAbsentIsReported() async throws {
    let (listener, endpoint) = try await startListener(allowPairing: false) { _ in }
    defer { listener.cancel() }

    await #expect(throws: PairingError.notAcceptingPairing) {
        _ = try await PairingExchange.runGuest(
            endpoint: endpoint, code: "12345678", identity: guestIdentity,
            persist: { _, _ in }, rollback: { _ in }
        )
    }
}

// MARK: - Saving

@Test("If the host can't save the key, the guest doesn't keep it either", .timeLimit(.minutes(1)))
func hostSaveFailureRollsBackGuest() async throws {
    // What actually happened on the first real attempt: the Mac saved, the
    // unsigned simulator build couldn't, and the Mac was left "paired" with a
    // phone that refused every sync.
    let code = PairingCrypto.generateCode()
    let hostResult = AsyncBox<Result<PairedPeer, PairingError>>()
    let (listener, endpoint) = try await startListener(
        allowPairing: true,
        onConnection: hostOutcome(code: code, into: hostResult, persist: { _, _ in throw SaveFailed() })
    )
    defer { listener.cancel() }

    let saved = SavedKeys()
    await #expect(throws: PairingError.storageFailed) {
        _ = try await PairingExchange.runGuest(
            endpoint: endpoint, code: code, identity: guestIdentity,
            persist: guestPersist(saved), rollback: guestRollback(saved)
        )
    }
    #expect(await saved.keys.isEmpty)
    #expect(await saved.rolledBack == [hostIdentity.deviceID])

    let host = try #require(await hostResult.waitForValue(timeout: .seconds(10)))
    #expect(throws: PairingError.storageFailed) { try host.get() }
}

@Test("If the guest can't save the key, the host never saves it", .timeLimit(.minutes(1)))
func guestSaveFailureStopsHost() async throws {
    let code = PairingCrypto.generateCode()
    let hostSaved = AsyncBox<Bool>()
    let hostResult = AsyncBox<Result<PairedPeer, PairingError>>()
    let (listener, endpoint) = try await startListener(
        allowPairing: true,
        onConnection: hostOutcome(code: code, into: hostResult, persist: { _, _ in await hostSaved.set(true) })
    )
    defer { listener.cancel() }

    await #expect(throws: PairingError.storageFailed) {
        _ = try await PairingExchange.runGuest(
            endpoint: endpoint, code: code, identity: guestIdentity,
            persist: { _, _ in throw SaveFailed() }, rollback: { _ in }
        )
    }
    _ = await hostResult.waitForValue(timeout: .seconds(10))
    #expect(await hostSaved.value() == nil)
}

// MARK: - Channel binding

@Test("Dialling with the public pairing key cannot open a sync as a paired device", .timeLimit(.minutes(1)))
func pairingChannelCannotImpersonatePairedPeer() async throws {
    // The paired device's ID is public — it is in its TXT record — so an
    // attacker can claim it. What it cannot do is prove the key.
    let pairedID = UUID()
    let realKey = SymmetricKey(size: .bits256)
    let responderError = AsyncBox<String>()
    let prepared = AsyncBox<Bool>()

    let (listener, endpoint) = try await startListener(pairedKeys: [pairedID: realKey], allowPairing: true) { connection in
        do {
            guard case .sync(let hello) = try await IncomingRequest.read(from: connection) else { return }
            _ = try await SyncSession().runResponder(
                connection: connection,
                replaying: .hello(hello),
                identity: hostIdentity,
                authenticate: { $0 == pairedID ? realKey : nil },
                prepare: {
                    await prepared.set(true)
                    throw CancellationError()
                }
            )
        } catch SyncSession.SessionError.notAuthenticated {
            await responderError.set("notAuthenticated")
        } catch {
            await responderError.set("\(error)")
        }
    }
    defer { listener.cancel() }

    let attacker = SyncConnection(pairingWith: endpoint)
    defer { Task { await attacker.cancel() } }
    try await attacker.start()

    let context = SyncSession.LocalContext(
        deviceID: pairedID, displayName: "Impostor", kind: .mac,
        libraryRoot: FileManager.default.temporaryDirectory,
        manifest: LibraryManifest(deviceID: pairedID, tracks: [], playlists: []),
        filter: .unrestricted, playlists: []
    )
    await #expect(throws: SyncSession.SessionError.self) {
        _ = try await SyncSession().runInitiator(
            connection: attacker, direction: .pull, local: context,
            pairedKey: SymmetricKey(size: .bits256),
            approve: { _ in .everything }
        )
    }
    let error = try #require(await responderError.waitForValue(timeout: .seconds(10)))
    #expect(error.contains("notAuthenticated"))
    #expect(await prepared.value() == nil)
}

// MARK: - Timeouts

@Test("A receive timeout fires against a peer that never speaks", .timeLimit(.minutes(1)))
func receiveTimeoutFires() async throws {
    // Both halves of the old pairing deadlock ended here: the timeout lost to
    // a continuation that ignored cancellation, and the spinner never stopped.
    let (listener, endpoint) = try await startListener(allowPairing: true) { connection in
        try? await connection.start()
        try? await Task.sleep(for: .seconds(20))
    }
    defer { listener.cancel() }

    let guest = SyncConnection(pairingWith: endpoint)
    defer { Task { await guest.cancel() } }
    try await guest.start()

    let clock = ContinuousClock()
    let started = clock.now
    await #expect(throws: SyncConnection.ConnectionError.self) {
        _ = try await guest.receiveMessage(timeout: .seconds(1))
    }
    #expect(clock.now - started < .seconds(5))
}

@Test("A connect timeout fires against a peer that never completes TLS", .timeLimit(.minutes(1)))
func startTimeoutFires() async throws {
    // A plain TCP listener: accepts the socket, never answers the handshake.
    let listener = try NWListener(using: .tcp, on: .any)
    listener.newConnectionHandler = { $0.start(queue: .global()) }
    listener.start(queue: .global())
    defer { listener.cancel() }
    var port: NWEndpoint.Port?
    for _ in 0 ..< 100 {
        if case .ready = listener.state { port = listener.port; break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let boundPort = try #require(port)

    let guest = SyncConnection(pairingWith: .hostPort(host: .ipv4(.loopback), port: boundPort))
    let clock = ContinuousClock()
    let started = clock.now
    await #expect(throws: SyncConnection.ConnectionError.self) {
        try await guest.start(timeout: .seconds(1))
    }
    #expect(clock.now - started < .seconds(5))
}

// MARK: - Advertised pairing state

@Test("Withdrawing a code notifies the owner, however it is withdrawn")
@MainActor
func closingPairingNotifiesOwner() {
    // The owner uses this to drop the pairing PSK and the "showing a code"
    // TXT flag. Before it existed, an expired code left both in place.
    let gatekeeper = PairingGatekeeper()
    var closes = 0
    gatekeeper.onClose = { closes += 1 }

    gatekeeper.openPairing()
    gatekeeper.closePairing()
    #expect(closes == 1)

    gatekeeper.openPairing()
    gatekeeper.recordFailure()
    #expect(closes == 2)

    gatekeeper.openPairing()
    gatekeeper.recordSuccess()
    #expect(closes == 3)
}
