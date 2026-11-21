import AppKit
import CryptoKit
import Foundation
import Network
import Observation

/// A signed-in server account. The token lives in the Keychain under `id`;
/// everything here is safe in preferences.
struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var serverID: UUID
    var serverName: String
    var address: ServerAddress
    /// SHA-256 of the server's SubjectPublicKeyInfo, confirmed by the user.
    var pin: Data
    var username: String
    var deviceID: UUID?
    /// The account's user ID: its customisation lives under
    /// `servers/<server id>/<user id>/`. Nil for profiles made before that.
    var userID: UUID?
    /// Where offline copies live, laid out by the server's relative paths.
    var offlineFolder: String
    /// Files that appear in the offline folder after this are uploaded.
    var created = Date()

    var offlineRoot: URL { URL(fileURLWithPath: offlineFolder, isDirectory: true) }
    var label: String { "\(serverName) · \(username)" }

    /// The app's own files for this profile: the track mirror, cursors,
    /// artwork and the stream cache.
    var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FLACtastic/Servers/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// The active server profile: sign-in, the track mirror, the change signal,
/// and handing what the server says to the app's existing stores.
@Observable
@MainActor
final class ServerSession {
    enum Status: Equatable {
        case idle, connecting, ready
        case unreachable
        /// The token was revoked or the password changed elsewhere.
        case signedOut
        /// The key no longer matches the pin. Never re-prompted (§3).
        case identityChanged
    }

    private(set) var profiles: [ServerProfile] = []
    private(set) var activeID: UUID?
    private(set) var status: Status = .idle
    private(set) var library: LibraryInfo?
    private(set) var serverInfo: ServerInfo?
    /// Bumped when the server reports Organizer changes.
    private(set) var organizerRevision = 0

    @ObservationIgnored private(set) var client: ServerClient?
    @ObservationIgnored let libraryStore: LibraryStore
    @ObservationIgnored let playlists: PlaylistStore
    @ObservationIgnored let listening: ListeningStore
    @ObservationIgnored let settings: Settings
    @ObservationIgnored let writer: MetadataWriter
    @ObservationIgnored var mirror = ServerMirror()
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Holds tag edits made on offline copies until the server takes them.
    @ObservationIgnored private var tagEditor: ServerTagEditor?
    @ObservationIgnored private var retryRound = 0
    @ObservationIgnored private let path = NWPathMonitor()
    @ObservationIgnored private var pathWasUp = true
    @ObservationIgnored private var pathInterfaces: Set<String>?
    @ObservationIgnored lazy var artwork = ServerArtwork(session: self)
    @ObservationIgnored lazy var offline = OfflineCopies(session: self)
    @ObservationIgnored lazy var uploads = ServerUploads(session: self)
    @ObservationIgnored lazy var history = HistorySync(session: self)
    @ObservationIgnored lazy var playlistSync = PlaylistSync(session: self)
    @ObservationIgnored lazy var prefs = PrefsSync(session: self)
    @ObservationIgnored lazy var userData = UserDataSync(session: self)
    /// Opens server tracks for the player; shared with its decode task.
    @ObservationIgnored let streamer = ServerStreamer()
    /// Each track's server ID by its standardized file path.
    @ObservationIgnored private var idByPath: [String: UUID] = [:]
    @ObservationIgnored private var isPullingTracks = false
    /// Files in the offline folder the server doesn't have (yet), by
    /// standardized path: downloads and imports waiting to upload, or ones
    /// kept off the server. They show in the library with its tracks.
    private(set) var localOnly: [String: Track] = [:]
    @ObservationIgnored private var localScan: Task<Void, Never>?
    @ObservationIgnored private var localScanAgain = false
    @ObservationIgnored private let scanner = LibraryScanner()

    init(library: LibraryStore, playlists: PlaylistStore, listening: ListeningStore, settings: Settings, writer: MetadataWriter) {
        libraryStore = library
        self.playlists = playlists
        self.listening = listening
        self.settings = settings
        self.writer = writer
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let stored = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = stored
        }
        activeID = UserDefaults.standard.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
        if active == nil { activeID = nil }
        Self.current = self
    }

    /// The app's one session, for menus built outside the view tree.
    static weak var current: ServerSession?

    private static let profilesKey = "flactastic.serverProfiles"
    private static let activeKey = "flactastic.activeServerProfile"

    var active: ServerProfile? { profiles.first { $0.id == activeID } }
    var isActive: Bool { activeID != nil }

    private func persistProfiles() {
        UserDefaults.standard.set(try? JSONEncoder().encode(profiles), forKey: Self.profilesKey)
        UserDefaults.standard.set(activeID?.uuidString, forKey: Self.activeKey)
    }

    // MARK: - First connection and sign-in (§3, §6)

    /// Connects without a pin, reads the server's identity and the pin it
    /// presented. Nothing secret is sent.
    nonisolated static func probe(_ address: ServerAddress) async throws -> (ServerInfo, Data) {
        let client = ServerClient(address: address, pin: nil)
        let info = try await client.json(ServerInfo.self, "GET", "v2/server", timeout: 20)
        guard let pin = client.trust.seenPin else { throw ServerError.badResponse }
        return (info, pin)
    }

    /// Signs in through a client pinned to the confirmed key, stores the
    /// token in the Keychain, and makes the new profile active.
    func signIn(address: ServerAddress, info: ServerInfo, pin: Data, username: String,
                password: String, offlineFolder: URL) async throws {
        let client = ServerClient(address: address, pin: pin)
        struct Login: Encodable { let username, password, deviceName, deviceKind: String }
        let name = Host.current().localizedName ?? "Mac"
        let response = try await client.json(LoginResponse.self, "POST", "v2/auth/login", body: Login(
            username: username.trimmingCharacters(in: .whitespaces).lowercased(),
            password: password,
            deviceName: Self.clamp(name, bytes: 63),
            deviceKind: "mac"
        ))
        let profile = ServerProfile(
            id: UUID(), serverID: info.id, serverName: TXTRecordCodec.sanitizeDisplayName(info.name, fallback: "FLACtastic Server"),
            address: address, pin: pin, username: response.user.name, deviceID: response.device.id,
            userID: response.user.id,
            offlineFolder: offlineFolder.path
        )
        try ServerTokenStore.store(response.token, for: profile.id)
        try? FileManager.default.createDirectory(at: offlineFolder, withIntermediateDirectories: true)
        profiles.append(profile)
        persistProfiles()
        activate(profile.id)
    }

    /// Signs in again after `signedOut`, keeping the profile, pin and copies.
    func reauthenticate(password: String) async throws {
        guard var profile = active else { return }
        let client = ServerClient(address: profile.address, pin: profile.pin)
        struct Login: Encodable { let username, password, deviceName, deviceKind: String }
        let response = try await client.json(LoginResponse.self, "POST", "v2/auth/login", body: Login(
            username: profile.username, password: password,
            deviceName: Self.clamp(Host.current().localizedName ?? "Mac", bytes: 63), deviceKind: "mac"))
        try ServerTokenStore.store(response.token, for: profile.id)
        profile.deviceID = response.device.id
        profile.userID = response.user.id
        replace(profile)
        activate(profile.id)
    }

    nonisolated static func clamp(_ s: String, bytes: Int) -> String {
        var s = s
        while s.utf8.count > bytes { s.removeLast() }
        return s
    }

    // MARK: - Switching

    /// Makes a server profile the library. Shows the mirrored library
    /// straight away, then catches up with the server.
    func activate(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        stopChanges()
        activeID = id
        persistProfiles()
        status = .connecting
        library = nil
        serverInfo = nil

        let token: String?
        do { token = try ServerTokenStore.token(for: id) } catch { token = nil }
        let client = ServerClient(address: profile.address, pin: profile.pin, token: token)
        client.onUnreachable = { [weak self] in Task { @MainActor in self?.connectionLost() } }
        self.client = client
        let editor = ServerTagEditor(
            client: client, root: profile.offlineRoot, streamer: streamer,
            stagingFile: profile.supportDirectory.appendingPathComponent("staged-edits.json"),
            onApplied: { [weak self] tracks in Task { @MainActor in self?.applyServerTracks(tracks) } },
            // The copy here already has the refused edit: fetch the server's.
            onRejected: { [weak self] id in Task { @MainActor in self?.offline.redownload(id) } })
        tagEditor = editor
        Task { [writer] in await writer.setServer(editor) }
        scope?.enter(dataFolder(profile))
        userData.attach()
        if profile.userID == nil { Task { await learnUserID() } }
        mirror = ServerMirror.load(from: profile.supportDirectory)
        offline.load()
        libraryStore.remoteRemove = { [weak self] tracks in Task { await self?.deleteTracks(tracks) } }
        libraryStore.remoteRefresh = { [weak self] in
            self?.uploads.scanForNewFiles()
            self?.refreshLocalFiles()
            Task { await self?.pullTracks() }
        }
        rebuildIndex()
        streamerSettingsChanged()
        libraryStore.openServer(root: profile.offlineRoot, tracks: appTracks(mirror.tracks.values))
        localOnly = [:]
        refreshLocalFiles()
        playlists.load(from: profile.offlineRoot)
        playlistSync.attach()
        Task {
            await listening.loadAsync(from: profile.offlineRoot)
            history.attach()
        }
        artwork.fillMissing()
        guard token != nil else { status = .signedOut; return }
        uploads.load()
        uploads.scanForNewFiles()
        startChanges()
        watchForeground()
    }

    /// Closes the server library and opens this Mac's folder (or nothing).
    /// The account stays signed in: opening it again needs no password, and
    /// at launch the app reopens whichever library was open last.
    func disconnect() {
        guard isActive else { return }
        deactivate()
        guard let path = settings.lastRootPath else {
            libraryStore.close()
            playlists.playlists = []
            return
        }
        let url = URL(fileURLWithPath: path)
        libraryStore.openFolder(url)
        playlists.load(from: url)
        listening.load(from: url)
    }

    /// Stops using the server library. Callers open the next library.
    func deactivate() {
        // Stop the player while the server's history hooks can still post
        // the play in progress.
        if isActive { libraryStore.onLibraryChange?() }
        stopChanges()
        retryTask?.cancel()
        retryTask = nil
        offline.cancel()
        history.detach()
        playlistSync.detach()
        prefs.detach()
        streamer.config.withLock { $0 = ServerStreamer.Config() }
        tagEditor = nil
        idByPath = [:]
        localScan?.cancel()
        localScan = nil
        localOnly = [:]
        Task { [writer] in await writer.setServer(nil) }
        userData.detach()
        scope?.enter(LibraryDataFolder.local)
        activeID = nil
        client = nil
        status = .idle
        library = nil
        libraryStore.remoteRefresh = nil
        libraryStore.remoteRemove = nil
        persistProfiles()
    }

    /// Keeps each library's customisation apart (set at launch).
    @ObservationIgnored var scope: LibraryScope?

    func dataFolder(_ profile: ServerProfile) -> URL {
        LibraryDataFolder.server(profile.serverID, user: profile.userID?.uuidString ?? "profile-\(profile.id.uuidString)")
    }

    /// A profile from before user IDs were kept: ask the server once.
    private func learnUserID() async {
        struct Me: Decodable { let user: ServerUser }
        guard var profile = active, let me = try? await call({ try await $0.json(Me.self, "GET", "v2/me") }),
              activeID == profile.id else { return }
        profile.userID = me.user.id
        replace(profile)
        scope?.enter(dataFolder(profile))
        userData.attach()
        await userData.sync()
    }

    func replace(_ profile: ServerProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        persistProfiles()
    }

    /// Revokes this Mac's token and forgets the profile. Offline copies stay
    /// on disk; they are the user's files.
    func signOut(_ id: UUID) async {
        if let profile = profiles.first(where: { $0.id == id }), let token = try? ServerTokenStore.token(for: id) {
            let c = ServerClient(address: profile.address, pin: profile.pin, token: token)
            try? await c.send("POST", "v2/auth/logout")
        }
        try? ServerTokenStore.delete(id)
        if activeID == id { disconnect() }
        profiles.removeAll { $0.id == id }
        persistProfiles()
    }

    /// For a profile whose key changed: the only way out is to remove it.
    func forget(_ id: UUID) {
        try? ServerTokenStore.delete(id)
        if activeID == id { disconnect() }
        profiles.removeAll { $0.id == id }
        persistProfiles()
    }

    // MARK: - Account (§6)

    func devices() async throws -> [ServerDevice] {
        struct Devices: Decodable { let devices: [ServerDevice] }
        return try await call { try await $0.json(Devices.self, "GET", "v2/devices").devices }
    }

    func revoke(_ device: ServerDevice) async throws {
        try await call { try await $0.send("DELETE", "v2/devices/\(device.id.uuidString)") }
    }

    /// Signs out every other device of this user (§6).
    func changePassword(current: String, new: String) async throws {
        struct Change: Encodable { let current: String; let new: String }
        try await call { try await $0.send("PUT", "v2/me/password", body: Change(current: current, new: new)) }
    }

    /// Runs a request and reacts to what it says about the session itself.
    func call<T>(_ body: (ServerClient) async throws -> T) async throws -> T {
        guard let client else { throw ServerError.unreachable("No server") }
        do {
            let result = try await body(client)
            if status == .unreachable || status == .connecting { status = .ready }
            return result
        } catch let error as ServerError {
            note(error)
            throw error
        }
    }

    func note(_ error: ServerError) {
        switch error {
        case .identityChanged:
            status = .identityChanged
            stopChanges()
        case .api(code: "unauthorized", _, _):
            if let id = activeID { try? ServerTokenStore.delete(id) }
            client?.token = nil
            status = .signedOut
            stopChanges()
        case .unreachable:
            connectionLost()
        default:
            break
        }
    }

    // MARK: - Library mirror (§7)

    func appTracks<S: Sequence>(_ tracks: S) -> [Track] where S.Element == ServerTrack {
        guard let root = active?.offlineRoot else { return [] }
        return tracks.compactMap { server -> Track? in
            guard var t = server.appTrack(root: root) else { return nil }
            t.artwork = server.artworkID.flatMap { artwork.thumbnail(for: $0) }
            return t
        }
    }

    /// Fetches every track created, changed or deleted since the mirror's
    /// `seq`, page by page, and applies it to the library.
    /// Deletes tracks on the server (§10: into its trash for 30 days), and
    /// this Mac's copies with them (into the Trash). A track the server
    /// didn't delete comes back with the pull that follows.
    func deleteTracks(_ tracks: [Track]) async {
        for track in tracks {
            // Only on this Mac: there's nothing on the server to delete.
            if isLocalOnly(track) {
                try? FileManager.default.trashItem(at: track.url, resultingItemURL: nil)
                uploads.forget(track.url)
                continue
            }
            let id = serverID(for: track) ?? track.id
            guard (try? await call({ try await $0.send("DELETE", "v2/tracks/\(id.uuidString)") })) != nil else { continue }
            offline.trash(id)
        }
        await pullTracks()
    }

    func pullTracks() async {
        guard let profile = active, !isPullingTracks else { return }
        isPullingTracks = true
        defer { isPullingTracks = false }
        var changed: [ServerTrack] = []
        var deleted = Set<UUID>()
        do {
            var more = true
            while more {
                let page = try await call {
                    try await $0.json(TracksPage.self, "GET", "v2/tracks", query: [
                        URLQueryItem(name: "since", value: String(mirror.seq)),
                        URLQueryItem(name: "limit", value: "5000"),
                    ])
                }
                guard activeID == profile.id else { return }
                for t in page.tracks { mirror.tracks[t.id] = t; changed.append(t); deleted.remove(t.id) }
                for id in page.deleted { mirror.tracks.removeValue(forKey: id); deleted.insert(id) }
                mirror.seq = page.seq
                more = page.more
            }
        } catch {
            return
        }
        guard !changed.isEmpty || !deleted.isEmpty else { return }
        mirror.save(to: profile.supportDirectory)
        rebuildIndex()
        libraryStore.applyRemote(updated: appTracks(changed), deleted: deleted)
        artwork.fillMissing()
        offline.libraryChanged()
        refreshLocalFiles()
    }

    /// The path → ID index and the streamer's per-track facts, from the mirror.
    private func rebuildIndex() {
        guard let root = active?.offlineRoot else { return }
        var ids: [String: UUID] = [:]
        var infos: [String: ServerStreamer.TrackInfo] = [:]
        for t in mirror.tracks.values {
            guard let format = AudioFileFormat(rawValue: t.format),
                  let path = try? PathSanitizer.sanitizeAudioRelativePath(t.relativePath) else { continue }
            let key = root.appendingPathComponent(path).standardizedFileURL.path
            ids[key] = t.id
            infos[key] = ServerStreamer.TrackInfo(id: t.id, format: format, fileSize: t.fileSize, contentHash: t.contentHash,
                                                  sampleRate: Double(t.sampleRate ?? 44_100), bitrate: t.bitrate ?? 0,
                                                  frames: t.frames, duration: t.duration)
        }
        idByPath = ids
        let snapshot = infos
        streamer.config.withLock { $0.tracks = snapshot }
        listening.refilter() // plays of tracks that just arrived count now
    }

    func serverID(for track: Track) -> UUID? { idByPath[track.url.standardizedFileURL.path] }

    /// Server track IDs by standardized file path.
    var trackIDsByPath: [String: UUID] { idByPath }

    func streamerSettingsChanged() {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FLACtastic/Stream/\(activeID?.uuidString ?? "none")", isDirectory: true)
        let (client, quality, transcoding) = (self.client, prefs.streamQuality, serverInfo?.transcoding ?? true)
        streamer.config.withLock {
            $0.client = client
            $0.quality = quality
            $0.transcoding = transcoding
            $0.cacheDirectory = cache
        }
    }

    // MARK: - On this Mac

    /// Whether a library track's bytes are on this Mac, and why.
    enum OnThisMac { case copy, notOnServer }

    func onThisMac(_ track: Track) -> OnThisMac? {
        let path = track.url.standardizedFileURL.path
        if localOnly[path] != nil { return .notOnServer }
        guard let id = idByPath[path] else { return nil }
        return offline.isCurrent(id) ? .copy : nil
    }

    func isLocalOnly(_ track: Track) -> Bool { localOnly[track.url.standardizedFileURL.path] != nil }

    /// Finds audio files in the offline folder the server doesn't have, reads
    /// the new ones' tags, and puts them in the library beside its tracks.
    func refreshLocalFiles() {
        guard let profile = active else { return }
        guard localScan == nil else { localScanAgain = true; return }
        localScan = Task { [weak self] in
            repeat {
                guard let self else { return }
                self.localScanAgain = false
                await self.scanLocalFiles(profile)
            } while self?.localScanAgain == true && !Task.isCancelled
            self?.localScan = nil
        }
    }

    private func scanLocalFiles(_ profile: ServerProfile) async {
        let root = profile.offlineRoot
        let known = Set(idByPath.keys).union(offline.installedPaths.map {
            root.appendingPathComponent($0).standardizedFileURL.path
        })
        let found = await Task.detached(priority: .utility) { Self.localFiles(in: root, excluding: known) }.value
        guard !Task.isCancelled, activeID == profile.id else { return }
        var next: [String: Track] = [:]
        var fresh: [Track] = []
        for stub in found {
            let key = stub.url.standardizedFileURL.path
            if let had = localOnly[key] { next[key] = had } else { fresh.append(stub) }
        }
        if !fresh.isEmpty {
            let loaded = await withTaskGroup(of: Track.self) { group in
                for t in fresh { group.addTask { [scanner] in await scanner.loadMetadata(for: t) } }
                var out: [Track] = []
                for await t in group { out.append(t) }
                return out
            }
            for t in loaded { next[t.url.standardizedFileURL.path] = t }
        }
        guard !Task.isCancelled, activeID == profile.id else { return }
        // Something may have reached the server while tags were read.
        next = next.filter { idByPath[$0.key] == nil }
        guard Set(next.keys) != Set(localOnly.keys) || !fresh.isEmpty else { return }
        localOnly = next
        libraryStore.setLocalExtras(Array(next.values))
    }

    /// Audio files under `root` that aren't at any of the `excluding` paths.
    /// Each gets an ID from its path, so it stays the same across launches.
    nonisolated static func localFiles(in root: URL, excluding known: Set<String>) -> [Track] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .addedToDirectoryDateKey, .creationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var out: [Track] = []
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard !known.contains(path), AudioFileFormat.classify(url) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let stub = Track.makeFromURL(url) else { continue }
            let rel = String(path.dropFirst(rootPath.count + 1))
            var track = stub.rebuilt(id: localID(rel))
            track.dateAdded = values.addedToDirectoryDate ?? values.creationDate
            out.append(track)
        }
        return out
    }

    nonisolated static func localID(_ relativePath: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("local:\(relativePath)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // a name-based UUID
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Organizer (§12)

    struct OrganizerState: Codable {
        var profiles: [OrganizerProfile]
        var selectedID: UUID?
    }

    struct PlanOperation: Decodable {
        let trackID: UUID
        let from: String
        let to: String
        let status: String
    }

    struct OrganizerPlan: Decodable {
        let planHash: String
        let operations: [PlanOperation]
    }

    func organizer() async throws -> OrganizerState {
        try await call { try await $0.json(OrganizerState.self, "GET", "v2/organizer") }
    }

    func putOrganizer(_ state: OrganizerState) async throws {
        try await call { try await $0.send("PUT", "v2/organizer", body: state) }
    }

    func organizerPlan(profileID: UUID) async throws -> OrganizerPlan {
        struct Body: Encodable { let profileID: UUID }
        return try await call { try await $0.json(OrganizerPlan.self, "POST", "v2/organizer/plan", body: Body(profileID: profileID)) }
    }

    /// Applies a previewed plan; `409 planStale` means the library changed.
    func organizerApply(profileID: UUID, planHash: String) async throws -> (moved: Int, unchanged: Int) {
        struct Body: Encodable { let profileID: UUID; let planHash: String }
        struct Result: Decodable { let moved: Int; let unchanged: Int }
        let r = try await call {
            try await $0.json(Result.self, "POST", "v2/organizer/apply", body: Body(profileID: profileID, planHash: planHash), timeout: 600)
        }
        return (r.moved, r.unchanged)
    }

    /// Tracks the server returned from an edit (an editor, embedded lyrics):
    /// into the mirror and the library now, without waiting for the change signal.
    func applyServerTracks(_ tracks: [ServerTrack]) {
        guard let profile = active, !tracks.isEmpty else { return }
        for t in tracks { mirror.tracks[t.id] = t }
        mirror.save(to: profile.supportDirectory)
        rebuildIndex()
        libraryStore.applyRemote(updated: appTracks(tracks), deleted: [])
        artwork.fillMissing()
        offline.libraryChanged()
        refreshLocalFiles()
    }

    func refreshLibraryInfo() async {
        if let info = try? await call({ try await $0.json(LibraryInfo.self, "GET", "v2/library") }) {
            library = info
        }
    }

    // MARK: - Change signal (§11)

    private func startChanges() {
        changesTask?.cancel()
        changesTask = Task { [weak self] in
            guard let self else { return }
            var backoff = 2.0
            // Catch up once, then wait for changes.
            await self.catchUp(["tracks", "playlists", "prefs", "history", "library", "organizer", "userdata"])
            var since = self.mirror.seq
            while !Task.isCancelled {
                do {
                    let changes = try await self.call {
                        try await $0.json(ChangesResponse.self, "GET", "v2/changes", query: [
                            URLQueryItem(name: "since", value: String(since)),
                            URLQueryItem(name: "wait", value: "55"),
                        ], timeout: 75)
                    }
                    backoff = 2
                    since = changes.seq
                    if !changes.changed.isEmpty { await self.catchUp(Set(changes.changed)) }
                } catch let error as ServerError {
                    if self.status == .signedOut || self.status == .identityChanged { return }
                    if case .api(_, _, let retry) = error, let retry {
                        backoff = Double(retry)
                    }
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 60)
                    // Back from offline: send what was edited meanwhile.
                    if self.status == .unreachable { await self.catchUp(["library", "userdata"]) }
                } catch {
                    return
                }
            }
        }
    }

    private func catchUp(_ kinds: Set<String>) async {
        // Edits made here while away go first, so pulling tracks can't put
        // the server's old tags back over them.
        if kinds.contains("tracks") { await tagEditor?.flushStaged() }
        if kinds.contains("library") || kinds.contains("tracks") {
            await refreshLibraryInfo()
            if let info = try? await call({ try await $0.json(ServerInfo.self, "GET", "v2/server") }) {
                serverInfo = info
                streamerSettingsChanged()
            }
        }
        if kinds.contains("tracks") { await pullTracks() }
        if kinds.contains("playlists") { await playlistSync.pull() }
        if kinds.contains("prefs") { await prefs.pull() }
        if kinds.contains("history") { await history.pull() }
        if kinds.contains("userdata") { await userData.sync() }
        if kinds.contains("organizer") { organizerRevision &+= 1 }
    }

    private func stopChanges() {
        changesTask?.cancel()
        changesTask = nil
    }

    // MARK: - Reconnecting

    /// A request or stream couldn't reach the server: say so, and keep
    /// trying in the background (2 s, doubling to a minute) until it answers.
    func connectionLost() {
        guard isActive, client != nil, status != .signedOut, status != .identityChanged else { return }
        status = .unreachable
        if retryTask == nil { retry(after: 2) }
    }

    /// Try now instead of waiting (the notice was clicked, the network came
    /// back, the Mac woke).
    func reconnectNow() {
        guard isActive, client != nil, status != .signedOut, status != .identityChanged else { return }
        if status == .unreachable { retry(after: 0) }
        else if changesTask != nil { startChanges() } // a long-poll from before sleep may be dead
    }

    /// The network changed under the app: whatever connection it had is
    /// gone, so start a new one, and check the server answers on it.
    private func networkChanged() {
        guard isActive, let client, status != .signedOut, status != .identityChanged else { return }
        client.resetConnections()
        if status == .unreachable { retry(after: 0) }
        else if changesTask != nil { startChanges() }
    }

    private func retry(after first: Double) {
        retryTask?.cancel()
        retryRound += 1
        let round = retryRound
        retryTask = Task { [weak self] in
            var delay = first
            while true {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let self, !Task.isCancelled else { return }
                guard self.status == .unreachable, let client = self.client else { break }
                // Each try on a new connection: the old one may be dead
                // without saying so (sleep, Wi-Fi, a VPN dropping).
                client.resetConnections()
                if (try? await self.call({ try await $0.json(ServerInfo.self, "GET", "v2/server", timeout: 10) })) != nil {
                    break
                }
                guard !Task.isCancelled else { return }
                delay = min(max(delay * 2, 2), 60)
            }
            guard let self, self.retryRound == round else { return }
            // Done before catching up, so a request that fails meanwhile
            // starts trying again rather than finding this one still here.
            self.retryTask = nil
            guard self.status == .ready else { return }
            self.reconnected()
        }
    }

    /// Back after an outage: send what waited, and catch up on everything
    /// that changed meanwhile.
    private func reconnected() {
        uploads.resume()
        uploads.scanForNewFiles()
        offline.libraryChanged()
        if NSApp?.isActive == true || changesTask != nil { startChanges() }
        else { Task { await catchUp(["tracks", "playlists", "prefs", "history", "library", "userdata"]) } }
    }

    /// Long-polls only while the app is in front; catches up on return.
    private func watchForeground() {
        guard foregroundObservers.isEmpty else { return }
        // The network going and coming back: say so at once, retry at once.
        path.pathUpdateHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                let up = p.status == .satisfied
                // A VPN or another network coming or going changes the route
                // to the server even while some network stays up.
                let interfaces = Set(p.availableInterfaces.map(\.name))
                defer { self.pathWasUp = up; self.pathInterfaces = interfaces }
                if !up { self.connectionLost() }
                else if !self.pathWasUp || (self.pathInterfaces.map { $0 != interfaces } ?? false) { self.networkChanged() }
            }
        }
        path.start(queue: .global(qos: .utility))
        let center = NotificationCenter.default
        foregroundObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.networkChanged() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopChanges() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.client != nil, self.changesTask == nil,
                          self.status != .signedOut, self.status != .identityChanged else { return }
                    self.startChanges()
                }
            },
        ]
    }
}

/// The local copy of the server's track list, and the cursor it is current to.
struct ServerMirror: Codable {
    var seq = 0
    var tracks: [UUID: ServerTrack] = [:]

    static func load(from dir: URL) -> ServerMirror {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("mirror.json")),
              let mirror = try? ServerClient.decoder.decode(ServerMirror.self, from: data) else { return ServerMirror() }
        return mirror
    }

    func save(to dir: URL) {
        let snapshot = self
        Task.detached(priority: .utility) {
            guard let data = try? ServerClient.encoder.encode(snapshot) else { return }
            try? data.write(to: dir.appendingPathComponent("mirror.json"), options: .atomic)
        }
    }
}
