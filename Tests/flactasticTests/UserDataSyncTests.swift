import AppKit
import CryptoKit
import Foundation
import Testing
@testable import flactastic

// MARK: - The table (§14), row by row

@Test("Each row of the user data table picks the protocol's action")
func userDataTable() {
    let r = UserDataSync.Remembered(etag: "e1", hash: "h1")
    typealias S = UserDataSync
    #expect(S.decide(local: "h2", server: "e1", remembered: r) == .upload, "changed here, same there")
    #expect(S.decide(local: "h1", server: "e2", remembered: r) == .download, "unchanged here, changed there")
    #expect(S.decide(local: "h1", server: nil, remembered: nil) == .upload, "never synced, absent")
    #expect(S.decide(local: "h1", server: nil, remembered: r) == .deleteLocal, "unchanged, deleted elsewhere")
    #expect(S.decide(local: nil, server: "e1", remembered: r) == .deleteRemote, "deleted here, same there")
    #expect(S.decide(local: "h2", server: "e2", remembered: r) == .download, "both changed: the server wins")
    #expect(S.decide(local: "h1", server: "e1", remembered: r) == .none)
    #expect(S.decide(local: nil, server: "e1", remembered: nil) == .download, "new from another device")
    #expect(S.decide(local: nil, server: nil, remembered: r) == .forget)
}

@Test("Artist file names: the first 32 hex of SHA-256 over the artist key")
func artistFileName() {
    let hex = SHA256.hash(data: Data("daft punk".utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(UserDataSync.artistName("daft punk") == "artists/\(hex.prefix(32)).json")
    #expect(UserDataSync.isValidName("mac/spine-logos/1F2E-AB.png"))
    #expect(!UserDataSync.isValidName("mac/.hidden"))
    #expect(!UserDataSync.isValidName("mac/a b.png"))
    #expect(!UserDataSync.isValidName("mac//x"))
    #expect(!UserDataSync.isValidName(String(repeating: "a", count: 201)))
}

// MARK: - A fake server

/// `/v2/userdata` in memory, plus just enough of the rest for a session.
final class FakeUserDataServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var items: [String: Data] = [:]
    nonisolated(unsafe) static var offline = false
    nonisolated(unsafe) static var unsupported = false
    static let lock = NSLock()

    static func reset() { lock.withLock { items = [:]; offline = false; unsupported = false } }
    static func etag(_ d: Data) -> String { SHA256.hash(data: d).prefix(16).map { String(format: "%02x", $0) }.joined() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET", path = request.url!.path
        if Self.lock.withLock({ Self.offline }) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let user = #"{"id":"9F1C2B3A-4D5E-4F60-8A7B-0C1D2E3F4A5B","name":"alice","isAdmin":false}"#
        let device = #"{"id":"0A1C2B3A-4D5E-4F60-8A7B-0C1D2E3F4A5B","name":"t","kind":"mac","created":"2026-01-01T00:00:00.000Z","lastSeen":"2026-01-01T00:00:00.000Z","current":true}"#
        switch (method, path) {
        case ("POST", "/v2/auth/login"): reply(200, #"{"token":"t","user":\#(user),"device":\#(device)}"#)
        case ("GET", "/v2/me"): reply(200, #"{"user":\#(user),"device":\#(device)}"#)
        case ("GET", "/v2/server"):
            reply(200, #"{"id":"1A1C2B3A-4D5E-4F60-8A7B-0C1D2E3F4A5B","name":"fake","protocol":"2.0","version":"beta-2","transcoding":false}"#)
        case ("GET", "/v2/changes"):
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { self.reply(200, #"{"seq":0,"changed":[]}"#) }
        case ("GET", "/v2/tracks"): reply(200, #"{"tracks":[],"deleted":[],"seq":0,"more":false}"#)
        case ("GET", "/v2/prefs"): reply(200, "{}")
        case ("GET", "/v2/playlists"): reply(200, #"{"playlists":[]}"#)
        case ("GET", "/v2/history"): reply(200, #"{"events":[],"contexts":[],"seq":0,"more":false}"#)
        case ("GET", "/v2/userdata"):
            if Self.lock.withLock({ Self.unsupported }) { return notFound() }
            let list = Self.lock.withLock { Self.items.map { #"{"name":"\#($0.key)","size":\#($0.value.count),"etag":"\#(Self.etag($0.value))"}"# } }
            reply(200, #"{"items":[\#(list.joined(separator: ","))]}"#)
        case (_, let p) where p.hasPrefix("/v2/userdata/"):
            let name = String(p.dropFirst("/v2/userdata/".count))
            switch method {
            case "GET":
                guard let data = Self.lock.withLock({ Self.items[name] }) else { return notFound() }
                reply(200, data, ["ETag": "\"\(Self.etag(data))\""])
            case "PUT":
                let body = Self.body(of: request)
                guard body.count <= 8 << 20 else { return reply(413, #"{"error":{"code":"sizeExceeded","message":""}}"#) }
                Self.lock.withLock { Self.items[name] = body }
                reply(204, Data(), ["ETag": "\"\(Self.etag(body))\""])
            default:
                Self.lock.withLock { Self.items[name] = nil }
                reply(204, Data())
            }
        default: notFound()
        }
    }

    private func notFound() { reply(404, #"{"error":{"code":"notFound","message":""}}"#) }
    private func reply(_ status: Int, _ body: String) { reply(status, Data(body.utf8)) }
    private func reply(_ status: Int, _ body: Data, _ headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
}

/// A signed-in session against the fake server, in temporary folders.
@MainActor
private func withFakeAccount(_ body: (ServerSession, ArtistStore, Settings) async throws -> Void) async throws {
    try await withTemporaryLibraryData { temp in
        FakeUserDataServer.reset()
        ServerClient.testProtocolClasses = [FakeUserDataServer.self]
        defer { ServerClient.testProtocolClasses = [] }
        let artists = ArtistStore(), settings = Settings()
        let session = ServerSession(library: LibraryStore(), playlists: PlaylistStore(),
                                    listening: ListeningStore(librariesDirectory: temp.appendingPathComponent("libraries")),
                                    settings: settings, writer: MetadataWriter())
        session.scope = LibraryScope(artists: artists, highlight: HomeHighlight(), settings: settings)
        let info = ServerInfo(id: UUID(), name: "fake", protocol: "2.0", version: "beta-2", transcoding: false)
        try await session.signIn(address: ServerAddress(host: "fake.invalid"), info: info, pin: Data(count: 32),
                                 username: "alice", password: "password", offlineFolder: temp.appendingPathComponent("offline"))
        let profile = try #require(session.active)
        try await body(session, artists, settings)
        await session.signOut(profile.id)
        try? FileManager.default.removeItem(at: profile.supportDirectory)
    }
}

private func serverProfile(_ key: String) -> ArtistOverride? {
    FakeUserDataServer.lock.withLock { FakeUserDataServer.items[UserDataSync.artistName(key)] }
        .flatMap { try? JSONDecoder().decode(ArtistOverride.self, from: $0) }
}

private func putServerProfile(_ o: ArtistOverride) {
    let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
    FakeUserDataServer.lock.withLock { FakeUserDataServer.items[UserDataSync.artistName(o.canonicalKey)] = try! e.encode(o) }
}

/// Tests that share global state (the fake server, the library data folder,
/// defaults) run one at a time.
@Suite(.serialized)
@MainActor
struct AccountDataTests {
    @Test("With a fake server: uploads, downloads and deletions follow the table, mac/ files too")
    func userDataSyncRows() async throws {
        try await withFakeAccount { session, artists, settings in
            let sync = session.userData

            // Never synced, absent: upload.
            artists.upsert(ArtistOverride(canonicalKey: "a", displayName: "A"))
            await sync.sync()
            #expect(serverProfile("a")?.displayName == "A")

            // Changed here, same there: upload.
            artists.upsert(ArtistOverride(canonicalKey: "a", displayName: "A2"))
            await sync.sync()
            #expect(serverProfile("a")?.displayName == "A2")

            // Unchanged here, changed there: download.
            putServerProfile(ArtistOverride(canonicalKey: "a", displayName: "From another Mac"))
            await sync.sync()
            #expect(artists.overrides["a"]?.displayName == "From another Mac")

            // Unchanged here, deleted there: removed here.
            FakeUserDataServer.lock.withLock { FakeUserDataServer.items[UserDataSync.artistName("a")] = nil }
            await sync.sync()
            #expect(artists.overrides["a"] == nil)

            // Deleted here, same there: DELETE.
            artists.upsert(ArtistOverride(canonicalKey: "b", displayName: "B"))
            await sync.sync()
            artists.remove(key: "b")
            await sync.sync()
            #expect(serverProfile("b") == nil)

            // Both changed: the server copy wins.
            artists.upsert(ArtistOverride(canonicalKey: "c", displayName: "C"))
            await sync.sync()
            artists.upsert(ArtistOverride(canonicalKey: "c", displayName: "Mine"))
            putServerProfile(ArtistOverride(canonicalKey: "c", displayName: "Theirs"))
            await sync.sync()
            #expect(artists.overrides["c"]?.displayName == "Theirs")
            #expect(serverProfile("c")?.displayName == "Theirs")

            // A mac/ file both ways.
            settings.customGenres = ["Shoegaze"]
            await sync.sync()
            #expect(FakeUserDataServer.lock.withLock { FakeUserDataServer.items["mac/genres.json"] } != nil)
            let doc = try JSONEncoder().encode(["flactastic.customGenres": JSONValue.array([.string("Dream Pop")])])
            FakeUserDataServer.lock.withLock { FakeUserDataServer.items["mac/genres.json"] = doc }
            await sync.sync()
            #expect(settings.customGenres == ["Dream Pop"])
        }
    }

    @Test("A pinned lyric follows the account to another Mac; other Home settings changing there don't re-roll it")
    func pinFollowsTheAccount() async throws {
        try await withFakeAccount { session, _, _ in
            let sync = session.userData
            sync.detach() // only this test's syncs: a background one would count too
            let highlight = try #require(session.scope?.highlight)
            let pinURL = LibraryDataFolder.url.appendingPathComponent("pinned_highlight.json")
            func pin(_ lyric: String) throws -> Data {
                try JSONEncoder().encode(HomeHighlight.Pick(lyric: lyric, songTitle: "Song", artistDisplay: "Artist", imageData: nil))
            }
            func serverPin() -> String? {
                FakeUserDataServer.lock.withLock { FakeUserDataServer.items["mac/home.json"] }
                    .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) }
                    .flatMap { if case .object(let o)? = $0["pinned"], case .string(let b)? = o["$data"] { return Data(base64Encoded: b) }; return nil }
                    .flatMap { try? JSONDecoder().decode(HomeHighlight.Pick.self, from: $0).lyric }
            }
            func putServerHome(pin lyric: String?, order: [String]) throws {
                var doc: [String: JSONValue] = ["flactastic.home.sectionOrder": .array(order.map { .string($0) })]
                if let lyric { doc["pinned"] = .object(["$data": .string(try pin(lyric).base64EncodedString())]) }
                let data = try JSONEncoder().encode(doc)
                FakeUserDataServer.lock.withLock { FakeUserDataServer.items["mac/home.json"] = data }
            }

            // Pinned here: uploaded.
            try pin("Pinned here").write(to: pinURL)
            await sync.sync()
            #expect(serverPin() == "Pinned here")

            // Pinned on another Mac: here too, and Home picks again.
            var resets = highlight.resets
            try putServerHome(pin: "Pinned there", order: ["a"])
            await sync.sync()
            #expect(try JSONDecoder().decode(HomeHighlight.Pick.self, from: Data(contentsOf: pinURL)).lyric == "Pinned there")
            #expect(highlight.resets == resets + 1)

            // Only the section order changed there: the lyric stays.
            resets = highlight.resets
            try putServerHome(pin: "Pinned there", order: ["b"])
            await sync.sync()
            #expect(highlight.resets == resets)

            // Unpinned there: unpinned here.
            try putServerHome(pin: nil, order: ["b"])
            await sync.sync()
            #expect(!FileManager.default.fileExists(atPath: pinURL.path))
            #expect(highlight.resets == resets + 1)
        }
    }

    @Test("Losing the server says so at once, retries on its own, and Try Now reconnects straight away")
    func reconnects() async throws {
        try await withFakeAccount { session, _, _ in
            @MainActor func until(_ seconds: Double, _ done: () -> Bool) async {
                let end = Date().addingTimeInterval(seconds)
                while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
            }
            // Any request that can't get through marks the server unreachable.
            FakeUserDataServer.lock.withLock { FakeUserDataServer.offline = true }
            _ = try? await session.client!.json(ServerInfo.self, "GET", "v2/server")
            await until(2) { session.status == .unreachable }
            #expect(session.status == .unreachable)

            // Back: the first retry (after 2 s) finds it.
            FakeUserDataServer.lock.withLock { FakeUserDataServer.offline = false }
            await until(5) { session.status == .ready }
            #expect(session.status == .ready)

            // Down again for a while: Try Now doesn't wait out the back-off.
            FakeUserDataServer.lock.withLock { FakeUserDataServer.offline = true }
            session.connectionLost()
            try await Task.sleep(for: .seconds(4.5)) // retries at 2 s and 6 s
            FakeUserDataServer.lock.withLock { FakeUserDataServer.offline = false }
            let tapped = Date()
            session.reconnectNow()
            await until(3) { session.status == .ready }
            #expect(session.status == .ready)
            #expect(Date().timeIntervalSince(tapped) < 1, "no waiting for the next scheduled retry")
        }
    }

    /// A noisy image that compresses badly: big as PNG.
    nonisolated private func noisePNG(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: width * 3, bitsPerPixel: 24)!
        var rng = SystemRandomNumberGenerator()
        let p = rep.bitmapData!
        for i in 0..<(width * height * 3) { p[i] = UInt8.random(in: 0...255, using: &rng) }
        return rep.representation(using: .png, properties: [:])!
    }

    @Test("An oversized banner is scaled to fit and uploads; an offline edit uploads once the server is back")
    func userDataScalingAndOffline() async throws {
        try await withFakeAccount { session, artists, _ in
            // Made off the main actor: it takes a while, and other tests need it.
        let banner = await Task.detached { noisePNG(width: 4000, height: 2500) }.value
            #expect(banner.count > 8 << 20, "the banner alone is over the limit")
            artists.upsert(ArtistOverride(canonicalKey: "big", displayName: "Big", bannerImage: banner))
            await session.userData.sync()
            let stored = try #require(FakeUserDataServer.lock.withLock { FakeUserDataServer.items[UserDataSync.artistName("big")] })
            #expect(stored.count < 8 << 20)
            let bannerData = try #require(serverProfile("big")?.bannerImage)
            let image = try #require(NSBitmapImageRep(data: bannerData))
            #expect(max(image.pixelsWide, image.pixelsHigh) == 2560)

            FakeUserDataServer.lock.withLock { FakeUserDataServer.offline = true }
            artists.upsert(ArtistOverride(canonicalKey: "later", displayName: "Edited offline"))
            await session.userData.sync()
            #expect(serverProfile("later") == nil)
            #expect(artists.overrides["later"] != nil, "kept here meanwhile")
            FakeUserDataServer.lock.withLock { FakeUserDataServer.offline = false }
            await session.userData.sync()
            #expect(serverProfile("later")?.displayName == "Edited offline")
        }
    }

    @Test("A server without user data (404) leaves the app working, the data kept here")
    func userDataUnsupported() async throws {
        try await withFakeAccount { session, artists, _ in
            FakeUserDataServer.lock.withLock { FakeUserDataServer.unsupported = true }
            let fresh = UserDataSync(session: session)
            artists.upsert(ArtistOverride(canonicalKey: "kept", displayName: "Kept"))
            await fresh.sync()
            #expect(!fresh.isSupported)
            #expect(artists.overrides["kept"]?.displayName == "Kept")
        }
    }

    @Test("A new server account shows nothing from the local library, and the local library keeps all of its own")
    func newAccountStartsEmpty() async throws {
        try await withTemporaryLibraryData { _ in
            let artists = ArtistStore(), settings = Settings()
            let scope = LibraryScope(artists: artists, highlight: HomeHighlight(), settings: settings)
            scope.enter(LibraryDataFolder.local)

            artists.upsert(ArtistOverride(canonicalKey: "daft punk", displayName: "DAFT PUNK",
                                          bannerImage: Data([1, 2, 3]), profileImage: Data([4, 5, 6])))
            settings.customGenres = ["Shoegaze"]
            settings.theme = .dark
            try await Task.sleep(for: .milliseconds(300)) // the store's save is queued

            let account = LibraryDataFolder.server(UUID(), user: UUID().uuidString)
            scope.enter(account)
            #expect(artists.overrides.isEmpty, "no custom name, picture or banner")
            #expect(settings.customGenres.isEmpty)
            #expect(settings.theme == .dark, "the look doesn't jump on sign-in")

            artists.upsert(ArtistOverride(canonicalKey: "justice", displayName: "†"))
            settings.customGenres = ["French House"]
            try await Task.sleep(for: .milliseconds(300))

            scope.enter(LibraryDataFolder.local)
            #expect(artists.overrides.keys.sorted() == ["daft punk"])
            #expect(artists.overrides["daft punk"]?.profileImage == Data([4, 5, 6]))
            #expect(settings.customGenres == ["Shoegaze"])

            scope.enter(account)
            #expect(artists.overrides.keys.sorted() == ["justice"], "the account keeps its own too")
            #expect(settings.customGenres == ["French House"])

            // Quitting with the account open: next launch enters it again, and the
            // local library's values are still waiting.
            let relaunched = LibraryScope(artists: ArtistStore(), highlight: HomeHighlight(), settings: Settings())
            relaunched.enter(account)
            #expect(Settings().customGenres == ["French House"])
            relaunched.enter(LibraryDataFolder.local)
            #expect(Settings().customGenres == ["Shoegaze"])
        }
    }

}
