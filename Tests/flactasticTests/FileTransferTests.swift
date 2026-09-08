import Foundation
import Network
import CryptoKit
import Testing
@testable import flactastic

// End-to-end file transfer over a real loopback TLS connection: two temp
// library roots, one sender, one receiver. These are the tests that prove a
// file arrives byte-identical, that a corrupted one never enters the library,
// and that an interrupted transfer resumes instead of starting over.

private struct TransferHarness {
    let senderRoot: URL
    let receiverRoot: URL
    let listener: NWListener
    let port: UInt16

    func tearDown() {
        listener.cancel()
        try? FileManager.default.removeItem(at: senderRoot)
        try? FileManager.default.removeItem(at: receiverRoot)
    }
}

private func makeRoot(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flactastic-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Deterministic pseudo-audio: large enough to span many chunks.
private func makePayload(bytes: Int, seed: UInt8 = 7) -> Data {
    Data((0 ..< bytes).map { UInt8(($0 &* 31 &+ Int(seed)) % 251) })
}

private func manifestEntry(for url: URL, root: URL, id: UUID = UUID()) throws -> TrackManifestEntry {
    let size = ManifestBuilder.fileSize(of: url)!
    return TrackManifestEntry(
        trackID: id,
        relativePath: TrackMetadataCache.relativePath(for: url, rootPath: root.path),
        fileSize: size,
        contentHash: try ContentHasher.hexDigest(ofFileAt: url),
        format: .flac,
        tagFingerprint: "fp",
        title: "Song", artist: "Artist", album: "Album"
    )
}

/// Standard placement: sanitise the peer's path and resolve it under our root.
private func placement(under root: URL) -> @Sendable (String) throws -> URL {
    { relativePath in
        try PathSanitizer.destinationForIncomingTrack(remoteRelativePath: relativePath, under: root)
    }
}

// MARK: -

@Test("A file arrives byte-identical and lands in the right place", .timeLimit(.minutes(1)))
func fileTransfersIntact() async throws {
    let senderRoot = try makeRoot("send")
    let receiverRoot = try makeRoot("recv")
    defer {
        try? FileManager.default.removeItem(at: senderRoot)
        try? FileManager.default.removeItem(at: receiverRoot)
    }

    let source = senderRoot.appendingPathComponent("Artist/Album/01 Song.flac")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let payload = makePayload(bytes: 2_500_000)     // spans three chunks
    try payload.write(to: source)
    let entry = try manifestEntry(for: source, root: senderRoot)

    let clientID = UUID()
    let key = SymmetricKey(size: .bits256)
    let outcome = AsyncBox<FileTransfer.ReceivedFile>()

    let parameters = SyncTLS.listenerParameters(pairedKeys: [clientID: key], allowPairing: false)
    let listener = try NWListener(using: parameters, on: .any)
    listener.newConnectionHandler = { raw in
        Task {
            let server = SyncConnection(accepted: raw)
            try? await server.start()
            guard let message = try? await server.receiveMessage(timeout: .seconds(20)),
                  case .fileStart(let start) = message else { return }
            let transfer = FileTransfer()
            if let received = try? await transfer.receive(
                start: start, over: server, libraryRoot: receiverRoot,
                placement: placement(under: receiverRoot)
            ) {
                await outcome.set(received)
            }
        }
    }
    listener.start(queue: .global())
    defer { listener.cancel() }

    let port = try await waitForPort(listener)
    let client = SyncConnection(
        endpoint: .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!),
        key: key, localDeviceID: clientID
    )
    defer { Task { await client.cancel() } }
    try await client.start()

    let sent = try await FileTransfer().send(entry: entry, from: source, over: client)
    #expect(sent == entry.fileSize)

    let received = try #require(await outcome.waitForValue())
    #expect(received.bytesWritten == entry.fileSize)
    // Landed under the receiver's root, at the sender's relative path.
    #expect(PathSanitizer.isContained(received.destination, in: receiverRoot.resolvingSymlinksInPath()))
    #expect(received.destination.lastPathComponent == "01 Song.flac")
    // Byte-identical, not merely the same length.
    #expect(try Data(contentsOf: received.destination) == payload)
    // Nothing left behind in the staging directory.
    #expect(!FileManager.default.fileExists(
        atPath: receiverRoot.appendingPathComponent(".flactastic/incoming/\(entry.trackID.uuidString).part").path
    ))
}

@Test("A file whose checksum doesn't match never enters the library", .timeLimit(.minutes(1)))
func corruptedFileIsRejected() async throws {
    let senderRoot = try makeRoot("send")
    let receiverRoot = try makeRoot("recv")
    defer {
        try? FileManager.default.removeItem(at: senderRoot)
        try? FileManager.default.removeItem(at: receiverRoot)
    }

    let source = senderRoot.appendingPathComponent("song.flac")
    try makePayload(bytes: 50_000).write(to: source)
    var entry = try manifestEntry(for: source, root: senderRoot)
    // Claim a digest the bytes do not have — a corrupted transfer, or a peer
    // sending different content than it advertised.
    entry = TrackManifestEntry(
        trackID: entry.trackID, relativePath: entry.relativePath, fileSize: entry.fileSize,
        contentHash: String(repeating: "0", count: 64), format: entry.format,
        tagFingerprint: entry.tagFingerprint, title: entry.title,
        artist: entry.artist, album: entry.album
    )

    let clientID = UUID()
    let key = SymmetricKey(size: .bits256)
    let failed = AsyncBox<Bool>()

    let listener = try NWListener(
        using: SyncTLS.listenerParameters(pairedKeys: [clientID: key], allowPairing: false), on: .any
    )
    listener.newConnectionHandler = { raw in
        Task {
            let server = SyncConnection(accepted: raw)
            try? await server.start()
            guard let message = try? await server.receiveMessage(timeout: .seconds(20)),
                  case .fileStart(let start) = message else { return }
            do {
                _ = try await FileTransfer().receive(
                    start: start, over: server, libraryRoot: receiverRoot,
                    placement: placement(under: receiverRoot)
                )
                await failed.set(false)
            } catch {
                await failed.set(true)
            }
        }
    }
    listener.start(queue: .global())
    defer { listener.cancel() }

    let port = try await waitForPort(listener)
    let client = SyncConnection(
        endpoint: .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!),
        key: key, localDeviceID: clientID
    )
    defer { Task { await client.cancel() } }
    try await client.start()
    _ = try? await FileTransfer().send(entry: entry, from: source, over: client)

    #expect(await failed.waitForValue() == true)
    // Neither installed nor left as a partial for a later resume: the bytes we
    // hold are known-bad, so keeping them would only reproduce the failure.
    #expect(!FileManager.default.fileExists(atPath: receiverRoot.appendingPathComponent("song.flac").path))
    #expect(!FileManager.default.fileExists(
        atPath: receiverRoot.appendingPathComponent(".flactastic/incoming/\(entry.trackID.uuidString).part").path
    ))
}

@Test("An interrupted transfer resumes from the bytes already held", .timeLimit(.minutes(1)))
func transferResumes() async throws {
    let senderRoot = try makeRoot("send")
    let receiverRoot = try makeRoot("recv")
    defer {
        try? FileManager.default.removeItem(at: senderRoot)
        try? FileManager.default.removeItem(at: receiverRoot)
    }

    let source = senderRoot.appendingPathComponent("song.flac")
    let payload = makePayload(bytes: 3_000_000)
    try payload.write(to: source)
    let entry = try manifestEntry(for: source, root: senderRoot)

    // Simulate a run that died after the first chunk: a .part file holding a
    // correct prefix of the payload.
    let partDirectory = receiverRoot.appendingPathComponent(".flactastic/incoming", isDirectory: true)
    try FileManager.default.createDirectory(at: partDirectory, withIntermediateDirectories: true)
    let partURL = partDirectory.appendingPathComponent("\(entry.trackID.uuidString).part")
    let alreadyHeld = 1_000_000
    try payload.prefix(alreadyHeld).write(to: partURL)

    let clientID = UUID()
    let key = SymmetricKey(size: .bits256)
    let outcome = AsyncBox<FileTransfer.ReceivedFile>()

    let listener = try NWListener(
        using: SyncTLS.listenerParameters(pairedKeys: [clientID: key], allowPairing: false), on: .any
    )
    listener.newConnectionHandler = { raw in
        Task {
            let server = SyncConnection(accepted: raw)
            try? await server.start()
            guard let message = try? await server.receiveMessage(timeout: .seconds(20)),
                  case .fileStart(let start) = message else { return }
            if let received = try? await FileTransfer().receive(
                start: start, over: server, libraryRoot: receiverRoot,
                placement: placement(under: receiverRoot)
            ) {
                await outcome.set(received)
            }
        }
    }
    listener.start(queue: .global())
    defer { listener.cancel() }

    let port = try await waitForPort(listener)
    let client = SyncConnection(
        endpoint: .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!),
        key: key, localDeviceID: clientID
    )
    defer { Task { await client.cancel() } }
    try await client.start()

    let sent = try await FileTransfer().send(entry: entry, from: source, over: client)
    // Only the remainder crossed the wire — that is the whole point of resume.
    #expect(sent == entry.fileSize - Int64(alreadyHeld))

    let received = try #require(await outcome.waitForValue())
    #expect(received.bytesWritten == entry.fileSize)
    // And the spliced file still verifies byte-for-byte.
    #expect(try Data(contentsOf: received.destination) == payload)
}

@Test("A file the receiver already has is skipped without transferring", .timeLimit(.minutes(1)))
func alreadyHeldFileIsSkipped() async throws {
    let senderRoot = try makeRoot("send")
    let receiverRoot = try makeRoot("recv")
    defer {
        try? FileManager.default.removeItem(at: senderRoot)
        try? FileManager.default.removeItem(at: receiverRoot)
    }

    let source = senderRoot.appendingPathComponent("song.flac")
    try makePayload(bytes: 100_000).write(to: source)
    let entry = try manifestEntry(for: source, root: senderRoot)

    let clientID = UUID()
    let key = SymmetricKey(size: .bits256)

    let listener = try NWListener(
        using: SyncTLS.listenerParameters(pairedKeys: [clientID: key], allowPairing: false), on: .any
    )
    listener.newConnectionHandler = { raw in
        Task {
            let server = SyncConnection(accepted: raw)
            try? await server.start()
            guard let message = try? await server.receiveMessage(timeout: .seconds(20)),
                  case .fileStart(let start) = message else { return }
            _ = try? await FileTransfer().receive(
                start: start, over: server, libraryRoot: receiverRoot,
                placement: placement(under: receiverRoot),
                alreadyHave: { _, _ in true }
            )
        }
    }
    listener.start(queue: .global())
    defer { listener.cancel() }

    let port = try await waitForPort(listener)
    let client = SyncConnection(
        endpoint: .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!),
        key: key, localDeviceID: clientID
    )
    defer { Task { await client.cancel() } }
    try await client.start()

    #expect(try await FileTransfer().send(entry: entry, from: source, over: client) == 0)
}

// MARK: - Housekeeping

@Test("Abandoned part files are swept, recent ones are kept")
func sweepsOldPartFiles() throws {
    let root = try makeRoot("sweep")
    defer { try? FileManager.default.removeItem(at: root) }

    let directory = root.appendingPathComponent(".flactastic/incoming", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let stale = directory.appendingPathComponent("\(UUID().uuidString).part")
    let fresh = directory.appendingPathComponent("\(UUID().uuidString).part")
    try Data([1]).write(to: stale)
    try Data([1]).write(to: fresh)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-30 * 24 * 3600)], ofItemAtPath: stale.path
    )

    FileTransfer.sweepAbandonedPartFiles(libraryRoot: root)
    // A partial from a month ago will never resume; one from this session might.
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
}

// MARK: - Helpers

private func waitForPort(_ listener: NWListener) async throws -> UInt16 {
    for _ in 0 ..< 100 {
        if case .ready = listener.state, let port = listener.port?.rawValue { return port }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw TransferTestError.listenerNeverReady
}

private enum TransferTestError: Error { case listenerNeverReady }

// AsyncBox lives in SyncTestSupport.swift.
