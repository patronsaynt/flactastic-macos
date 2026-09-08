import Foundation

/// `AudioFileFormat` is a `String`-backed enum, so this is all the Codable
/// conformance it needs. Declared here rather than on the type itself to keep
/// `Library/AudioFileFormat.swift` byte-identical with the iOS copy.
extension AudioFileFormat: Codable {}

// MARK: - Track entry

/// One track as described to a peer.
///
/// Identity is `trackID` — the `com.flactastic.trackID` xattr that
/// `TrackIDStore` maintains and that survives moves, renames, and Organizer
/// runs on both platforms. `contentHash` is the fallback: xattrs are lost
/// crossing FAT volumes, zip archives, and some cloud providers, so two copies
/// of the same file can legitimately carry different IDs. Matching on the hash
/// recovers that case instead of transferring a file the peer already has.
///
/// The display fields exist purely so the conflict sheet can name what it is
/// about to overwrite without the receiving side having to look anything up.
struct TrackManifestEntry: Codable, Sendable, Hashable, Identifiable {
    let trackID: UUID
    /// Path relative to the sender's library root. **Untrusted** on receipt —
    /// always goes through `PathSanitizer` before it touches the filesystem.
    let relativePath: String
    let fileSize: Int64
    /// Lowercase hex SHA-256 of the whole file.
    let contentHash: String
    let format: AudioFileFormat
    /// SHA-256 over the normalised tag set — see `TagFingerprint`. Two files
    /// with the same `trackID` but different fingerprints are a metadata
    /// conflict the user must approve.
    let tagFingerprint: String

    // Display-only, never used for matching.
    let title: String
    let artist: String?
    let album: String?

    var id: UUID { trackID }
}

// MARK: - Playlist entry

/// One playlist as described to a peer. `Playlist` itself is byte-identical
/// across the macOS and iOS repos, so the playlist body transfers as its own
/// existing `Codable` JSON — this is only the summary used for diffing.
struct PlaylistManifestEntry: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let dateCreated: Date
    let entryCount: Int
    /// SHA-256 over the ordered `(trackID, relativePath)` pairs. Order is part
    /// of a playlist's meaning, so a reorder is a genuine change.
    let contentHash: String
}

// MARK: - Manifest

/// The complete description of one side's library, after that side's filters
/// have been applied.
struct LibraryManifest: Codable, Sendable, Hashable {
    let deviceID: UUID
    let generatedAt: Date
    let tracks: [TrackManifestEntry]
    let playlists: [PlaylistManifestEntry]

    /// Never includes listening history, settings, or credentials — see the
    /// spec. Anything added here becomes something the user's other devices
    /// learn about them.
    init(deviceID: UUID, generatedAt: Date = .now,
         tracks: [TrackManifestEntry], playlists: [PlaylistManifestEntry]) {
        self.deviceID = deviceID
        self.generatedAt = generatedAt
        self.tracks = tracks
        self.playlists = playlists
    }

    var tracksByID: [UUID: TrackManifestEntry] {
        Dictionary(tracks.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var tracksByContentHash: [String: TrackManifestEntry] {
        Dictionary(tracks.map { ($0.contentHash, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var playlistsByID: [UUID: PlaylistManifestEntry] {
        Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - Conflicts

/// A track the receiver already has, whose tags differ from the sender's.
///
/// The transfer overwrites the file wholesale, so `differingFields` is
/// presentational: it tells the user *why* this row is in the list. There is no
/// field-level merge — the user asked for an explicit overwrite prompt rather
/// than silent reconciliation.
struct TrackConflict: Codable, Sendable, Hashable, Identifiable {
    let incoming: TrackManifestEntry
    let existing: TrackManifestEntry
    let differingFields: [String]

    var id: UUID { incoming.trackID }
}

struct PlaylistConflict: Codable, Sendable, Hashable, Identifiable {
    let incoming: PlaylistManifestEntry
    let existing: PlaylistManifestEntry

    var id: UUID { incoming.id }
}

// MARK: - Plan

/// What a sync run would do, computed by the **receiving** side and shown to
/// the user before a single byte moves.
///
/// The receiver recomputes this from its own state before executing, and never
/// trusts the copy the sender echoes back. The version the user approved and
/// the version that runs must agree, which `planHash` lets both sides check.
struct SyncPlan: Codable, Sendable, Hashable {
    let direction: SyncDirection
    /// Files the receiver does not have at all.
    let newTracks: [TrackManifestEntry]
    /// Files the receiver has, with differing tags — these get overwritten.
    let trackConflicts: [TrackConflict]
    let newPlaylists: [PlaylistManifestEntry]
    let playlistConflicts: [PlaylistConflict]

    var allIncomingTracks: [TrackManifestEntry] {
        newTracks + trackConflicts.map(\.incoming)
    }

    var totalTransferBytes: Int64 {
        allIncomingTracks.reduce(0) { $0 + $1.fileSize }
    }

    var overwriteCount: Int { trackConflicts.count + playlistConflicts.count }

    var isEmpty: Bool {
        newTracks.isEmpty && trackConflicts.isEmpty
            && newPlaylists.isEmpty && playlistConflicts.isEmpty
    }

    /// Stable digest of everything this plan would change, so the approval the
    /// user gave can be tied to the work that actually runs.
    var planHash: String {
        var parts: [String] = [direction.rawValue]
        parts += newTracks.map { "n:\($0.trackID.uuidString):\($0.contentHash)" }.sorted()
        parts += trackConflicts.map { "c:\($0.incoming.trackID.uuidString):\($0.incoming.contentHash)" }.sorted()
        parts += newPlaylists.map { "p:\($0.id.uuidString):\($0.contentHash)" }.sorted()
        parts += playlistConflicts.map { "q:\($0.incoming.id.uuidString):\($0.incoming.contentHash)" }.sorted()
        return ContentHasher.hexDigest(of: Data(parts.joined(separator: "\n").utf8))
    }
}
