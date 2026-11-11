import AppKit
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import flactastic

// Against a running FLACtastic Server. Skipped unless these are set:
//   FLACTASTIC_TEST_SERVER        host:port
//   FLACTASTIC_TEST_FINGERPRINT   what `flactastic-server info` prints
//   FLACTASTIC_TEST_USERS         alice:password,bob:password (two users)
// Each user's library must hold at least one track.

private let env = ProcessInfo.processInfo.environment
private let enabled = env["FLACTASTIC_TEST_SERVER"] != nil

private struct Account {
    let client: ServerClient
    let name: String
    let password: String
}

private enum Live {
    static let address = ServerAddress(typed: env["FLACTASTIC_TEST_SERVER"] ?? "")!
    static var users: [(String, String)] {
        (env["FLACTASTIC_TEST_USERS"] ?? "").split(separator: ",").map {
            let p = $0.split(separator: ":", maxSplits: 1)
            return (String(p[0]), String(p[1]))
        }
    }

    static func pin() async throws -> Data { try await ServerSession.probe(address).1 }

    static func signIn(_ index: Int, device: String = "Integration Test") async throws -> Account {
        let (name, password) = users[index]
        let client = ServerClient(address: address, pin: try await pin())
        struct Login: Encodable { let username, password, deviceName, deviceKind: String }
        // Deliberate failures in other tests count against this IP (§6):
        // wait out Retry-After like the app does.
        var attempt = 0
        let r: LoginResponse
        while true {
            do {
                r = try await client.json(LoginResponse.self, "POST", "v2/auth/login",
                                          body: Login(username: name, password: password, deviceName: device, deviceKind: "mac"))
                break
            } catch ServerError.api("rateLimited", _, let retry) where attempt < 6 {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(retry ?? 1)))
            }
        }
        client.token = r.token
        return Account(client: client, name: name, password: password)
    }

    static func tracks(_ c: ServerClient) async throws -> [ServerTrack] {
        var all: [ServerTrack] = [], since = 0, more = true
        while more {
            let page = try await c.json(TracksPage.self, "GET", "v2/tracks", query: [
                URLQueryItem(name: "since", value: String(since)), URLQueryItem(name: "limit", value: "2")])
            all += page.tracks
            since = page.seq
            more = page.more
        }
        return all
    }

    static func status(_ c: ServerClient, _ method: String, _ path: String, body: Data? = nil) async -> Int {
        do { return try await c.data(for: c.request(method, path, body: body)).1.statusCode }
        catch ServerError.api(_, let status, _) { return status }
        catch { return -1 }
    }
}

@Suite(.enabled(if: enabled), .serialized)
struct ServerIntegrationTests {

    @Test("§3: the pinned key's fingerprint is what flactastic-server info prints; a wrong pin is a hard failure")
    func trust() async throws {
        let pin = try await Live.pin()
        if let expected = env["FLACTASTIC_TEST_FINGERPRINT"] { #expect(ServerPin.display(pin) == expected) }
        var wrong = pin
        wrong[0] ^= 0xFF
        let client = ServerClient(address: Live.address, pin: wrong)
        await #expect(throws: ServerError.identityChanged) {
            _ = try await client.json(ServerInfo.self, "GET", "v2/server")
        }
        let info = try await ServerClient(address: Live.address, pin: pin).json(ServerInfo.self, "GET", "v2/server")
        #expect(info.isCompatible)
    }

    @Test("§6: bad credentials say invalidCredentials; a revoked token says unauthorized")
    func signInAndRevoke() async throws {
        let client = ServerClient(address: Live.address, pin: try await Live.pin())
        struct Login: Encodable { let username, password, deviceName, deviceKind: String }
        // Earlier runs' deliberate failures may have this IP backing off (§6).
        var wrong: ServerError?
        for _ in 0..<6 {
            do {
                _ = try await client.json(LoginResponse.self, "POST", "v2/auth/login",
                                          body: Login(username: Live.users[0].0, password: "definitely-wrong", deviceName: "x", deviceKind: "mac"))
            } catch let e as ServerError {
                wrong = e
                guard case .api("rateLimited", _, let retry) = e else { break }
                try await Task.sleep(for: .seconds(Double(retry ?? 1)))
            }
        }
        #expect(wrong == .api(code: "invalidCredentials", status: 401, retryAfter: nil))
        let a = try await Live.signIn(0, device: "To Revoke")
        let b = try await Live.signIn(0)
        struct Me: Decodable { let device: ServerDevice }
        let me = try await a.client.json(Me.self, "GET", "v2/me")
        struct Devices: Decodable { let devices: [ServerDevice] }
        #expect(try await b.client.json(Devices.self, "GET", "v2/devices").devices.contains { $0.id == me.device.id })
        try await b.client.send("DELETE", "v2/devices/\(me.device.id.uuidString)")
        await #expect(throws: ServerError.api(code: "unauthorized", status: 401, retryAfter: nil)) {
            _ = try await a.client.json(Me.self, "GET", "v2/me")
        }
        try await b.client.send("POST", "v2/auth/logout")
    }

    @Test("Users are isolated: nothing one user can name reaches another's tracks, files, art, playlists or history")
    func isolation() async throws {
        let alice = try await Live.signIn(0), bob = try await Live.signIn(1)
        let aliceTracks = try await Live.tracks(alice.client)
        let bobTracks = try await Live.tracks(bob.client)
        #expect(!aliceTracks.isEmpty && !bobTracks.isEmpty)
        #expect(Set(aliceTracks.map(\.id)).isDisjoint(with: bobTracks.map(\.id)))
        let theirs = bobTracks[0]
        #expect(await Live.status(alice.client, "GET", "v2/tracks/\(theirs.id.uuidString)") == 404)
        #expect(await Live.status(alice.client, "GET", "v2/tracks/\(theirs.id.uuidString)/file") == 404)
        #expect(await Live.status(alice.client, "GET", "v2/tracks/\(theirs.id.uuidString)/stream") == 404)
        #expect(await Live.status(alice.client, "PATCH", "v2/tracks/\(theirs.id.uuidString)", body: Data(#"{"title":"x"}"#.utf8)) == 404)
        #expect(await Live.status(alice.client, "DELETE", "v2/tracks/\(theirs.id.uuidString)") == 404)
        if let art = theirs.artworkID, !aliceTracks.contains(where: { $0.artworkID == art }) {
            #expect(await Live.status(alice.client, "GET", "v2/art/\(art)") == 404)
        }

        let list = Playlist(name: "Bob's secret", entries: [PlaylistEntry(trackID: theirs.id, relativePath: theirs.relativePath)])
        try await bob.client.send("PUT", "v2/playlists/\(list.id.uuidString)", body: list)
        #expect(await Live.status(alice.client, "GET", "v2/playlists/\(list.id.uuidString)") == 404)
        struct Lists: Decodable { let playlists: [Playlist] }
        #expect(!(try await alice.client.json(Lists.self, "GET", "v2/playlists").playlists.contains { $0.id == list.id }))
        try await bob.client.send("DELETE", "v2/playlists/\(list.id.uuidString)")

        let event = PlayEvent(date: .now, trackID: theirs.id, title: "Bob only", secondsListened: 30, counted: true)
        struct Post: Encodable { let events: [PlayEvent]; let contexts: [RecentContext] }
        try await bob.client.send("POST", "v2/history", body: Post(events: [event], contexts: []))
        struct Page: Decodable { let events: [PlayEvent] }
        let aliceHistory = try await alice.client.json(Page.self, "GET", "v2/history", query: [URLQueryItem(name: "since", value: "0")])
        #expect(!aliceHistory.events.contains { $0.id == event.id })
    }

    @Test("§7, §9.1: the mirror pages by seq, and originals answer ranges")
    func mirrorAndRanges() async throws {
        let alice = try await Live.signIn(0)
        let tracks = try await Live.tracks(alice.client)
        let t = try #require(tracks.first { $0.fileSize > 4096 })
        #expect(t.appTrack(root: URL(fileURLWithPath: "/tmp/x")) != nil)
        var r = alice.client.request("GET", "v2/tracks/\(t.id.uuidString)/file")
        r.setValue("bytes=100-1123", forHTTPHeaderField: "Range")
        let (data, http) = try await alice.client.data(for: r)
        #expect(http.statusCode == 206)
        #expect(data.count == 1024)
        let (whole, _, _) = try await ServerStreamer.fetch(alice.client, t.id, 0..<t.fileSize, nil)
        #expect(whole.subdata(in: 100..<1124) == data)
        if let hash = t.contentHash { #expect(ContentHasher.hexDigest(of: whole) == hash) }
    }

    @Test("§9.2: a transcode decodes to exactly FLACtastic-Frames after trimming, also from a seek")
    func transcodeIsGapless() async throws {
        let alice = try await Live.signIn(0)
        guard try await alice.client.json(ServerInfo.self, "GET", "v2/server").transcoding else { return }
        let t = try #require(try await Live.tracks(alice.client).first { $0.format == "flac" && ($0.duration ?? 0) > 3 })
        for seconds in [0.0, 1.5] {
            var r = alice.client.request("GET", "v2/tracks/\(t.id.uuidString)/stream", query: [
                URLQueryItem(name: "quality", value: "normal"),
                URLQueryItem(name: "s", value: String(Int(seconds * Double(t.sampleRate ?? 44_100))))])
            r.timeoutInterval = 60
            let (_, http) = try await alice.client.data(for: r)
            let expected = try #require(http.value(forHTTPHeaderField: "FLACtastic-Frames").flatMap(Int64.init))
            let store = try await ADTSStore.open(client: alice.client, trackID: t.id, quality: .normal, seconds: seconds,
                                                 sourceRate: Double(t.sampleRate ?? 44_100), onSpeed: { _ in })
            let source = try #require(store.reader(at: seconds))
            let buffer = AVAudioPCMBuffer(pcmFormat: try source.waitForFormat(), frameCapacity: 8192)!
            var total: Int64 = 0
            repeat {
                try source.read(into: buffer, frameCount: 8192)
                total += Int64(buffer.frameLength)
            } while buffer.frameLength > 0
            #expect(total == expected)
        }
    }

    @Test("§9.4, §10: an upload resumes, is filed by the profile, and a tag edit sends only what changed")
    func uploadAndEdit() async throws {
        let alice = try await Live.signIn(0), bob = try await Live.signIn(1)
        let source = try #require(try await Live.tracks(alice.client).first { $0.format == "flac" && $0.fileSize > 100_000 })
        let (bytes, _, _) = try await ServerStreamer.fetch(alice.client, source.id, 0..<source.fileSize, nil)
        // A different file: the same audio with a byte of padding changed would
        // be refused by TagLib, so re-tag after upload instead and upload as new.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).flac")
        try bytes.write(to: file)
        let hash = ContentHasher.hexDigest(of: bytes)
        struct Create: Encodable { let filename: String; let size: Int64; let contentHash: String; let trackID: UUID? }
        struct Opened: Decodable { let id: UUID; let offset: Int64 }
        let newID = UUID()
        let opened = try await alice.client.json(Opened.self, "POST", "v2/uploads",
                                                 body: Create(filename: "x.flac", size: Int64(bytes.count), contentHash: hash, trackID: newID))
        // Half now, then pretend the ID was lost: re-posting finds the same upload.
        let half = Int64(bytes.count / 2)
        var r = alice.client.request("PATCH", "v2/uploads/\(opened.id.uuidString)", body: bytes.prefix(Int(half)),
                                     contentType: "application/offset+octet-stream")
        r.setValue("0", forHTTPHeaderField: "Upload-Offset")
        _ = try await alice.client.data(for: r)
        let again = try await alice.client.json(Opened.self, "POST", "v2/uploads",
                                                body: Create(filename: "x.flac", size: Int64(bytes.count), contentHash: hash, trackID: newID))
        #expect(again.id == opened.id)
        #expect(again.offset == half)
        let bobSees = await Live.status(bob.client, "HEAD", "v2/uploads/\(opened.id.uuidString)")
        #expect(bobSees == 404)
        let track = try await ServerUploads.send(file, upload: again.id, from: again.offset, size: Int64(bytes.count),
                                                 client: alice.client, chunk: 1 << 20) { _ in }
        #expect(track.id == newID)
        #expect(!track.relativePath.isEmpty)

        let editor = ServerTagEditor(client: alice.client, root: URL(fileURLWithPath: "/tmp/offline"))
        let app = try #require(track.appTrack(root: editor.root))
        var edit = TagEdit()
        edit.text("title", app.title, "Integration \(UUID().uuidString.prefix(6))")
        edit.number("year", app.year, 1999)
        let edited = try await editor.apply(edit, to: app)
        #expect(edited.title.hasPrefix("Integration"))
        #expect(edited.year == 1999)
        #expect(edited.album == app.album, "fields left out of the edit are untouched")
        try await alice.client.send("DELETE", "v2/tracks/\(newID.uuidString)")
    }

    @Test("§11: a change wakes a long-poll")
    func changesWake() async throws {
        let alice = try await Live.signIn(0)
        let seq = try await alice.client.json(LibraryInfo.self, "GET", "v2/library").seq
        async let woke = alice.client.json(ChangesResponse.self, "GET", "v2/changes", query: [
            URLQueryItem(name: "since", value: String(seq)), URLQueryItem(name: "wait", value: "20")], timeout: 40)
        try await Task.sleep(for: .milliseconds(500))
        try await alice.client.send("PATCH", "v2/prefs", body: ServerPrefs(streamQuality: "high"))
        let changes = try await woke
        #expect(changes.changed.contains("prefs"))
        let prefs = try await alice.client.json(ServerPrefs.self, "GET", "v2/prefs")
        #expect(prefs.streamQuality == "high")
        try await alice.client.send("PATCH", "v2/prefs", body: ServerPrefs(streamQuality: "original"))
    }

    @Test("§12: the Organizer previews on the server and refuses a stale plan")
    func organizer() async throws {
        let alice = try await Live.signIn(0)
        let state = try await alice.client.json(ServerSession.OrganizerState.self, "GET", "v2/organizer")
        let profile = state.profiles.first ?? OrganizerProfile.default
        try await alice.client.send("PUT", "v2/organizer", body: ServerSession.OrganizerState(profiles: [profile], selectedID: profile.id))
        struct Body: Encodable { let profileID: UUID; let planHash: String }
        let plan = try await alice.client.json(ServerSession.OrganizerPlan.self, "POST", "v2/organizer/plan",
                                               body: ["profileID": profile.id])
        #expect(!plan.operations.isEmpty)
        #expect(await Live.status(alice.client, "POST", "v2/organizer/apply",
                                  body: try ServerClient.encoder.encode(Body(profileID: profile.id, planHash: String(repeating: "0", count: 64)))) == 409)
    }

    @Test("§13: a manifest diffs into downloads that verify against contentHash")
    func offlineManifest() async throws {
        let alice = try await Live.signIn(0)
        struct Request: Encodable { let filter: SyncFilter }
        let manifest = try await alice.client.json(LibraryManifest.self, "POST", "v2/manifest",
                                                   body: Request(filter: SyncFilter(excludedFormats: [.mp3])))
        #expect(!manifest.tracks.isEmpty)
        #expect(!manifest.tracks.contains { $0.format == .mp3 })
        let plan = SyncDiff.plan(incoming: manifest, local: LibraryManifest(deviceID: UUID(), tracks: [], playlists: []), direction: .pull)
        let first = try #require(plan.newTracks.min { $0.fileSize < $1.fileSize })
        let (bytes, _, _) = try await ServerStreamer.fetch(alice.client, first.trackID, 0..<first.fileSize, nil)
        #expect(ContentHasher.digestsMatch(ContentHasher.hexDigest(of: bytes), first.contentHash))
    }

    @Test("§15: history is idempotent by event ID")
    func historyIdempotent() async throws {
        let alice = try await Live.signIn(0)
        let t = try #require(try await Live.tracks(alice.client).first)
        let event = PlayEvent(date: .now, trackID: t.id, title: t.title, secondsListened: 12, counted: false)
        struct Post: Encodable { let events: [PlayEvent]; let contexts: [RecentContext] }
        struct Accepted: Decodable { let accepted: Int }
        let first = try await alice.client.json(Accepted.self, "POST", "v2/history", body: Post(events: [event], contexts: []))
        let second = try await alice.client.json(Accepted.self, "POST", "v2/history", body: Post(events: [event], contexts: []))
        #expect(first.accepted == 1 && second.accepted == 0)
    }

    @MainActor
    @Test("End to end: a server profile fills the library, plays, keeps an album offline, and syncs playlists and plays")
    func sessionEndToEnd() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("flactastic-e2e-\(UUID().uuidString)")
        let library = LibraryStore(), playlists = PlaylistStore()
        let listening = ListeningStore(librariesDirectory: temp.appendingPathComponent("libraries"))
        let session = ServerSession(library: library, playlists: playlists, listening: listening,
                                    settings: Settings(), writer: MetadataWriter())
        let (info, pin) = try await ServerSession.probe(Live.address)
        let (name, password) = Live.users[0]
        try await session.signIn(address: Live.address, info: info, pin: pin, username: name, password: password,
                                 offlineFolder: temp.appendingPathComponent("offline"))
        let profile = try #require(session.active)
        defer {
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: profile.supportDirectory)
        }

        func until(_ seconds: Double = 15, _ condition: () async -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while await !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        }

        // The mirror becomes the library, built by LibraryStore's own album code.
        await until { session.status == .ready && library.tracks.contains { $0.title == "Tone A" } }
        let tone = try #require(library.tracks.first { $0.title == "Tone A" })
        let album = try #require(library.albums.first { $0.name == "Long Tones" })
        #expect(album.tracks.count == 3)
        #expect(tone.url.path.hasPrefix(profile.offlineFolder))

        // Playback: the original streams progressively, sample-exact length.
        let original = try #require(try await session.streamer.open(tone, at: 0))
        #expect(original is RemoteAudioSource)
        #expect(original.playbackSource == .streaming)
        #expect(original.length == 12 * 44_100)

        // A queued copy (fresh ID, same URL) still resolves to the server track.
        #expect(try await session.streamer.open(tone.withNewID(), at: 0) != nil)

        // A transcode, by the user's synced quality, trimmed to the source's length.
        await session.prefs.setStreamQuality(.normal)
        let transcode = try #require(try await session.streamer.open(tone, at: 0))
        #expect(transcode is ADTSStreamSource)
        #expect(transcode.playbackSource == .transcode(.normal))
        let buffer = AVAudioPCMBuffer(pcmFormat: transcode.processingFormat, frameCapacity: 8192)!
        var frames: Int64 = 0
        repeat { try transcode.read(into: buffer, frameCount: 8192); frames += Int64(buffer.frameLength) } while buffer.frameLength > 0
        #expect(frames == 12 * 44_100)
        await session.prefs.setStreamQuality(.original)

        // Offline: keep the album; the copies download, verify and install,
        // and playback then prefers them over any stream.
        session.offline.setAlbum(album.id, kept: true)
        await until(30) { album.tracks.allSatisfy { session.offline.isCurrent($0.id) } }
        #expect(album.tracks.allSatisfy { session.offline.isCurrent($0.id) })
        #expect(FileManager.default.fileExists(atPath: tone.url.path))
        #expect(try await session.streamer.open(tone, at: 0)?.playbackSource == .offline)
        let xattr = tone.url.path.withCString { getxattr($0, "com.flactastic.trackID", nil, 0, 0, 0) }
        #expect(xattr == 36)

        // Playlists: a new one reaches the server in the Mac's JSON.
        let list = playlists.createPlaylist(name: "E2E \(UUID().uuidString.prefix(4))")
        playlists.addTracks([tone], to: list.id, relativeTo: library.rootURL)
        await until { (try? await session.client!.json(Playlist.self, "GET", "v2/playlists/\(list.id.uuidString)")) != nil }
        let remote = try await session.client!.json(Playlist.self, "GET", "v2/playlists/\(list.id.uuidString)")
        #expect(remote.entries.first?.trackID == tone.id)

        // History: a play posts with the server's track ID, even from a queued copy.
        listening.record(track: tone.withNewID(), startedAt: .now, secondsListened: 30, counted: true)
        let posted = try #require(listening.events.last)
        #expect(posted.trackID == tone.id)
        struct Page: Decodable { let events: [PlayEvent] }
        await until {
            let page = try? await session.client!.json(Page.self, "GET", "v2/history", query: [URLQueryItem(name: "since", value: "0"), URLQueryItem(name: "limit", value: "5000")])
            return page?.events.contains { $0.id == posted.id } == true
        }
        let history = try await session.client!.json(Page.self, "GET", "v2/history", query: [URLQueryItem(name: "since", value: "0"), URLQueryItem(name: "limit", value: "5000")])
        #expect(history.events.contains { $0.id == posted.id })

        // Fetched lyrics for a played (queued) copy go to the real server
        // track with PATCH, and the mirror takes the server's reply at once.
        let hashBefore = session.mirror.tracks[tone.id]?.contentHash
        try await session.writer.writeLyrics(to: tone.withNewID(), lyrics: "[00:01.00] la la")
        #expect(try await session.writer.readLyrics(from: tone.withNewID()) == "[00:01.00] la la")
        await until { session.mirror.tracks[tone.id]?.contentHash != hashBefore }
        #expect(session.mirror.tracks[tone.id]?.contentHash != hashBefore)
        // Once the offline copy has the new bytes, its lyrics read from the
        // file even with the server out of reach.
        await until(30) { session.offline.isCurrent(tone.id) }
        let unreachable = ServerTagEditor(client: ServerClient(address: ServerAddress(host: "127.0.0.1", port: 9),
                                                               pin: Data(repeating: 0, count: 32)),
                                          root: profile.offlineRoot, streamer: session.streamer)
        let offlineWriter = MetadataWriter()
        await offlineWriter.setServer(unreachable)
        #expect(try await offlineWriter.readLyrics(from: tone.withNewID()) == "[00:01.00] la la")

        // Other background writers still can't change tags on the server.
        await #expect(throws: MetadataWriter.WriteError.self) {
            _ = try await session.writer.write(to: tone, title: "Nope", artist: nil, album: nil, year: nil, genre: "Jazz", trackNumber: nil)
        }

        // Disconnect keeps the account: reopening needs no password.
        session.disconnect()
        #expect(!session.isActive)
        #expect(!library.tracks.contains { $0.title == "Tone A" })
        #expect(try ServerTokenStore.token(for: profile.id) != nil)
        session.activate(profile.id)
        await until { session.status == .ready && library.tracks.contains { $0.title == "Tone A" } }
        #expect(session.status == .ready)

        playlists.deletePlaylist(id: list.id)
        await until { (try? await session.client!.json(Playlist.self, "GET", "v2/playlists/\(list.id.uuidString)")) == nil }
        await session.signOut(profile.id)
        #expect(try ServerTokenStore.token(for: profile.id) == nil)
        #expect(!session.isActive)
    }

    @MainActor
    @Test("User data: a new account starts empty; edits, pictures and removals travel between devices; accounts never see each other's")
    func userDataAcrossDevices() async throws {
        try await withTemporaryLibraryData { temp in
            @MainActor func until(_ seconds: Double = 15, _ condition: @MainActor () async -> Bool) async {
                let end = Date().addingTimeInterval(seconds)
                while await !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
            }
            struct Items: Decodable { struct Item: Decodable { let name: String }; let items: [Item] }
            @MainActor func names(_ c: ServerClient) async throws -> Set<String> {
                Set(try await c.json(Items.self, "GET", "v2/userdata").items.map(\.name))
            }
            @MainActor func profile(_ c: ServerClient, _ key: String) async -> ArtistOverride? {
                guard let (data, _) = try? await c.data(for: c.request("GET", "v2/userdata/\(UserDataSync.artistName(key))")) else { return nil }
                return try? JSONDecoder().decode(ArtistOverride.self, from: data)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]

            // The other device, and a clean account.
            let other = try await Live.signIn(0, device: "Other Mac")
            for name in try await names(other.client) { try await other.client.send("DELETE", "v2/userdata/\(name)") }

            // The local library has a profile of its own.
            let artists = ArtistStore(), settings = Settings()
            let scope = LibraryScope(artists: artists, highlight: HomeHighlight(), settings: settings)
            scope.enter(LibraryDataFolder.local)
            artists.upsert(ArtistOverride(canonicalKey: "local only", displayName: "Local"))
            try await Task.sleep(for: .milliseconds(300))

            let session = ServerSession(library: LibraryStore(), playlists: PlaylistStore(),
                                        listening: ListeningStore(librariesDirectory: temp.appendingPathComponent("libraries")),
                                        settings: settings, writer: MetadataWriter())
            session.scope = scope
            let (info, pin) = try await ServerSession.probe(Live.address)
            let (name, password) = Live.users[0]
            try await session.signIn(address: Live.address, info: info, pin: pin, username: name, password: password,
                                     offlineFolder: temp.appendingPathComponent("offline"))
            let account = try #require(session.active)
            await until { session.status == .ready }
            #expect(artists.overrides.isEmpty, "no custom name, picture or banner from the local library")

            // Another device sets a profile with a picture: it arrives here.
            let picture = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                                        samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                                        colorSpaceName: .deviceRGB, bytesPerRow: 24, bitsPerPixel: 24)?
                .representation(using: .png, properties: [:]))
            let theirs = ArtistOverride(canonicalKey: "justice", displayName: "JUSTICE", profileImage: picture)
            _ = try await other.client.data(for: other.client.request("PUT", "v2/userdata/\(UserDataSync.artistName("justice"))",
                                                                      body: try encoder.encode(theirs), contentType: "application/octet-stream"))
            await until { artists.overrides["justice"]?.displayName == "JUSTICE" }
            #expect(artists.overrides["justice"]?.profileImage == picture)

            // An edit here reaches the other device.
            artists.upsert(ArtistOverride(canonicalKey: "justice", displayName: "Justice†", profileImage: picture))
            await until { await profile(other.client, "justice")?.displayName == "Justice†" }
            #expect(await profile(other.client, "justice")?.displayName == "Justice†")

            // A removal there is removed here, and the other way round.
            try await other.client.send("DELETE", "v2/userdata/\(UserDataSync.artistName("justice"))")
            await until { artists.overrides["justice"] == nil }
            #expect(artists.overrides["justice"] == nil)
            artists.upsert(ArtistOverride(canonicalKey: "daft punk", displayName: "Daft Punk"))
            await until { await profile(other.client, "daft punk") != nil }
            artists.remove(key: "daft punk")
            await until { await profile(other.client, "daft punk") == nil }
            #expect(await profile(other.client, "daft punk") == nil)

            // Another account sees none of it.
            artists.upsert(ArtistOverride(canonicalKey: "alice only", displayName: "Mine"))
            await until { await profile(other.client, "alice only") != nil }
            let bob = try await Live.signIn(1)
            #expect(!(try await names(bob.client)).contains(UserDataSync.artistName("alice only")))
            #expect(await Live.status(bob.client, "GET", "v2/userdata/\(UserDataSync.artistName("alice only"))") == 404)

            // Back on this Mac's library, its own profile is there and the account's isn't.
            session.disconnect()
            #expect(artists.overrides["local only"]?.displayName == "Local")
            #expect(artists.overrides["alice only"] == nil)

            for name in try await names(other.client) { try await other.client.send("DELETE", "v2/userdata/\(name)") }
            await session.signOut(account.id)
            try? FileManager.default.removeItem(at: account.supportDirectory)
        }
    }
}
