import Foundation

/// One cached parse result for an audio file, validated against the file's
/// size and modification date. Artwork bytes are deliberately NOT stored —
/// only whether the file has an embedded picture, so the scanner knows
/// whether re-reading it is worth a file open.
struct TrackMetadataCacheEntry: Codable, Sendable {
    var title: String
    var artist: String?
    var albumArtist: String?
    var album: String?
    var trackNumber: Int?
    var duration: Double?
    var sampleRate: Double?
    var bitDepth: Int?
    var genre: String?
    var secondaryGenres: [String]
    var year: Int?
    var isCompilation: Bool
    var isMixCompilation: Bool
    var hasArtwork: Bool
    /// Codec-refined format (`.m4a` → ALAC vs AAC). Optional so sidecars
    /// written before it existed still decode; `nil` there means an `.m4a`
    /// entry predates refinement and must be re-parsed once.
    var fileFormat: String?
    var fileSize: Int64
    var mtime: Date

    init(track: Track, fileSize: Int64, mtime: Date) {
        title = track.title
        artist = track.artist
        albumArtist = track.albumArtist
        album = track.album
        trackNumber = track.trackNumber
        duration = track.duration
        sampleRate = track.sampleRate
        bitDepth = track.bitDepth
        genre = track.genre
        secondaryGenres = track.secondaryGenres
        year = track.year
        isCompilation = track.isCompilation
        isMixCompilation = track.isMixCompilation
        hasArtwork = track.artwork != nil
        fileFormat = track.fileFormat.rawValue
        self.fileSize = fileSize
        self.mtime = mtime
    }

    /// True when the file on disk still matches the state this entry was
    /// built from. The mtime tolerance absorbs Codable's Date round-trip.
    func isValid(forFileAt path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let modified = attrs[.modificationDate] as? Date else { return false }
        return size == fileSize && abs(modified.timeIntervalSince(mtime)) < 0.001
    }

    /// False for `.m4a` entries cached before codec refinement — they'd keep
    /// every AAC file labeled ALAC until the file itself changed.
    func hasFormat(forFileAt url: URL) -> Bool {
        fileFormat != nil || url.pathExtension.lowercased() != "m4a"
    }

    /// Hydrates every field this entry covers. `id`, `url`, `dateAdded`, and
    /// `artwork` are deliberately untouched — the first three come from the
    /// cheap scan, artwork is re-read from the file. `fileFormat` overrides
    /// the scan's extension guess only when the entry recorded one.
    func apply(to track: inout Track) {
        if let fileFormat, let format = AudioFileFormat(rawValue: fileFormat) {
            track.fileFormat = format
        }
        track.title = title
        track.artist = artist
        track.albumArtist = albumArtist
        track.album = album
        track.trackNumber = trackNumber
        track.duration = duration
        track.sampleRate = sampleRate
        track.bitDepth = bitDepth
        track.genre = genre
        track.secondaryGenres = secondaryGenres
        track.year = year
        track.isCompilation = isCompilation
        track.isMixCompilation = isMixCompilation
    }
}

/// Sidecar cache (`<root>/.flactastic/metadata-cache.json`, same pattern as
/// `track-ids.json`) that lets a relaunch skip the per-file metadata cost for
/// unchanged files. Without it, every launch re-opens every audio file up to
/// four times (TagLib tags, TagLib bit depth, AVURLAsset duration,
/// AVAudioFile format); with it, an unchanged file costs one `stat` plus one
/// TagLib open for the embedded picture (zero opens when it has none).
///
/// Purely derived data: a size/mtime mismatch falls through to the full parse
/// path, and deleting the sidecar restores pre-cache behavior exactly.
enum TrackMetadataCache {
    static func sidecarURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(".flactastic", isDirectory: true)
            .appendingPathComponent("metadata-cache.json")
    }

    static func relativePath(for url: URL, rootPath: String) -> String {
        String(url.path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
    }

    /// Blocking read + decode — call off the main actor. Any failure just
    /// means an empty cache (i.e. a full parse, today's behavior).
    static func load(rootURL: URL) -> [String: TrackMetadataCacheEntry] {
        guard let data = try? Data(contentsOf: sidecarURL(rootURL: rootURL)) else { return [:] }
        return (try? JSONDecoder().decode([String: TrackMetadataCacheEntry].self, from: data)) ?? [:]
    }

    /// Stats every track's file and atomically rewrites the sidecar.
    /// Blocking — call off the main actor, once per completed scan batch.
    /// Must run while tracks still hold their parsed artwork (before any
    /// artwork offloading) so `hasArtwork` is recorded correctly.
    static func rebuild(from tracks: [Track], rootURL: URL) {
        let rootPath = rootURL.path
        var entries: [String: TrackMetadataCacheEntry] = [:]
        entries.reserveCapacity(tracks.count)
        let fm = FileManager.default
        for track in tracks {
            guard track.url.path.hasPrefix(rootPath) else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: track.url.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            let rel = relativePath(for: track.url, rootPath: rootPath)
            entries[rel] = TrackMetadataCacheEntry(track: track, fileSize: size, mtime: mtime)
        }
        do {
            let url = sidecarURL(rootURL: rootURL)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[TrackMetadataCache] Failed to save sidecar: \(error)")
        }
    }
}
