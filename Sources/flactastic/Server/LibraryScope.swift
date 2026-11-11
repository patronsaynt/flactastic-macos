import Foundation

/// Keeps customisation with the library it belongs to. Files live in
/// `LibraryDataFolder`; settings live in `UserDefaults`, so while a server
/// account is open its values sit in the keys and the local library's wait
/// in a stash beside its files, to be put back when it opens again. The
/// stash names the library that owns the keys now, so a quit part-way
/// through never mixes the two.
@MainActor
final class LibraryScope {
    let artists: ArtistStore
    let highlight: HomeHighlight
    let settings: Settings

    init(artists: ArtistStore, highlight: HomeHighlight, settings: Settings) {
        self.artists = artists
        self.highlight = highlight
        self.settings = settings
    }

    /// Customisation kept in defaults that belongs to a library. A new
    /// account starts without these.
    nonisolated static let dataKeys = [
        "flactastic.artistLogos", "flactastic.labelLogos", "flactastic.artistLogoTints",
        "flactastic.labelLogoTints", "flactastic.labelLogoBackings", "flactastic.labelLogoRotations",
        "flactastic.spineOverrides", "flactastic.genreGroups", "flactastic.customGenres",
        "flactastic.home.arrangesAutomatically", "flactastic.home.sectionOrder", "flactastic.home.hiddenSections",
    ]

    /// Switches that follow an account (`prefs.clients.mac`). A new account
    /// starts from the current ones, so the look doesn't jump on sign-in.
    nonisolated static let switchKeys = PrefsSync.syncedKeys + [MultiValueParser.displaySeparatorDefaultsKey]

    private struct Stash: Codable, Sendable {
        /// The folder whose library owns the keys now.
        var owner: String
        var values: [String: JSONValue]
    }

    nonisolated private static var stashURL: URL { LibraryDataFolder.local.appendingPathComponent("local-settings.json") }
    private static func snapshotURL(_ folder: URL) -> URL { folder.appendingPathComponent("settings.json") }

    /// Opens `folder`'s customisation: `LibraryDataFolder.local` for the
    /// local library, an account's folder for a server.
    func enter(_ folder: URL) {
        let local = LibraryDataFolder.local.standardizedFileURL
        let target = folder.standardizedFileURL
        var stash = Self.read(Stash.self, Self.stashURL)

        if let owner = stash.map({ URL(fileURLWithPath: $0.owner).standardizedFileURL }), owner != target {
            // The keys hold another account's values: keep them with it.
            Self.write(Self.values(Self.dataKeys + Self.switchKeys), to: Self.snapshotURL(owner))
        }
        if target == local {
            if let stash { Self.restore(stash.values, keys: Self.dataKeys + Self.switchKeys, clearMissing: true) }
            try? FileManager.default.removeItem(at: Self.stashURL)
        } else if stash?.owner != target.path {
            if stash == nil { stash = Stash(owner: target.path, values: Self.values(Self.dataKeys + Self.switchKeys)) }
            let saved = Self.read([String: JSONValue].self, Self.snapshotURL(target)) ?? [:]
            Self.restore(saved, keys: Self.dataKeys, clearMissing: true)
            Self.restore(saved, keys: Self.switchKeys, clearMissing: false)
            stash?.owner = target.path
            Self.write(stash, to: Self.stashURL)
        }

        LibraryDataFolder.use(target)
        artists.load()
        SpineLogoStore.clearCache()
        highlight.reset()
        MixSignals.shared.reload()
        settings.adoptSynced(from: Settings())
    }

    /// This Mac's own library's values, wherever they are right now: in the
    /// keys, or in the stash while an account is open.
    nonisolated static func localValues() -> [String: JSONValue] {
        stashedLocalValues() ?? values(dataKeys + switchKeys)
    }

    /// The local library's values while an account holds the keys, else nil.
    nonisolated static func stashedLocalValues(in folder: URL = LibraryDataFolder.local) -> [String: JSONValue]? {
        read(Stash.self, folder.appendingPathComponent("local-settings.json"))?.values
    }

    nonisolated static func values(_ keys: [String]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in keys { if let v = UserDefaults.standard.object(forKey: key).flatMap(PrefsSync.json) { out[key] = v } }
        return out
    }

    static func restore(_ values: [String: JSONValue], keys: [String], clearMissing: Bool) {
        for key in keys {
            if let v = values[key].flatMap(PrefsSync.plist) { UserDefaults.standard.set(v, forKey: key) }
            else if clearMissing { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    nonisolated static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func write<T: Encodable>(_ value: T?, to url: URL) {
        guard let value, let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
