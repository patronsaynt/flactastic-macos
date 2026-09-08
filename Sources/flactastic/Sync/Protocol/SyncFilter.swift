import Foundation

/// Narrows what a sync run covers.
///
/// The default is the whole library; every field here removes something from
/// it. Filters are stored per-peer — a phone with 128 GB and a Mac with a NAS
/// attached want very different sets — and are applied twice: by the **sender**
/// when it builds its manifest, and again by the **receiver** as a sanity bound
/// on what it is willing to accept. The second application is not redundant. A
/// peer that ignores the agreed filter is either buggy or hostile, and either
/// way should not be able to fill the user's disk.
struct SyncFilter: Codable, Sendable, Hashable {

    /// Formats to leave out entirely. Reuses `Library/AudioFileFormat.swift`
    /// so the Settings UI can list exactly the formats the app understands.
    var excludedFormats: Set<AudioFileFormat>

    /// Artists to leave out, keyed by `ArtistResolver.key(for:)` so the match
    /// is diacritic- and case-insensitive and survives the casing differences
    /// that creep in between two independently tagged libraries.
    var excludedArtistKeys: Set<String>

    /// Skip any single file larger than this. `nil` means no cap.
    var maxFileSizeBytes: Int64?

    /// Whether playlists travel at all.
    var includePlaylists: Bool

    /// When non-nil, only these playlists sync. `nil` means all of them.
    var playlistIDAllowlist: Set<UUID>?

    /// Total transfer ceiling for one run. `nil` means no cap. Distinct from
    /// `maxFileSizeBytes`: this is what stops a 400 GB library from being
    /// pushed at a phone by accident.
    var maxTotalTransferBytes: Int64?

    static let unrestricted = SyncFilter()

    init(
        excludedFormats: Set<AudioFileFormat> = [],
        excludedArtistKeys: Set<String> = [],
        maxFileSizeBytes: Int64? = nil,
        includePlaylists: Bool = true,
        playlistIDAllowlist: Set<UUID>? = nil,
        maxTotalTransferBytes: Int64? = nil
    ) {
        self.excludedFormats = excludedFormats
        self.excludedArtistKeys = excludedArtistKeys
        self.maxFileSizeBytes = maxFileSizeBytes
        self.includePlaylists = includePlaylists
        self.playlistIDAllowlist = playlistIDAllowlist
        self.maxTotalTransferBytes = maxTotalTransferBytes
    }

    // MARK: - Codable

    /// Every field is decoded with `decodeIfPresent` and defaulted, matching
    /// the migration discipline in `Library/Playlist.swift`. A filter written
    /// by an older build, or by a peer on an older protocol minor version,
    /// must keep loading.
    private enum CodingKeys: String, CodingKey {
        case excludedFormats, excludedArtistKeys, maxFileSizeBytes
        case includePlaylists, playlistIDAllowlist, maxTotalTransferBytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        excludedFormats       = try c.decodeIfPresent(Set<AudioFileFormat>.self, forKey: .excludedFormats) ?? []
        excludedArtistKeys    = try c.decodeIfPresent(Set<String>.self, forKey: .excludedArtistKeys) ?? []
        maxFileSizeBytes      = try c.decodeIfPresent(Int64.self, forKey: .maxFileSizeBytes)
        includePlaylists      = try c.decodeIfPresent(Bool.self, forKey: .includePlaylists) ?? true
        playlistIDAllowlist   = try c.decodeIfPresent(Set<UUID>.self, forKey: .playlistIDAllowlist)
        maxTotalTransferBytes = try c.decodeIfPresent(Int64.self, forKey: .maxTotalTransferBytes)
    }

    // MARK: - Application

    /// Whether a track survives the filter, judged from manifest data alone so
    /// the receiver can re-apply it without opening any file.
    ///
    /// `artistKey` is passed in rather than derived here to keep this type free
    /// of `ArtistResolver` — the iOS copy of that resolver is a separate file
    /// and the two must not drift into disagreeing about key derivation.
    func allows(format: AudioFileFormat, artistKey: String?, fileSize: Int64) -> Bool {
        if excludedFormats.contains(format) { return false }
        if let artistKey, excludedArtistKeys.contains(artistKey) { return false }
        if let maxFileSizeBytes, fileSize > maxFileSizeBytes { return false }
        return true
    }

    func allows(playlistID: UUID) -> Bool {
        guard includePlaylists else { return false }
        guard let playlistIDAllowlist else { return true }
        return playlistIDAllowlist.contains(playlistID)
    }

    /// True when a proposed transfer exceeds the per-run ceiling.
    func exceedsTotalCap(_ bytes: Int64) -> Bool {
        guard let maxTotalTransferBytes else { return false }
        return bytes > maxTotalTransferBytes
    }
}
