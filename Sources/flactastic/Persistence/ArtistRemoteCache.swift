import Foundation
import Observation

/// Cached remote-fetched image for an artist. Kept separate from
/// `ArtistOverride` so user-supplied customisations remain untouched and
/// the remote cache can be invalidated independently.
struct ArtistRemoteEntry: Codable, Sendable, Hashable {
    var canonicalKey: String
    var deezerId: Int?
    var profileImage: Data?
    var fetchedAt: Date
    /// Negative cache: true when Deezer returned no usable match.
    var notFound: Bool

    init(
        canonicalKey: String,
        deezerId: Int? = nil,
        profileImage: Data? = nil,
        fetchedAt: Date = Date(),
        notFound: Bool = false
    ) {
        self.canonicalKey = canonicalKey
        self.deezerId = deezerId
        self.profileImage = profileImage
        self.fetchedAt = fetchedAt
        self.notFound = notFound
    }
}

@Observable
@MainActor
final class ArtistRemoteCache {
    /// Refresh successful entries after this many seconds (~30 days).
    static let positiveTTL: TimeInterval = 60 * 60 * 24 * 30
    /// Retry negative (not-found) entries after this many seconds (~7 days).
    static let negativeTTL: TimeInterval = 60 * 60 * 24 * 7

    private(set) var entries: [String: ArtistRemoteEntry] = [:]

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("flactastic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("artist_remote_cache.json")
    }()

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let list = try JSONDecoder().decode([ArtistRemoteEntry].self, from: data)
            entries = Dictionary(uniqueKeysWithValues: list.map { ($0.canonicalKey, $0) })
        } catch {
            print("[ArtistRemoteCache] Failed to load: \(error)")
        }
    }

    /// Async variant of `load()` for app bootstrap: file read + JSON decode
    /// run off the main actor so launch doesn't block first paint on disk I/O.
    func loadAsync() async {
        let url = fileURL
        let loaded: [ArtistRemoteEntry]? = await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode([ArtistRemoteEntry].self, from: data)
            } catch {
                print("[ArtistRemoteCache] Failed to load: \(error)")
                return nil
            }
        }.value
        guard let loaded else { return }
        entries = Dictionary(uniqueKeysWithValues: loaded.map { ($0.canonicalKey, $0) })
    }

    /// Forget every cached entry and save the empty cache. Entries are
    /// fetched again as they're next needed.
    func removeAll() {
        entries = [:]
        save()
    }

    /// Size of the saved cache file, in bytes.
    var fileSize: Int {
        (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    func save() {
        do {
            let list = Array(entries.values).sorted { $0.canonicalKey < $1.canonicalKey }
            let data = try JSONEncoder().encode(list)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[ArtistRemoteCache] Failed to save: \(error)")
        }
    }

    func entry(forKey key: String) -> ArtistRemoteEntry? {
        entries[key]
    }

    func setEntry(_ entry: ArtistRemoteEntry) {
        entries[entry.canonicalKey] = entry
        save()
    }

    /// True when a fresh entry already exists for this key (no fetch needed).
    func isFresh(forKey key: String, now: Date = Date()) -> Bool {
        guard let entry = entries[key] else { return false }
        let age = now.timeIntervalSince(entry.fetchedAt)
        return entry.notFound ? age < Self.negativeTTL : age < Self.positiveTTL
    }
}
