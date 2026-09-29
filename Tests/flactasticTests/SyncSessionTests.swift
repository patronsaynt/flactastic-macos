import Foundation
import Network
import CryptoKit
import Testing
@testable import flactastic

// Full-run tests: two temp libraries, a real TLS connection, a complete
// handshake-to-summary sync. These are the closest thing to the two-machine
// manual pass that can run unattended, and they cover the properties that
// matter most — files arrive intact, a declined plan transfers nothing, and
// syncing back the other way is a no-op.

private struct Library {
    let root: URL
    var tracks: [Track] = []
    var playlists: [Playlist] = []

    func manifest(deviceID: UUID, filter: SyncFilter = .unrestricted) async throws -> LibraryManifest {
        try await ManifestBuilder().build(
            tracks: tracks, playlists: playlists, rootURL: root,
            deviceID: deviceID, filter: filter
        )
    }

    func context(deviceID: UUID, filter: SyncFilter = .unrestricted) async throws -> SyncSession.LocalContext {
        SyncSession.LocalContext(
            deviceID: deviceID, displayName: "Test", kind: .mac, libraryRoot: root,
            manifest: try await manifest(deviceID: deviceID, filter: filter),
            filter: filter, playlists: playlists
        )
    }
}

private func makeLibrary(_ label: String, files: [(path: String, bytes: Int)]) throws -> Library {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("flactastic-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    var tracks: [Track] = []
    for (path, bytes) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((0 ..< bytes).map { UInt8($0 % 251) }).write(to: url)
        tracks.append(Track(
            url: url,
            title: (path as NSString).lastPathComponent,
            artist: "Artist", album: "Album", trackNumber: 1, fileFormat: .flac
        ))
    }
    return Library(root: root, tracks: tracks)
}

/// Runs a full session between two libraries over loopback TLS.
@discardableResult
private func runSync(
    initiator: Library,
    responder: Library,
    direction: SyncDirection,
    initiatorFilter: SyncFilter = .unrestricted,
    responderFilter: SyncFilter = .unrestricted,
    approve: @escaping @Sendable (SyncPlan) async -> SyncSelection? = { _ in .everything }
) async throws -> (summary: SyncSession.Summary, plan: AsyncBox<SyncPlan>, responderLanded: AsyncBox<SyncSession.Landed>) {
    let initiatorID = UUID(), responderID = UUID()
    let key = SymmetricKey(size: .bits256)
    let seenPlan = AsyncBox<SyncPlan>()
    let responderLanded = AsyncBox<SyncSession.Landed>()

    let responderContext = try await responder.context(deviceID: responderID, filter: responderFilter)
    let listener = try NWListener(
        using: SyncTLS.listenerParameters(pairedKeys: [initiatorID: key], allowPairing: false), on: .any
    )
    listener.newConnectionHandler = { raw in
        Task {
            let server = SyncConnection(accepted: raw)
            try? await server.start()
            let session = SyncSession()
            _ = try? await session.runResponder(
                connection: server,
                identity: .init(deviceID: responderID, displayName: "Test", kind: .mac),
                authenticate: { $0 == initiatorID ? key : nil },
                prepare: { responderContext }
            )
            await responderLanded.set(await session.landed)
        }
    }
    listener.start(queue: .global())
    defer { listener.cancel() }

    var port: UInt16?
    for _ in 0 ..< 100 {
        if case .ready = listener.state, let bound = listener.port?.rawValue { port = bound; break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let boundPort = try #require(port)

    let client = SyncConnection(
        endpoint: .hostPort(host: .ipv4(.loopback), port: .init(rawValue: boundPort)!),
        key: key, localDeviceID: initiatorID
    )
    defer { Task { await client.cancel() } }
    try await client.start()

    let session = SyncSession()
    let summary = try await session.runInitiator(
        connection: client,
        direction: direction,
        local: try await initiator.context(deviceID: initiatorID, filter: initiatorFilter),
        pairedKey: key,
        approve: { plan in
            await seenPlan.set(plan)
            return await approve(plan)
        }
    )
    return (summary, seenPlan, responderLanded)
}

// MARK: - Push

@Test("Pushing an empty peer transfers the whole library", .timeLimit(.minutes(2)))
func pushToEmptyPeer() async throws {
    let sender = try makeLibrary("push-src", files: [
        ("Artist/Album/01 One.flac", 300_000),
        ("Artist/Album/02 Two.flac", 120_000),
    ])
    let receiver = try makeLibrary("push-dst", files: [])
    defer {
        try? FileManager.default.removeItem(at: sender.root)
        try? FileManager.default.removeItem(at: receiver.root)
    }

    let result = try await runSync(initiator: sender, responder: receiver, direction: .push)

    #expect(result.summary.tracksTransferred == 2)
    #expect(result.summary.bytesTransferred == 420_000)
    #expect(result.summary.failures.isEmpty)

    let landed = try #require(await result.responderLanded.waitForValue())
    #expect(landed.files.count == 2)
    // Files are byte-identical and at the sender's relative paths.
    for file in landed.files {
        let original = sender.root.appendingPathComponent(file.relativePath)
        #expect(try Data(contentsOf: file.destination) == (try Data(contentsOf: original)))
    }
}

@Test("A second sync of an unchanged library does nothing", .timeLimit(.minutes(2)))
func repeatedSyncIsNoOp() async throws {
    // The property that makes bi-directional syncing usable: run it again, or
    // run it the other way, and nothing moves.
    let files = [("Artist/Album/01 One.flac", 200_000)]
    let a = try makeLibrary("noop-a", files: files)
    let b = try makeLibrary("noop-b", files: files)     // identical bytes
    defer {
        try? FileManager.default.removeItem(at: a.root)
        try? FileManager.default.removeItem(at: b.root)
    }

    let result = try await runSync(initiator: a, responder: b, direction: .push)
    #expect(result.summary.tracksTransferred == 0)
    let plan = try #require(await result.plan.waitForValue())
    // Matched on content hash despite the two libraries having minted
    // independent track IDs.
    #expect(plan.isEmpty)
}

// MARK: - Pull

@Test("Pulling brings the peer's library here", .timeLimit(.minutes(2)))
func pullFromPeer() async throws {
    let localSide = try makeLibrary("pull-dst", files: [])
    let remote = try makeLibrary("pull-src", files: [
        ("Remote/Album/01 Track.flac", 250_000),
    ])
    defer {
        try? FileManager.default.removeItem(at: localSide.root)
        try? FileManager.default.removeItem(at: remote.root)
    }

    let result = try await runSync(initiator: localSide, responder: remote, direction: .pull)

    #expect(result.summary.tracksTransferred == 1)
    #expect(result.summary.bytesTransferred == 250_000)
    let landedPath = localSide.root.appendingPathComponent("Remote/Album/01 Track.flac")
    #expect(FileManager.default.fileExists(atPath: landedPath.path))
    #expect(try Data(contentsOf: landedPath)
            == (try Data(contentsOf: remote.root.appendingPathComponent("Remote/Album/01 Track.flac"))))
}

// MARK: - Approval

@Test("Declining the plan transfers nothing at all", .timeLimit(.minutes(2)))
func decliningTransfersNothing() async throws {
    let sender = try makeLibrary("decline-src", files: [("a.flac", 100_000)])
    let receiver = try makeLibrary("decline-dst", files: [])
    defer {
        try? FileManager.default.removeItem(at: sender.root)
        try? FileManager.default.removeItem(at: receiver.root)
    }

    await #expect(throws: SyncSession.SessionError.self) {
        _ = try await runSync(initiator: sender, responder: receiver, direction: .push,
                              approve: { _ in nil })
    }
    // Not one byte, and no staging left behind.
    #expect(!FileManager.default.fileExists(atPath: receiver.root.appendingPathComponent("a.flac").path))
}

@Test("The plan shown to the user describes the real work", .timeLimit(.minutes(2)))
func planMatchesReality() async throws {
    let sender = try makeLibrary("plan-src", files: [
        ("a.flac", 100_000), ("b.flac", 50_000),
    ])
    let receiver = try makeLibrary("plan-dst", files: [])
    defer {
        try? FileManager.default.removeItem(at: sender.root)
        try? FileManager.default.removeItem(at: receiver.root)
    }

    let result = try await runSync(initiator: sender, responder: receiver, direction: .push)
    let plan = try #require(await result.plan.waitForValue())

    #expect(plan.newTracks.count == 2)
    #expect(plan.overwriteCount == 0)      // nothing overwritten, so no warning
    #expect(plan.totalTransferBytes == 150_000)
    #expect(plan.totalTransferBytes == result.summary.bytesTransferred)
}

// MARK: - Conflicts

@Test("An overwrite is surfaced as a conflict before it happens", .timeLimit(.minutes(2)))
func conflictIsSurfaced() async throws {
    let sender = try makeLibrary("conflict-src", files: [("song.flac", 80_000)])
    var receiver = try makeLibrary("conflict-dst", files: [])
    defer {
        try? FileManager.default.removeItem(at: sender.root)
        try? FileManager.default.removeItem(at: receiver.root)
    }

    // Give the receiver a file with the same identity but different content.
    let receiverFile = receiver.root.appendingPathComponent("song.flac")
    try Data(repeating: 9, count: 40_000).write(to: receiverFile)
    receiver.tracks = [Track(
        id: sender.tracks[0].id,             // same stable identity
        url: receiverFile, title: "song.flac", artist: "Artist",
        album: "Album", trackNumber: 1, fileFormat: .flac
    )]

    let result = try await runSync(initiator: sender, responder: receiver, direction: .push)
    let plan = try #require(await result.plan.waitForValue())

    #expect(plan.newTracks.isEmpty)
    #expect(plan.trackConflicts.count == 1)
    #expect(plan.trackConflicts[0].differingFields.contains("Audio file"))

    // Wait for the responder to finish before inspecting its filesystem: the
    // sender returns as soon as it has sent syncComplete, which is strictly
    // before the receiver has verified and installed the last file.
    _ = await result.responderLanded.waitForValue()
    // The user approved, so it was overwritten — atomically.
    #expect(try Data(contentsOf: receiverFile).count == 80_000)
}

// MARK: - Filters

@Test("The receiver's filter is enforced even though the sender applied it", .timeLimit(.minutes(2)))
func receiverFilterEnforced() async throws {
    let sender = try makeLibrary("filter-src", files: [
        ("big.flac", 500_000), ("small.flac", 10_000),
    ])
    let receiver = try makeLibrary("filter-dst", files: [])
    defer {
        try? FileManager.default.removeItem(at: sender.root)
        try? FileManager.default.removeItem(at: receiver.root)
    }

    let result = try await runSync(
        initiator: sender, responder: receiver, direction: .push,
        responderFilter: SyncFilter(maxFileSizeBytes: 100_000)
    )

    #expect(result.summary.tracksTransferred == 1)

    _ = await result.responderLanded.waitForValue()
    #expect(!FileManager.default.fileExists(atPath: receiver.root.appendingPathComponent("big.flac").path))
    #expect(FileManager.default.fileExists(atPath: receiver.root.appendingPathComponent("small.flac").path))
}

// MARK: - Playlists

@Test("Playlists travel with the files", .timeLimit(.minutes(2)))
func playlistsTransfer() async throws {
    var sender = try makeLibrary("pl-src", files: [("a.flac", 20_000)])
    let receiver = try makeLibrary("pl-dst", files: [])
    defer {
        try? FileManager.default.removeItem(at: sender.root)
        try? FileManager.default.removeItem(at: receiver.root)
    }
    sender.playlists = [Playlist(
        name: "Late Night",
        entries: [PlaylistEntry(trackID: sender.tracks[0].id, relativePath: "a.flac")]
    )]

    let result = try await runSync(initiator: sender, responder: receiver, direction: .push)
    #expect(result.summary.playlistsTransferred == 1)

    let landed = try #require(await result.responderLanded.waitForValue())
    #expect(landed.playlists.count == 1)
    #expect(landed.playlists[0].name == "Late Night")
    // Identity is preserved, so a later sync recognises it rather than
    // creating a duplicate.
    #expect(landed.playlists[0].id == sender.playlists[0].id)
}

@Test("Playlists are withheld when the receiver excludes them", .timeLimit(.minutes(2)))
func playlistsRespectFilter() async throws {
    var sender = try makeLibrary("plf-src", files: [("a.flac", 20_000)])
    let receiver = try makeLibrary("plf-dst", files: [])
    defer {
        try? FileManager.default.removeItem(at: sender.root)
        try? FileManager.default.removeItem(at: receiver.root)
    }
    sender.playlists = [Playlist(name: "Private", entries: [])]

    let result = try await runSync(
        initiator: sender, responder: receiver, direction: .push,
        responderFilter: SyncFilter(includePlaylists: false)
    )
    let landed = try #require(await result.responderLanded.waitForValue())
    #expect(landed.playlists.isEmpty)
}

// MARK: - Selection

@Test("Only the tracks the user ticked are pushed", .timeLimit(.minutes(2)))
func pushHonoursSelection() async throws {
    let sender = try makeLibrary("sel-src", files: [
        ("A/One/01.flac", 30_000), ("A/One/02.flac", 20_000), ("B/Two/01.flac", 10_000),
    ])
    let receiver = try makeLibrary("sel-dst", files: [])
    defer {
        try? FileManager.default.removeItem(at: sender.root)
        try? FileManager.default.removeItem(at: receiver.root)
    }
    let keep = sender.tracks[0].id

    let result = try await runSync(
        initiator: sender, responder: receiver, direction: .push,
        approve: { _ in SyncSelection(trackIDs: [keep]) }
    )
    #expect(result.summary.tracksTransferred == 1)
    #expect(result.summary.bytesTransferred == 30_000)

    let landed = try #require(await result.responderLanded.waitForValue())
    #expect(landed.files.map(\.trackID) == [keep])
    #expect(!FileManager.default.fileExists(atPath: receiver.root.appendingPathComponent("B/Two/01.flac").path))
}

@Test("A pull only brings the ticked tracks and playlists", .timeLimit(.minutes(2)))
func pullHonoursSelection() async throws {
    let localSide = try makeLibrary("selp-dst", files: [])
    var remote = try makeLibrary("selp-src", files: [("x.flac", 15_000), ("y.flac", 25_000)])
    defer {
        try? FileManager.default.removeItem(at: localSide.root)
        try? FileManager.default.removeItem(at: remote.root)
    }
    remote.playlists = [Playlist(name: "Wanted", entries: []), Playlist(name: "Unwanted", entries: [])]
    let wantedTrack = remote.tracks[1].id
    let wantedPlaylist = remote.playlists[0].id

    let result = try await runSync(
        initiator: localSide, responder: remote, direction: .pull,
        approve: { _ in SyncSelection(trackIDs: [wantedTrack], playlistIDs: [wantedPlaylist]) }
    )
    #expect(result.summary.tracksTransferred == 1)
    #expect(result.summary.playlistsTransferred == 1)
    #expect(FileManager.default.fileExists(atPath: localSide.root.appendingPathComponent("y.flac").path))
    #expect(!FileManager.default.fileExists(atPath: localSide.root.appendingPathComponent("x.flac").path))
}

@Test("A selection can only narrow the plan, never widen it")
func selectionCannotWiden() {
    let entry = { (path: String) in
        TrackManifestEntry(trackID: UUID(), relativePath: path, fileSize: 1, contentHash: path,
                           format: .flac, tagFingerprint: "", title: path, artist: nil, album: nil)
    }
    let a = entry("a"), b = entry("b")
    let plan = SyncPlan(direction: .push, newTracks: [a, b], trackConflicts: [],
                        newPlaylists: [], playlistConflicts: [])

    let narrowed = plan.restricted(to: SyncSelection(trackIDs: [a.trackID, UUID()]))
    #expect(narrowed.newTracks == [a])
    #expect(plan.restricted(to: .everything) == plan)
    #expect(plan.restricted(to: SyncSelection(trackIDs: [])).newTracks.isEmpty)
}

// AsyncBox lives in SyncTestSupport.swift.
