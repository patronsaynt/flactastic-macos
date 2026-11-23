import Foundation
import os

/// Streamed tracks kept on disk between plays, so a replay, Previous or a
/// repeated playlist costs no download. One per server, under Caches (the
/// system may clear it). Separate from offline copies, which never count
/// here: a track made available offline has its cached copy removed.
///
/// Originals are kept as they download, partial ones too, so a track you
/// skipped resumes where its download stopped. Transcodes are kept only
/// once received whole from the start. Entries are keyed by the file's
/// content hash: an edited file has a new hash, so a stale copy is never
/// played. Past `limit`, the least recently played go first; the ones
/// playing or read ahead are never removed.
final class StreamCache: @unchecked Sendable {
    static let defaultLimit: Int64 = 3 << 30

    struct Entry: Codable, Equatable {
        var trackID: UUID
        var quality: StreamQuality
        /// The whole file's size (an original) or the stream's (a transcode).
        var size: Int64
        /// Byte ranges on disk, as [start, end).
        var ranges: [[Int64]]
        var etag: String?
        /// A transcode's trim (§9.2), from its response headers.
        var priming: Int?
        var frames: Int?
        var lastUsed: Date

        var stored: Int64 { ranges.reduce(0) { $0 + max(0, $1[1] - $1[0]) } }
        var isComplete: Bool { stored >= size }
    }

    let directory: URL
    let limit: Int64
    private struct State {
        var entries: [String: Entry] = [:]
        var inUse: [String: Int] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// One index write at a time, so a stale snapshot never lands last.
    private let saving = NSLock()
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL, limit: Int64 = StreamCache.defaultLimit) {
        self.directory = directory
        self.limit = limit
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries = (try? Data(contentsOf: directory.appendingPathComponent("index.json")))
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        // Drop entries whose file is gone, and files nobody indexes (an old
        // per-play download, or a copy written before a crash).
        entries = entries.filter { fm.fileExists(atPath: Self.file(directory, $0.key, $0.value.quality).path) }
        let known = Set(entries.map { Self.file(directory, $0.key, $0.value.quality).lastPathComponent } + ["index.json"])
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !known.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        let loaded = entries
        state.withLock { $0.entries = loaded }
        save()
    }

    /// The cache key for a file's content at a quality, or nil without a
    /// hash (nothing is kept then: there'd be no way to tell it changed).
    static func key(hash: String?, quality: StreamQuality) -> String? {
        guard let hash, !hash.isEmpty else { return nil }
        let safe = String(hash.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        guard !safe.isEmpty else { return nil }
        return "\(safe.prefix(96))-\(quality.rawValue)"
    }

    private static func file(_ dir: URL, _ key: String, _ quality: StreamQuality) -> URL {
        dir.appendingPathComponent(key + (quality == .original ? ".audio" : ".adts"))
    }

    func fileURL(_ key: String, quality: StreamQuality) -> URL { Self.file(directory, key, quality) }

    func entry(_ key: String) -> Entry? { state.withLock { $0.entries[key] } }

    /// Whether a whole copy is here.
    func isComplete(_ key: String) -> Bool { state.withLock { $0.entries[key]?.isComplete ?? false } }

    var totalStored: Int64 { state.withLock { $0.entries.values.reduce(0) { $0 + $1.stored } } }

    // MARK: - In use

    /// The entry is being read or written: it isn't removed to make room.
    func lease(_ key: String) { state.withLock { $0.inUse[key, default: 0] += 1 } }

    func release(_ key: String) {
        state.withLock { s in
            let n = (s.inUse[key] ?? 1) - 1
            s.inUse[key] = n > 0 ? n : nil
        }
    }

    // MARK: - Originals

    /// What's on disk of an original, to read on from; starts an entry if
    /// none (or the one there doesn't match the file). Marks it used.
    func beginOriginal(_ key: String, trackID: UUID, size: Int64) -> (have: IndexSet, etag: String?) {
        let url = fileURL(key, quality: .original)
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        let found: (have: IndexSet, etag: String?)? = state.withLock { s in
            guard var e = s.entries[key], e.size == size, onDisk == size else { return nil }
            e.lastUsed = Date()
            s.entries[key] = e
            var have = IndexSet()
            for r in e.ranges where r[1] > r[0] { have.insert(integersIn: Int(r[0])..<Int(r[1])) }
            return (have, e.etag)
        }
        if let found { return found }
        try? FileManager.default.removeItem(at: url)
        state.withLock {
            $0.entries[key] = Entry(trackID: trackID, quality: .original, size: size, ranges: [], etag: nil, lastUsed: Date())
        }
        // Indexed at once: a file being written is never taken for an orphan.
        save()
        return (IndexSet(), nil)
    }

    /// Records what an original has on disk now. Ignored once the entry is
    /// gone (made available offline, say, while it played).
    func saveOriginal(_ key: String, have: IndexSet, etag: String?) {
        let changed: Bool = state.withLock { s in
            guard var e = s.entries[key] else { return false }
            let ranges = have.rangeView.map { [Int64($0.lowerBound), Int64($0.upperBound)] }
            guard ranges != e.ranges || etag != e.etag else { return false }
            e.ranges = ranges
            e.etag = etag
            s.entries[key] = e
            return true
        }
        if changed { evict(); save() }
    }

    // MARK: - Transcodes

    /// Keeps a transcode received whole from the start.
    func storeTranscode(_ key: String, trackID: UUID, quality: StreamQuality, data: Data, priming: Int, frames: Int?) {
        let url = fileURL(key, quality: quality)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        state.withLock {
            $0.entries[key] = Entry(trackID: trackID, quality: quality, size: Int64(data.count),
                                    ranges: [[0, Int64(data.count)]], etag: nil, priming: priming,
                                    frames: frames, lastUsed: Date())
        }
        evict()
        save()
    }

    /// A whole transcode, if kept. Marks it used.
    func transcode(_ key: String) -> (data: Data, priming: Int, frames: Int?)? {
        guard let e = state.withLock({ s -> Entry? in
            guard var e = s.entries[key], e.isComplete else { return nil }
            e.lastUsed = Date()
            s.entries[key] = e
            return e
        }), let data = try? Data(contentsOf: fileURL(key, quality: e.quality)), Int64(data.count) == e.size else { return nil }
        return (data, e.priming ?? 0, e.frames)
    }

    // MARK: - Removing

    /// Drops every copy of these tracks (they're offline copies now).
    func remove(trackIDs: Set<UUID>) {
        guard !trackIDs.isEmpty else { return }
        let gone: [(String, StreamQuality)] = state.withLock { s in
            let keys = s.entries.filter { trackIDs.contains($0.value.trackID) }.map { ($0.key, $0.value.quality) }
            for (k, _) in keys { s.entries[k] = nil }
            return keys
        }
        guard !gone.isEmpty else { return }
        // Unlinking a file that's being read leaves it readable until closed.
        for (k, q) in gone { try? FileManager.default.removeItem(at: fileURL(k, quality: q)) }
        save()
    }

    /// Least recently played first, until everything fits; never what's in use.
    private func evict() {
        let gone: [(String, StreamQuality)] = state.withLock { s in
            var total = s.entries.values.reduce(0) { $0 + $1.stored }
            guard total > limit else { return [] }
            var out: [(String, StreamQuality)] = []
            for (k, e) in s.entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) where total > limit {
                guard s.inUse[k] == nil else { continue }
                s.entries[k] = nil
                total -= e.stored
                out.append((k, e.quality))
            }
            return out
        }
        for (k, q) in gone { try? FileManager.default.removeItem(at: fileURL(k, quality: q)) }
    }

    private func save() {
        saving.withLock {
            let entries = state.withLock { $0.entries }
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
