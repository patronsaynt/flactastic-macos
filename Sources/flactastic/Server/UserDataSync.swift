import AppKit
import CryptoKit
import Foundation
import ImageIO

/// Customisation that follows a server account (§14, "User data"): artist
/// profiles as `artists/<id>.json`, and this client's own files under `mac/`.
/// Syncs by comparing ETags with the ones remembered when each item last
/// matched the server.
@Observable
@MainActor
final class UserDataSync {
    @ObservationIgnored unowned let session: ServerSession

    struct Remembered: Codable, Equatable {
        var etag: String
        /// SHA-256 of the bytes that matched it.
        var hash: String
    }

    enum Action: Equatable { case none, upload, download, deleteRemote, deleteLocal, forget }

    @ObservationIgnored private var remembered: [String: Remembered] = [:]
    /// False after a server answered 404 (older than user data): the
    /// account's data stays local until the next launch.
    private(set) var isSupported = true
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(session: ServerSession) { self.session = session }

    private var stateURL: URL { LibraryDataFolder.url.appendingPathComponent("userdata-sync.json") }

    // MARK: The table

    /// What to do with one item (§14): local and remembered are hashes of the
    /// bytes, server and remembered.etag are ETags.
    nonisolated static func decide(local: String?, server: String?, remembered r: Remembered?) -> Action {
        switch (local, server) {
        case (nil, nil): return r == nil ? .none : .forget
        case (let l?, nil):
            // Never synced: new here. Unchanged since it last matched: deleted elsewhere.
            return r?.hash == l ? .deleteLocal : .upload
        case (nil, let s?):
            // Unchanged on the server since it last matched: deleted here.
            return r?.etag == s ? .deleteRemote : .download
        case (let l?, let s?):
            guard let r else { return .download }
            switch (r.hash != l, r.etag != s) {
            case (false, false): return .none
            case (true, false): return .upload
            default: return .download // changed elsewhere, or both: the server copy wins
            }
        }
    }

    // MARK: Triggers

    /// Starts following local edits for the open account.
    func attach() {
        remembered = LibraryScope.read([String: Remembered].self, stateURL) ?? [:]
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [LibraryDataFolder.changed, UserDefaults.didChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.localEdit() }
            })
        }
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        pending?.cancel()
    }

    /// After a store's own save: sync a moment later, never blocking the editor.
    private func localEdit() {
        guard !isApplying, isSupported else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    // MARK: Syncing

    func sync() async {
        guard isSupported, session.isActive, session.scope != nil else { return }
        // One run at a time; a sync asked for meanwhile runs once more, and
        // its caller waits for that.
        if isRunning {
            again = true
            while isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            return
        }
        isRunning = true
        defer { isRunning = false }
        repeat {
            again = false
            await runOnce()
        } while again
    }

    private func runOnce() async {
        struct List: Decodable { struct Item: Decodable { let name: String; let etag: String }; let items: [Item] }
        let list: List
        do {
            list = try await session.call { try await $0.json(List.self, "GET", "v2/userdata") }
        } catch ServerError.api(code: "notFound", _, _) {
            isSupported = false
            return
        } catch {
            return // offline: edits stay here and go up on the next sync
        }
        let server = Dictionary(list.items.filter { Self.isOurs($0.name) }.map { ($0.name, Self.bare($0.etag)) },
                                uniquingKeysWith: { a, _ in a })
        let local = await localItems()
        let hashes = local.mapValues(Self.hash)
        var changes: [String: Data?] = [:]

        for name in Set(server.keys).union(local.keys).union(remembered.keys).sorted() {
            do {
                switch Self.decide(local: hashes[name], server: server[name], remembered: remembered[name]) {
                case .none: break
                case .forget: remembered[name] = nil
                case .upload:
                    let (_, http) = try await session.call {
                        try await $0.data(for: $0.request("PUT", "v2/userdata/\(name)", body: local[name]!,
                                                          contentType: "application/octet-stream"))
                    }
                    remembered[name] = Remembered(etag: Self.bare(http.value(forHTTPHeaderField: "ETag") ?? ""), hash: hashes[name]!)
                case .download:
                    let (data, http) = try await session.call { try await $0.data(for: $0.request("GET", "v2/userdata/\(name)")) }
                    let bytes = Self.canonical(data, name: name)
                    changes[name] = .some(bytes)
                    remembered[name] = Remembered(etag: Self.bare(http.value(forHTTPHeaderField: "ETag") ?? server[name]!),
                                                  hash: Self.hash(bytes))
                case .deleteRemote:
                    try await session.call { try await $0.send("DELETE", "v2/userdata/\(name)") }
                    remembered[name] = nil
                case .deleteLocal:
                    changes[name] = .some(nil)
                    remembered[name] = nil
                }
            } catch ServerError.api(code: "notFound", _, _) {
                remembered[name] = nil // gone meanwhile; the next list settles it
            } catch let error as ServerError {
                if case .api = error { continue }
                break // unreachable: keep the rest for the next sync
            } catch {
                break
            }
        }
        LibraryScope.write(remembered, to: stateURL)
        apply(changes)
    }

    // MARK: Names and bytes

    nonisolated static func isOurs(_ name: String) -> Bool { name.hasPrefix("artists/") || name.hasPrefix("mac/") }

    /// `artists/<first 32 hex of SHA-256 over the artist key>.json` (§14).
    nonisolated static func artistName(_ key: String) -> String {
        "artists/" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32) + ".json"
    }

    /// The server's name rule: `/`-separated segments of `A–Z a–z 0–9 . _ -`,
    /// none starting with a dot, 200 bytes at most.
    nonisolated static func isValidName(_ name: String) -> Bool {
        name.utf8.count <= 200 && name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { seg in
            !seg.isEmpty && seg.first != "." && seg.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
    }

    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func bare(_ etag: String) -> String { etag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }

    /// JSON as one stable byte string (sorted keys), so the same content
    /// always hashes the same; other bytes (logo images) as they are.
    nonisolated static func canonical(_ data: Data, name: String) -> Data {
        guard name.hasSuffix(".json"), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let out = try? sorted.encode(value) else { return data }
        return out
    }

    nonisolated(unsafe) private static let sorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Customisation kept in defaults, by file.
    nonisolated static let defaultsFiles: [String: [String]] = [
        "mac/spine-logos.json": ["flactastic.artistLogos", "flactastic.labelLogos", "flactastic.artistLogoTints",
                                 "flactastic.labelLogoTints", "flactastic.labelLogoBackings", "flactastic.labelLogoRotations"],
        "mac/spine-overrides.json": ["flactastic.spineOverrides"],
        "mac/genres.json": ["flactastic.genreGroups", "flactastic.customGenres"],
        "mac/home.json": ["flactastic.home.arrangesAutomatically", "flactastic.home.sectionOrder", "flactastic.home.hiddenSections"],
    ]

    /// Everything this account has locally, as the bytes it would upload.
    private func localItems() async -> [String: Data] {
        guard let scope = session.scope else { return [:] }
        let overrides = Array(scope.artists.overrides.values)
        let docs = Self.defaultsFiles.mapValues { LibraryScope.values($0) }
        let folder = LibraryDataFolder.url
        let root = session.libraryStore.rootURL
        let idByPath = session.trackIDsByPath
        return await Task.detached(priority: .utility) {
            var out: [String: Data] = [:]
            for o in overrides where !o.isEmpty {
                if let data = ArtistProfileFile.encode(o) { out[Self.artistName(o.canonicalKey)] = data }
            }
            var docs = docs
            if let pinned = try? Data(contentsOf: folder.appendingPathComponent("pinned_highlight.json")) {
                docs["mac/home.json", default: [:]]["pinned"] = .object(["$data": .string(pinned.base64EncodedString())])
            }
            for (name, values) in docs where !values.isEmpty {
                if let data = try? Self.sorted.encode(values) { out[name] = data }
            }
            let logos = folder.appendingPathComponent("SpineLogos", isDirectory: true)
            for file in (try? FileManager.default.contentsOfDirectory(atPath: logos.path)) ?? [] {
                let name = "mac/spine-logos/\(file)"
                if Self.isValidName(name), let data = try? Data(contentsOf: logos.appendingPathComponent(file)) { out[name] = data }
            }
            let mixes = folder.appendingPathComponent("mixes", isDirectory: true)
            if let data = try? Data(contentsOf: mixes.appendingPathComponent("feedback.json")) {
                out["mac/mixes/feedback.json"] = Self.canonical(Self.translate(data, idByPath.mapValues(\.uuidString)), name: ".json")
            }
            if let data = try? Data(contentsOf: mixes.appendingPathComponent("saved_mixes.json")) {
                out["mac/mixes/saved_mixes.json"] = Self.canonical(data, name: ".json")
            }
            if let root, let data = try? Data(contentsOf: root.appendingPathComponent(".flactastic/split-decisions.json")) {
                out["mac/split-decisions.json"] = Self.canonical(data, name: ".json")
            }
            return out
        }.value
    }

    /// Mix feedback names tracks by file path, which differs between Macs;
    /// on the server it names them by track ID. Unknown tracks are dropped.
    nonisolated static func translate(_ feedback: Data, _ map: [String: String]) -> Data {
        guard let value = try? JSONDecoder().decode([String: [String: [String]]].self, from: feedback) else { return feedback }
        let out = value.mapValues { $0.mapValues { $0.compactMap { map[$0] } } }
        return (try? sorted.encode(out)) ?? feedback
    }

    // MARK: Applying downloads

    private func apply(_ changes: [String: Data?]) {
        guard !changes.isEmpty, let scope = session.scope else { return }
        isApplying = true
        defer { isApplying = false }
        let folder = LibraryDataFolder.url
        var settingsChanged = false, mixesChanged = false

        for (name, data) in changes {
            if name.hasPrefix("artists/") {
                if let data, let o = try? JSONDecoder().decode(ArtistOverride.self, from: data) {
                    scope.artists.upsert(o)
                } else if data == nil, let key = scope.artists.overrides.keys.first(where: { Self.artistName($0) == name }) {
                    scope.artists.remove(key: key)
                }
            } else if name.hasPrefix("mac/spine-logos/") {
                let url = folder.appendingPathComponent("SpineLogos/" + name.dropFirst("mac/spine-logos/".count))
                Self.put(data, at: url)
                SpineLogoStore.clearCache()
            } else if let keys = Self.defaultsFiles[name] {
                let values = data.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
                LibraryScope.restore(values, keys: keys, clearMissing: true)
                if name == "mac/home.json" {
                    let pinned: Data? = { if case .object(let o)? = values["pinned"], case .string(let b)? = o["$data"] { return Data(base64Encoded: b) }; return nil }()
                    // Only a different pin changes Home's lyric; other Home
                    // settings changing elsewhere don't re-roll it.
                    let pinURL = folder.appendingPathComponent("pinned_highlight.json")
                    let pick = { (d: Data?) in d.flatMap { try? JSONDecoder().decode(HomeHighlight.Pick.self, from: $0) } }
                    if pick(pinned) != pick(try? Data(contentsOf: pinURL)) {
                        Self.put(pinned, at: pinURL)
                        scope.highlight.reset()
                    }
                }
                settingsChanged = true
            } else if name == "mac/mixes/feedback.json" {
                let back = Dictionary(session.trackIDsByPath.map { ($1.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
                Self.put(data.map { Self.translate($0, back) }, at: folder.appendingPathComponent("mixes/feedback.json"))
                mixesChanged = true
            } else if name == "mac/mixes/saved_mixes.json" {
                Self.put(data, at: folder.appendingPathComponent("mixes/saved_mixes.json"))
                mixesChanged = true
            } else if name == "mac/split-decisions.json", let root = session.libraryStore.rootURL {
                Self.put(data, at: root.appendingPathComponent(".flactastic/split-decisions.json"))
                session.libraryStore.reloadSplitDecisions()
            }
        }
        if settingsChanged { scope.settings.adoptSynced(from: Settings()) }
        if mixesChanged { MixSignals.shared.reload() }
    }

    nonisolated private static func put(_ data: Data?, at url: URL) {
        guard let data else { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Bringing this Mac's customisation across

    /// A one-time push: artist profiles fill in artists the account has none
    /// for; spine logos, Edit Spine, genres, Home, the switches and credit
    /// answers replace the account's. Mixes stay, as they name this Mac's
    /// tracks and playlists.
    func copyFromThisMac() async {
        guard let scope = session.scope, session.isActive else { return }
        let local = LibraryDataFolder.local
        isApplying = true
        let list = LibraryScope.read([ArtistOverride].self, local.appendingPathComponent("artists.json")) ?? []
        for o in list where scope.artists.overrides[o.canonicalKey] == nil { scope.artists.upsert(o) }

        let fm = FileManager.default
        let from = local.appendingPathComponent("SpineLogos", isDirectory: true)
        let to = LibraryDataFolder.url.appendingPathComponent("SpineLogos", isDirectory: true)
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        for file in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] where !fm.fileExists(atPath: to.appendingPathComponent(file).path) {
            try? fm.copyItem(at: from.appendingPathComponent(file), to: to.appendingPathComponent(file))
        }
        SpineLogoStore.clearCache()

        LibraryScope.restore(LibraryScope.localValues(), keys: LibraryScope.dataKeys + LibraryScope.switchKeys, clearMissing: true)
        Self.put(try? Data(contentsOf: local.appendingPathComponent("pinned_highlight.json")),
                 at: LibraryDataFolder.url.appendingPathComponent("pinned_highlight.json"))
        scope.highlight.reset()
        scope.settings.adoptSynced(from: Settings())

        if let path = session.settings.lastRootPath {
            let theirs = URL(fileURLWithPath: path).appendingPathComponent(".flactastic/split-decisions.json")
            if let answers = LibraryScope.read([String: MultiValueParser.Decision].self, theirs) {
                session.libraryStore.recordSplitDecisions(answers, overwrite: false)
            }
        }
        isApplying = false
        await sync()
    }
}

/// An artist profile as stored on the server: the app's `ArtistOverride`
/// JSON, with pictures scaled to 1000 px (profile) and 2560 px (banner) on
/// the long edge, and smaller still if the file would pass 8 MiB.
enum ArtistProfileFile {
    static let limit = 8 << 20
    static let profileEdge = 1000
    static let bannerEdge = 2560

    static func encode(_ o: ArtistOverride) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for quality in [0.9, 0.75, 0.6, 0.45] {
            var scaled = o
            scaled.profileImage = o.profileImage.map { fit($0, edge: profileEdge, quality: quality) }
            scaled.bannerImage = o.bannerImage.map { fit($0, edge: bannerEdge, quality: quality) }
            if let data = try? encoder.encode(scaled), data.count < limit { return data }
        }
        return nil
    }

    /// The picture unchanged if it already fits `edge` and isn't being
    /// squeezed; else scaled and re-encoded as JPEG.
    static func fit(_ data: Data, edge: Int, quality: Double) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return data }
        if max(w, h) <= edge, quality == 0.9 { return data }
        guard let image = PrerenderedImage.downsampled(data, maxPixel: min(edge, max(w, h))),
              let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
        else { return data }
        return jpeg
    }
}
