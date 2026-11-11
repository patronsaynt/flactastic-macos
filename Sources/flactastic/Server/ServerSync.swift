import Foundation
import Observation

// MARK: - Artwork (§9.3)

/// Server covers by `artworkID`. Responses are immutable, so a cover fetched
/// once is kept on disk for good and shared in memory by every track using it.
@MainActor
final class ServerArtwork {
    unowned let session: ServerSession
    private var memory: [String: Data] = [:]
    private var running = false

    init(session: ServerSession) { self.session = session }

    func thumbnail(for id: String) -> Data? { memory[id] }

    static func isValid(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Loads every cover the library uses that isn't in memory: from disk
    /// first, then from the server, and hands them to the library in batches.
    func fillMissing() {
        guard !running, let profile = session.active, let client = session.client else { return }
        let wanted = Set(session.mirror.tracks.values.compactMap(\.artworkID)).filter(Self.isValid).subtracting(memory.keys)
        guard !wanted.isEmpty else { return }
        running = true
        let dir = profile.supportDirectory.appendingPathComponent("art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task {
            let onDisk = await Task.detached(priority: .utility) {
                var found: [String: Data] = [:]
                for id in wanted {
                    if let data = try? Data(contentsOf: dir.appendingPathComponent("\(id).img")) { found[id] = data }
                }
                return found
            }.value
            memory.merge(onDisk) { a, _ in a }
            apply(Set(onDisk.keys))

            var queue = Array(wanted.subtracting(onDisk.keys))
            await withTaskGroup(of: (String, Data?).self) { group in
                func next() {
                    guard let id = queue.popLast() else { return }
                    group.addTask { (id, try? await Self.fetch(client, id, to: dir)) }
                }
                for _ in 0..<6 { next() }
                var batch = Set<String>()
                for await (id, data) in group {
                    if let data { memory[id] = data; batch.insert(id) }
                    if batch.count >= 200 { apply(batch); batch = [] }
                    next()
                }
                apply(batch)
            }
            running = false
        }
    }

    nonisolated private static func fetch(_ client: ServerClient, _ id: String, to dir: URL) async throws -> Data {
        let (data, _) = try await client.data(for: client.request("GET", "v2/art/\(id)", query: [URLQueryItem(name: "size", value: "1000")]))
        try? data.write(to: dir.appendingPathComponent("\(id).img"), options: .atomic)
        return data
    }

    private func apply(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let updated = session.libraryStore.tracks.compactMap { t -> Track? in
            guard let a = t.artworkID, ids.contains(a), let data = memory[a] else { return nil }
            var copy = t
            copy.artwork = data
            return copy
        }
        if !updated.isEmpty { session.libraryStore.applyRemote(updated: updated, deleted: []) }
    }
}

// MARK: - Playlists (§14)

/// Keeps `PlaylistStore` and `/v2/playlists` in step. Last write wins, but a
/// save that would replace a copy changed elsewhere since it was read is
/// shown to the user first.
@Observable
@MainActor
final class PlaylistSync {
    struct Conflict: Identifiable {
        let id = UUID()
        let local: Playlist
        /// Nil when the server copy was deleted elsewhere.
        let server: Playlist?
    }

    /// A save waiting on the user's word.
    var conflict: Conflict?

    @ObservationIgnored unowned let session: ServerSession
    /// The server copies as last read or written: the baseline for telling
    /// local edits from changes made elsewhere.
    @ObservationIgnored private var known: [UUID: Playlist] = [:]
    @ObservationIgnored private var pushTask: Task<Void, Never>?

    init(session: ServerSession) { self.session = session }

    private var knownURL: URL? { session.active?.supportDirectory.appendingPathComponent("playlists-known.json") }

    func attach() {
        known = [:]
        if let url = knownURL, let data = try? Data(contentsOf: url),
           let list = try? ServerClient.decoder.decode([Playlist].self, from: data) {
            known = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        session.playlists.onSave = { [weak self] in self?.schedulePush() }
    }

    func detach() {
        session.playlists.onSave = nil
        pushTask?.cancel()
    }

    private func saveKnown() {
        guard let url = knownURL, let data = try? ServerClient.encoder.encode(Array(known.values)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Reads every playlist and merges: edits made elsewhere are taken, local
    /// edits made while offline are sent, and both at once ask the user.
    func pull() async {
        struct List: Decodable { let playlists: [Playlist] }
        guard let server = try? await session.call({ try await $0.json(List.self, "GET", "v2/playlists") }).playlists else { return }
        let serverByID = Dictionary(server.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var local = session.playlists.playlists
        var toPush: [Playlist] = []

        for (i, lp) in local.enumerated().reversed() {
            let base = known[lp.id]
            switch serverByID[lp.id] {
            case let sp? where sp == lp:
                known[lp.id] = sp
            case let sp?:
                if base == lp { local[i] = sp; known[lp.id] = sp }
                else if base == sp { toPush.append(lp) }
                else { conflict = Conflict(local: lp, server: sp) }
            case nil:
                if base == nil { toPush.append(lp) }           // made here, never sent
                else if base == lp { local.remove(at: i); known[lp.id] = nil }  // deleted elsewhere
                else { conflict = Conflict(local: lp, server: nil) }
            }
        }
        let localIDs = Set(local.map(\.id))
        for sp in server where !localIDs.contains(sp.id) && known[sp.id] == nil {
            local.append(sp)
            known[sp.id] = sp
        }
        session.playlists.replaceAll(local)
        saveKnown()
        for p in toPush { await put(p) }
    }

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    /// Sends what changed locally since the last sync.
    func push() async {
        let local = session.playlists.playlists
        for p in local where known[p.id] != p {
            // Read the server copy first: if it changed since we last saw it,
            // the user sees what this save would replace.
            let current: Playlist?
            do {
                current = try await session.call { try await $0.json(Playlist.self, "GET", "v2/playlists/\(p.id.uuidString)") }
            } catch ServerError.api(code: "notFound", _, _) {
                current = nil
            } catch {
                return
            }
            if let current, current != known[p.id], current != p {
                conflict = Conflict(local: p, server: current)
                return
            }
            await put(p)
        }
        let ids = Set(local.map(\.id))
        for id in known.keys where !ids.contains(id) {
            do {
                try await session.call { try await $0.send("DELETE", "v2/playlists/\(id.uuidString)") }
            } catch ServerError.api(code: "notFound", _, _) {
            } catch { return }
            known[id] = nil
        }
        saveKnown()
    }

    private func put(_ p: Playlist) async {
        do {
            try await session.call { try await $0.send("PUT", "v2/playlists/\(p.id.uuidString)", body: p) }
            known[p.id] = p
            saveKnown()
        } catch {}
    }

    /// The user chose to replace the server's copy with this Mac's.
    func keepMine(_ c: Conflict) async {
        conflict = nil
        await put(c.local)
        await push()
    }

    /// The user chose the server's copy (or its deletion).
    func useServers(_ c: Conflict) {
        conflict = nil
        var local = session.playlists.playlists
        if let server = c.server {
            if let i = local.firstIndex(where: { $0.id == server.id }) { local[i] = server } else { local.append(server) }
            known[server.id] = server
        } else {
            local.removeAll { $0.id == c.local.id }
            known[c.local.id] = nil
        }
        session.playlists.replaceAll(local)
        saveKnown()
    }
}

// MARK: - Preferences (§14)

/// `streamQuality`, `artistSeparator`, and the Mac settings that follow the
/// user (`clients.mac`). Credentials never go here.
@Observable
@MainActor
final class PrefsSync {
    private(set) var streamQuality: StreamQuality = .original

    @ObservationIgnored unowned let session: ServerSession
    @ObservationIgnored private var lastSynced: [String: JSONValue] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pushTask: Task<Void, Never>?

    init(session: ServerSession) { self.session = session }

    /// Defaults keys carried in `clients.mac`: look and shelf, Home layout,
    /// library rules, and the lyrics and artist-image switches.
    /// Small switches only; logos, Edit Spine, genres and Home travel as
    /// user data (`UserDataSync`).
    nonisolated static let syncedKeys = [
        "flactastic.theme", "flactastic.clearCaseLook", "flactastic.blurSpineArt", "flactastic.spineVariety",
        "flactastic.shelfTheme", "flactastic.spineLabelMark", "flactastic.ageSpinesWithYear",
        "flactastic.spineShuffles", "flactastic.spineStyle", "flactastic.useSpineScans",
        "flactastic.disabledSpineFaces", "flactastic.showAllArtists",
        "flactastic.hideSinglesInAlbums", "flactastic.countedPlayFraction",
        "flactastic.lyricsLookupEnabled", "flactastic.autoFetchArtistImages",
    ]

    func pull() async {
        guard let prefs = try? await session.call({ try await $0.json(ServerPrefs.self, "GET", "v2/prefs") }) else { return }
        streamQuality = prefs.streamQuality.flatMap(StreamQuality.init(rawValue:)) ?? .original
        session.streamerSettingsChanged()
        if let sep = prefs.artistSeparator, MultiValueParser.displaySeparatorChoices.contains(sep),
           sep != session.settings.artistSeparator {
            session.settings.artistSeparator = sep
        }
        // Nothing stored yet: nothing is sent until a switch changes, so the
        // local library's settings never reach a new account by themselves.
        if case .object(let mac)? = prefs.clients?["mac"] { apply(mac) } else { lastSynced = snapshot() }
        watch()
    }

    func setStreamQuality(_ quality: StreamQuality) async {
        streamQuality = quality
        session.streamerSettingsChanged()
        try? await session.call { try await $0.send("PATCH", "v2/prefs", body: ServerPrefs(streamQuality: quality.rawValue)) }
    }

    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func watch() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePush() }
        }
    }

    private func snapshot() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in Self.syncedKeys {
            if let v = UserDefaults.standard.object(forKey: key).flatMap(Self.json) { out[key] = v }
        }
        return out
    }

    private func schedulePush() {
        let current = snapshot()
        let separator = session.settings.artistSeparator
        guard current != lastSynced else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let body = ServerPrefs(artistSeparator: separator, clients: ["mac": .object(current)])
            if (try? await self.session.call({ try await $0.send("PATCH", "v2/prefs", body: body) })) != nil {
                self.lastSynced = current
            }
        }
    }

    private func apply(_ mac: [String: JSONValue]) {
        lastSynced = mac
        for key in Self.syncedKeys {
            if let v = mac[key], let value = Self.plist(v) { UserDefaults.standard.set(value, forKey: key) }
        }
        session.settings.adoptSynced(from: Settings())
    }

    /// A defaults value as JSON; `Data` (the JSON-backed settings) is tagged.
    nonisolated static func json(_ any: Any) -> JSONValue? {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return CFNumberIsFloatType(n) ? .number(n.doubleValue) : .int(n.intValue)
        case let s as String: return .string(s)
        case let d as Data: return .object(["$data": .string(d.base64EncodedString())])
        case let a as [Any]: return .array(a.compactMap(json))
        case let o as [String: Any]: return .object(o.compactMapValues(json))
        default: return nil
        }
    }

    nonisolated static func plist(_ v: JSONValue) -> Any? {
        switch v {
        case .null: return nil
        case .bool(let b): return b
        case .int(let i): return i
        case .number(let d): return d
        case .string(let s): return s
        case .array(let a): return a.compactMap(plist)
        case .object(let o):
            if o.count == 1, case .string(let b64)? = o["$data"] { return Data(base64Encoded: b64) }
            return o.compactMapValues(plist)
        }
    }
}

extension Settings {
    /// Takes the synced settings from `other` (freshly read from defaults).
    func adoptSynced(from other: Settings) {
        theme = other.theme
        clearCaseLook = other.clearCaseLook
        blurSpineArt = other.blurSpineArt
        spineVariety = other.spineVariety
        shelfTheme = other.shelfTheme
        spineLabelMark = other.spineLabelMark
        ageSpinesWithYear = other.ageSpinesWithYear
        spineShuffles = other.spineShuffles
        spineStyle = other.spineStyle
        useSpineScans = other.useSpineScans
        spineOverrides = other.spineOverrides
        disabledSpineFaces = other.disabledSpineFaces
        artistLogos = other.artistLogos
        labelLogos = other.labelLogos
        artistLogoTints = other.artistLogoTints
        labelLogoTints = other.labelLogoTints
        labelLogoBackings = other.labelLogoBackings
        labelLogoRotations = other.labelLogoRotations
        homeArrangesAutomatically = other.homeArrangesAutomatically
        homeSectionOrder = other.homeSectionOrder
        homeHiddenSections = other.homeHiddenSections
        genreGroups = other.genreGroups
        customGenres = other.customGenres
        showAllArtists = other.showAllArtists
        hideSinglesInAlbums = other.hideSinglesInAlbums
        countedPlayFraction = other.countedPlayFraction
        lyricsLookupEnabled = other.lyricsLookupEnabled
        autoFetchArtistImages = other.autoFetchArtistImages
        artistSeparator = other.artistSeparator
    }
}

// MARK: - Listening history (§15)

/// Posts this Mac's plays (batched, idempotent by event ID) and merges every
/// other device's from `GET /v2/history`. Home keeps computing its stats
/// from the merged history.
@MainActor
final class HistorySync {
    unowned let session: ServerSession
    private struct State: Codable {
        var seq = 0
        var outbox: Set<UUID> = []
        var contextsDirty = false
        var offeredLocalUpload = false
    }
    private var state = State()
    private var postTask: Task<Void, Never>?

    init(session: ServerSession) { self.session = session }

    private var stateURL: URL? { session.active?.supportDirectory.appendingPathComponent("history-sync.json") }

    func attach() {
        state = stateURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        session.listening.libraryID = { [weak session] track in session?.serverID(for: track) }
        // Stats count only this library's tracks, and only those plays are sent.
        session.listening.belongs = { [weak session] event in session?.mirror.tracks[event.trackID] != nil }
        session.listening.onRecord = { [weak self, weak session] event in
            guard session?.mirror.tracks[event.trackID] != nil else { return }
            self?.state.outbox.insert(event.id)
            self?.schedulePost()
        }
        session.listening.onContext = { [weak self] in
            self?.state.contextsDirty = true
            self?.schedulePost()
        }
        schedulePost()
    }

    func detach() {
        session.listening.belongs = nil
        session.listening.libraryID = nil
        session.listening.onRecord = nil
        session.listening.onContext = nil
    }

    private func save() {
        guard let url = stateURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func schedulePost() {
        save()
        postTask?.cancel()
        postTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.post()
        }
    }

    private struct Batch: Encodable { let events: [PlayEvent]; let contexts: [RecentContext] }

    /// Sends the outbox, ≤ 1000 events per request.
    func post() async {
        let byID = Dictionary(session.listening.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        state.outbox = state.outbox.filter { byID[$0] != nil }
        while !state.outbox.isEmpty || state.contextsDirty {
            let ids = Array(state.outbox.prefix(1000))
            let contexts = state.contextsDirty ? Array(session.listening.recentContexts.suffix(1000)) : []
            let batch = Batch(events: ids.compactMap { byID[$0] }, contexts: contexts)
            do {
                try await session.call { try await $0.send("POST", "v2/history", body: batch) }
            } catch { return }
            state.outbox.subtract(ids)
            state.contextsDirty = false
            save()
        }
    }

    /// Merges plays from every device, page by page.
    func pull() async {
        struct Page: Decodable { let events: [PlayEvent]; let contexts: [RecentContext]; let seq: Int; let more: Bool }
        var more = true
        while more {
            guard let page = try? await session.call({
                try await $0.json(Page.self, "GET", "v2/history", query: [
                    URLQueryItem(name: "since", value: String(state.seq)),
                    URLQueryItem(name: "limit", value: "5000"),
                ])
            }) else { return }
            session.listening.merge(events: page.events, contexts: page.contexts)
            state.seq = page.seq
            more = page.more
            save()
        }
    }

    /// Whether to offer bringing this Mac's local history (asked once).
    var shouldOfferLocalUpload: Bool { !state.offeredLocalUpload }

    func markOffered() {
        state.offeredLocalUpload = true
        save()
    }

    /// Posts the local folder's history once. Event IDs make a repeat harmless.
    func uploadLocal(from root: URL) async throws -> Int {
        markOffered()
        let url = ListeningStore.historyURL(for: root, librariesDirectory: ListeningStore.defaultLibrariesDirectory)
        let (events, contexts) = Self.matched(ListeningStore.readHistory(url), to: Array(session.mirror.tracks.values))
        var sent = 0
        for start in stride(from: 0, to: max(events.count, 1), by: 1000) {
            let slice = Array(events[start..<min(start + 1000, events.count)])
            try await session.call {
                try await $0.send("POST", "v2/history", body: Batch(events: slice, contexts: start == 0 ? contexts : []))
            }
            sent += slice.count
        }
        await pull()
        return sent
    }

    /// Of another library's history, the plays of songs the server has (by
    /// title, artist and album), under its track IDs, and the albums among
    /// them. That library's playlists aren't the server's, so they're dropped.
    nonisolated static func matched(_ history: ([PlayEvent], [RecentContext]), to tracks: [ServerTrack]) -> ([PlayEvent], [RecentContext]) {
        func key(_ title: String?, _ artist: String?, _ album: String?) -> String {
            [title, artist, album].map { ArtistResolver.key(for: $0 ?? "") }.joined(separator: "|")
        }
        var ids: [String: UUID] = [:]
        for t in tracks { ids[key(t.title, t.artist ?? t.albumArtist, t.album)] = t.id }
        let events: [PlayEvent] = history.0.compactMap { e in
            guard let id = ids[key(e.title, e.artist, e.album)] else { return nil }
            var e = e
            e.trackID = id
            return e
        }
        let albums = Set(events.compactMap(\.albumID))
        return (events, history.1.filter { $0.kind == .album && albums.contains($0.targetID) })
    }
}
