import Foundation
import Observation

/// One cached lrclib lookup. Stores raw LRC / plain text — parsing is
/// performed on read so we can change the parser without re-fetching.
struct LyricsCacheEntry: Codable, Sendable, Hashable {
    var key: String
    var plainLyrics: String?
    var syncedLyrics: String?
    var fetchedAt: Date
    /// Negative cache: lrclib returned 404 for this query.
    var notFound: Bool

    init(
        key: String,
        plainLyrics: String? = nil,
        syncedLyrics: String? = nil,
        fetchedAt: Date = Date(),
        notFound: Bool = false
    ) {
        self.key = key
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
        self.fetchedAt = fetchedAt
        self.notFound = notFound
    }
}

/// Stable cache key shared between cache lookups and fetcher dedup.
/// Album is intentionally excluded (noisy across remasters) but is still
/// passed to the API for matching.
enum LyricsCacheKey {
    static func make(artist: String?, title: String?, duration: TimeInterval?) -> String {
        let a = ArtistResolver.key(for: artist ?? "")
        let t = ArtistResolver.key(for: title ?? "")
        let d = duration.map { Int($0.rounded()) } ?? -1
        return "\(a)|\(t)|\(d)"
    }
}

@Observable
@MainActor
final class LyricsRemoteCache {
    /// Refresh successful entries after this many seconds (~30 days).
    static let positiveTTL: TimeInterval = 60 * 60 * 24 * 30
    /// Retry negative (not-found) entries after this many seconds (~7 days).
    static let negativeTTL: TimeInterval = 60 * 60 * 24 * 7

    private(set) var entries: [String: LyricsCacheEntry] = [:]
    /// The saved cache has been read (or there was none). Before this,
    /// `entries` being empty says nothing.
    private(set) var isLoaded = false

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("flactastic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lyrics_cache.json")
    }()

    func load() {
        defer { isLoaded = true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let list = try JSONDecoder().decode([LyricsCacheEntry].self, from: data)
            entries = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0) })
        } catch {
            print("[LyricsRemoteCache] Failed to load: \(error)")
        }
    }

    /// Async variant of `load()` for app bootstrap: file read + JSON decode
    /// run off the main actor so launch doesn't block first paint on disk I/O.
    func loadAsync() async {
        defer { isLoaded = true }
        let url = fileURL
        let loaded: [LyricsCacheEntry]? = await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode([LyricsCacheEntry].self, from: data)
            } catch {
                print("[LyricsRemoteCache] Failed to load: \(error)")
                return nil
            }
        }.value
        guard let loaded else { return }
        entries = Dictionary(uniqueKeysWithValues: loaded.map { ($0.key, $0) })
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
            let list = Array(entries.values).sorted { $0.key < $1.key }
            let data = try JSONEncoder().encode(list)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[LyricsRemoteCache] Failed to save: \(error)")
        }
    }

    func entry(forKey key: String) -> LyricsCacheEntry? { entries[key] }

    func setEntry(_ entry: LyricsCacheEntry) {
        entries[entry.key] = entry
        save()
    }

    /// True when a fresh entry already exists for this key (no fetch needed).
    func isFresh(forKey key: String, now: Date = Date()) -> Bool {
        guard let entry = entries[key] else { return false }
        let age = now.timeIntervalSince(entry.fetchedAt)
        return entry.notFound ? age < Self.negativeTTL : age < Self.positiveTTL
    }
}
