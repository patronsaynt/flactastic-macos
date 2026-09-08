import Foundation
import Network
import CryptoKit
import Testing
@testable import flactastic

// Loopback tests for the transport. These run a real NWListener and a real
// NWConnection in one process over 127.0.0.1, so the TLS-PSK handshake is
// genuinely exercised rather than mocked — which matters, because the security
// claim of this whole layer is "a peer without the key cannot connect", and
// that claim lives entirely inside the handshake.

/// Stands up a listener with the given paired keys and returns its port.
@discardableResult
private func startListener(
    pairedKeys: [UUID: SymmetricKey],
    allowPairing: Bool = false,
    onConnection: @escaping @Sendable (NWConnection) -> Void
) async throws -> (listener: NWListener, port: UInt16) {
    let parameters = SyncTLS.listenerParameters(pairedKeys: pairedKeys, allowPairing: allowPairing)
    // Loopback only: these tests must not advertise on the tester's network.
    let listener = try NWListener(using: parameters, on: .any)
    listener.newConnectionHandler = onConnection
    listener.start(queue: .global())

    for _ in 0 ..< 100 {
        if case .ready = listener.state, let port = listener.port?.rawValue {
            return (listener, port)
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    listener.cancel()
    throw ConnectionTestError.listenerNeverBecameReady
}

private enum ConnectionTestError: Error { case listenerNeverBecameReady }

private func loopbackEndpoint(port: UInt16) -> NWEndpoint {
    .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!)
}

// MARK: - Authenticated exchange

@Test("A paired peer completes the handshake and exchanges messages", .timeLimit(.minutes(1)))
func pairedPeersExchangeMessages() async throws {
    let clientID = UUID()
    let key = SymmetricKey(size: .bits256)

    let received = AsyncBox<WireMessage>()
    let (listener, port) = try await startListener(pairedKeys: [clientID: key]) { raw in
        Task {
            let server = SyncConnection(accepted: raw)
            try? await server.start()
            if let message = try? await server.receiveMessage(timeout: .seconds(10)) {
                await received.set(message)
                try? await server.send(.cancel(.init(reason: "ack")))
            }
        }
    }
    defer { listener.cancel() }

    let client = SyncConnection(endpoint: loopbackEndpoint(port: port), key: key, localDeviceID: clientID)
    defer { Task { await client.cancel() } }
    try await client.start()

    let sent = WireMessage.hello(.init(version: SyncProtocol.version, deviceID: clientID,
                                       displayName: "Tester", deviceKind: .mac, isPaired: true))
    try await client.send(sent)

    let reply = try await client.receiveMessage(timeout: .seconds(10))
    #expect(reply == .cancel(.init(reason: "ack")))
    #expect(await received.value() == sent)
}

@Test("A peer with the wrong key cannot complete the handshake", .timeLimit(.minutes(1)))
func wrongKeyIsRejected() async throws {
    // This is revocation. Deleting a peer's key removes it from the listener's
    // PSK set, and from that moment its connections fail here — there is no
    // application-level check that could be forgotten or bypassed.
    let clientID = UUID()
    let (listener, port) = try await startListener(pairedKeys: [clientID: SymmetricKey(size: .bits256)]) { raw in
        Task { try? await SyncConnection(accepted: raw).start() }
    }
    defer { listener.cancel() }

    let impostor = SyncConnection(
        endpoint: loopbackEndpoint(port: port),
        key: SymmetricKey(size: .bits256),      // not the key the listener holds
        localDeviceID: clientID
    )
    defer { Task { await impostor.cancel() } }

    await #expect(throws: (any Error).self) {
        try await impostor.start()
        // If the handshake somehow completed, a send must still fail.
        try await impostor.send(.cancel(.init(reason: "should never arrive")))
        _ = try await impostor.receiveMessage(timeout: .seconds(5))
    }
}

@Test("An unknown device cannot connect at all", .timeLimit(.minutes(1)))
func unknownDeviceIsRejected() async throws {
    // A listener with no paired keys and pairing closed accepts nobody.
    let (listener, port) = try await startListener(pairedKeys: [:]) { raw in
        Task { try? await SyncConnection(accepted: raw).start() }
    }
    defer { listener.cancel() }

    let stranger = SyncConnection(
        endpoint: loopbackEndpoint(port: port),
        key: SymmetricKey(size: .bits256),
        localDeviceID: UUID()
    )
    defer { Task { await stranger.cancel() } }

    await #expect(throws: (any Error).self) {
        try await stranger.start()
        try await stranger.send(.cancel(.init(reason: "x")))
        _ = try await stranger.receiveMessage(timeout: .seconds(5))
    }
}

// MARK: - Pairing channel

@Test("The pairing channel connects without prior trust", .timeLimit(.minutes(1)))
func pairingChannelConnects() async throws {
    // Encryption only — anyone can complete this handshake, by design. The
    // security of first contact comes from PairingCrypto, not from here.
    let opened = AsyncBox<Bool>()
    let (listener, port) = try await startListener(pairedKeys: [:], allowPairing: true) { raw in
        Task {
            let server = SyncConnection(accepted: raw)
            try? await server.start()
            await opened.set(true)
            try? await server.send(.pairCommit(.init(commitment: Data([1, 2, 3]))))
        }
    }
    defer { listener.cancel() }

    let guest = SyncConnection(pairingWith: loopbackEndpoint(port: port))
    defer { Task { await guest.cancel() } }
    try await guest.start()

    let message = try await guest.receiveMessage(timeout: .seconds(10))
    #expect(message == .pairCommit(.init(commitment: Data([1, 2, 3]))))
    #expect(await opened.value() == true)
}

@Test("Pairing is refused when no code is on screen", .timeLimit(.minutes(1)))
func pairingChannelClosedWhenNotPairing() async throws {
    // The listener only carries the pairing PSK while the user is actually
    // looking at a code. Outside that window there is nothing to connect to.
    let (listener, port) = try await startListener(pairedKeys: [:], allowPairing: false) { raw in
        Task { try? await SyncConnection(accepted: raw).start() }
    }
    defer { listener.cancel() }

    let guest = SyncConnection(pairingWith: loopbackEndpoint(port: port))
    defer { Task { await guest.cancel() } }

    await #expect(throws: (any Error).self) {
        try await guest.start()
        try await guest.send(.pairGuestKey(.init(publicKey: Data([1]))))
        _ = try await guest.receiveMessage(timeout: .seconds(5))
    }
}

// MARK: - Framing over a real socket

@Test("Large payloads and rapid frames survive a real socket", .timeLimit(.minutes(1)))
func largeAndRapidFramesSurvive() async throws {
    // TCP will fragment and coalesce these arbitrarily; this is the end-to-end
    // check that FrameCodec's incremental decoder handles what the network
    // actually does, not just what the unit tests hand it.
    let clientID = UUID()
    let key = SymmetricKey(size: .bits256)
    let chunks = AsyncCollector<Data>()

    let (listener, port) = try await startListener(pairedKeys: [clientID: key]) { raw in
        Task {
            let server = SyncConnection(accepted: raw)
            try? await server.start()
            for _ in 0 ..< 20 {
                guard let frame = try? await server.receiveFrame(timeout: .seconds(15)) else { return }
                await chunks.append(frame.payload)
            }
        }
    }
    defer { listener.cancel() }

    let client = SyncConnection(endpoint: loopbackEndpoint(port: port), key: key, localDeviceID: clientID)
    defer { Task { await client.cancel() } }
    try await client.start()

    var expected: [Data] = []
    for index in 0 ..< 20 {
        // Mix sizes so some frames span many TCP segments and some share one.
        let size = index % 2 == 0 ? 200_000 : 16
        let payload = Data(repeating: UInt8(index), count: size)
        expected.append(payload)
        try await client.send(chunk: payload)
    }

    for _ in 0 ..< 200 where await chunks.count() < 20 {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await chunks.all() == expected)
}

// Shared AsyncBox / AsyncCollector live in SyncTestSupport.swift.
