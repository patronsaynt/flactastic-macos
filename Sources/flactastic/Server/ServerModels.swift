import Foundation

// Wire types of FLACtastic Server Protocol v2. Types the Mac already shares
// with the server (TrackManifestEntry, SyncFilter, Playlist, PlayEvent,
// RecentContext, OrganizerProfile) are used directly and not repeated here.

struct ServerInfo: Codable, Sendable {
    let id: UUID
    let name: String
    let `protocol`: String
    let version: String
    let transcoding: Bool

    /// Only major version 2 is spoken here (§4).
    var isCompatible: Bool { `protocol`.split(separator: ".").first == "2" }
}

struct ServerUser: Codable, Sendable, Hashable {
    let id: UUID
    let name: String
    let isAdmin: Bool
}

struct ServerDevice: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let kind: String
    let created: Date
    let lastSeen: Date
    let current: Bool
}

struct LoginResponse: Decodable, Sendable {
    let token: String
    let device: ServerDevice
    let user: ServerUser
}

struct LibraryInfo: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case scanning, ready, offline }
    let libraryID: UUID
    let state: State
    let seq: Int
    let trackCount: Int
    let pendingHashes: Int
    let usedBytes: Int64
    let quotaBytes: Int64?
    let freeBytes: Int64
}

/// A track as the server describes it (§7). Kept as-is in the mirror so the
/// fields the app's `Track` has no room for (hash, size, artwork ID) survive.
struct ServerTrack: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var relativePath: String
    var format: String
    var fileSize: Int64
    var contentHash: String?
    var tagFingerprint: String
    var title: String
    var artist: String?
    var artistIsList: Bool?
    var albumArtist: String?
    var albumArtistIsList: Bool?
    var album: String?
    var trackNumber: Int?
    var discNumber: Int?
    var discTotal: Int?
    var year: Int?
    var genre: String?
    var secondaryGenres: [String]?
    var isCompilation: Bool?
    var isMixCompilation: Bool?
    var label: String?
    var duration: Double?
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?
    var bitrate: Int?
    var frames: Int64?
    var artworkID: String?
    var hasCueSheet: Bool?
    var dateAdded: Date?
    var modified: Date?
    // Only on GET /v2/tracks/{id}.
    var cueSheet: String?
    var lyrics: String?

    /// The app's `Track` for this server track. Its URL is where the offline
    /// copy lives (or would live) under `root`, so relative-path code
    /// (playlists, the Organizer) works unchanged whether or not it's there.
    func appTrack(root: URL) -> Track? {
        guard let format = AudioFileFormat(rawValue: format),
              let path = try? PathSanitizer.sanitizeAudioRelativePath(relativePath) else { return nil }
        var t = Track(
            id: id,
            url: root.appendingPathComponent(path, isDirectory: false),
            title: title,
            artist: artist,
            albumArtist: albumArtist,
            album: album,
            trackNumber: trackNumber,
            duration: duration,
            fileFormat: format,
            sampleRate: sampleRate.map(Double.init),
            bitDepth: bitDepth,
            genre: genre,
            secondaryGenres: secondaryGenres ?? [],
            year: year,
            isCompilation: isCompilation ?? false,
            isMixCompilation: isMixCompilation ?? false,
            dateAdded: dateAdded,
            label: label,
            discNumber: discNumber,
            discTotal: discTotal
        )
        t.artistIsList = artistIsList ?? false
        t.albumArtistIsList = albumArtistIsList ?? false
        t.tagVersion = 2
        t.artworkID = artworkID
        return t
    }

    var manifestEntry: TrackManifestEntry? {
        guard let contentHash, let format = AudioFileFormat(rawValue: format) else { return nil }
        return TrackManifestEntry(
            trackID: id, relativePath: relativePath, fileSize: fileSize, contentHash: contentHash,
            format: format, tagFingerprint: tagFingerprint,
            title: title, artist: artist, album: album, albumArtist: albumArtist
        )
    }
}

struct TracksPage: Decodable, Sendable {
    let tracks: [ServerTrack]
    let deleted: [UUID]
    let seq: Int
    let more: Bool
}

struct ChangesResponse: Decodable, Sendable {
    let seq: Int
    let changed: [String]
}

struct ServerPrefs: Codable, Sendable {
    var streamQuality: String?
    var artistSeparator: String?
    var clients: [String: JSONValue]?
}

/// Any JSON, for the free-form `clients` preference values.
enum JSONValue: Codable, Sendable, Hashable {
    case null, bool(Bool), int(Int), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
