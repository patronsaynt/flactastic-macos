import Foundation

/// Remembers each file's SHA-256 so building a manifest doesn't re-read the
/// whole library every time.
///
/// Hashing is by far the most expensive part of preparing a sync — a 200 GB
/// library is 200 GB of reading — and almost none of it changes between runs.
///
/// ### Why this isn't folded into `TrackMetadataCache`
/// That cache is rebuilt from scratch out of `[Track]` on every scan
/// (`TrackMetadataCache.rebuild(from:rootURL:)`), and `Track` has no hash
/// field to rebuild one from. Adding a `contentHash` there would therefore
/// throw every hash away on each scan — the exact opposite of the point. A
/// separate sidecar keyed the same way, with the same size+mtime validity
/// rule, keeps both caches honest about what they own.
///
/// Purely derived: deleting `<root>/.flactastic/sync-hashes.json` costs one
/// slow sync and nothing else.
struct ContentHashCache: Sendable {

    struct Entry: Codable, Sendable {
        var contentHash: String
        var fileSize: Int64
        var mtime: Date

        /// Same validity rule as `TrackMetadataCacheEntry.isValid`, including
        /// the millisecond tolerance that absorbs Codable's `Date` round-trip.
        func isValid(fileSize: Int64, mtime: Date) -> Bool {
            self.fileSize == fileSize && abs(self.mtime.timeIntervalSince(mtime)) < 0.001
        }
    }

    private var entries: [String: Entry]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    static func sidecarURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(".flactastic", isDirectory: true)
            .appendingPathComponent("sync-hashes.json")
    }

    /// Blocking read — call off the main actor. Any failure means an empty
    /// cache, which costs time and nothing else.
    static func load(rootURL: URL) -> ContentHashCache {
        guard let data = try? Data(contentsOf: sidecarURL(rootURL: rootURL)),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return ContentHashCache()
        }
        return ContentHashCache(entries: entries)
    }

    /// Blocking write — call once per manifest build, not per file.
    func save(rootURL: URL) {
        let url = Self.sidecarURL(rootURL: rootURL)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            print("[ContentHashCache] Failed to save sidecar: \(error)")
        }
    }

    /// The cached hash for a file, or `nil` when absent or stale.
    func hash(forRelativePath path: String, fileSize: Int64, mtime: Date) -> String? {
        guard let entry = entries[path], entry.isValid(fileSize: fileSize, mtime: mtime) else {
            return nil
        }
        return entry.contentHash
    }

    mutating func store(hash: String, forRelativePath path: String, fileSize: Int64, mtime: Date) {
        entries[path] = Entry(contentHash: hash, fileSize: fileSize, mtime: mtime)
    }

    /// Drops entries for files that are no longer in the library, so the
    /// sidecar doesn't grow without bound across years of reorganisation.
    mutating func prune(keeping livePaths: Set<String>) {
        entries = entries.filter { livePaths.contains($0.key) }
    }

    var count: Int { entries.count }
}
