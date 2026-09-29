import Foundation

/// The checklist behind the confirmation sheet: a plan's incoming tracks
/// grouped artist → album → track, plus its playlists, with what the user has
/// unticked.
///
/// Shared by both apps so "untick an album" means the same thing on each, and
/// so the grouping and tri-state rules are tested once rather than trusted
/// twice. Pure value type — the sheets hold it in `@State`.
///
/// It records **exclusions**, not inclusions. The default is everything, and a
/// user who changes nothing should produce `.everything` on the wire rather
/// than a list of ten thousand IDs.
struct SyncPickList: Sendable {

    // MARK: - Tree

    struct Track: Identifiable, Sendable {
        let entry: TrackManifestEntry
        /// Set when this track replaces one the receiver already has —
        /// `TrackConflict.differingFields`, joined for display.
        let replaces: String?
        /// The track's own artist when it differs from the album's — a
        /// featured or guest credit — so the row can say so.
        var creditedArtist: String? = nil
        var id: UUID { entry.trackID }
    }

    struct Album: Identifiable, Sendable {
        let id: String
        let title: String
        let tracks: [Track]
        let trackIDs: [UUID]
        let bytes: Int64
    }

    struct Artist: Identifiable, Sendable {
        let id: String
        let name: String
        let albums: [Album]
        let trackIDs: [UUID]
        let bytes: Int64
    }

    struct Playlist: Identifiable, Sendable {
        let entry: PlaylistManifestEntry
        /// True when it replaces a playlist of the same ID on the receiver.
        let replacesExisting: Bool
        var id: UUID { entry.id }
    }

    enum Mark: Sendable, Equatable {
        case all, some, none
    }

    let artists: [Artist]
    let playlists: [Playlist]

    private let allTrackIDs: Set<UUID>
    private let allPlaylistIDs: Set<UUID>
    private let bytesByTrack: [UUID: Int64]

    private(set) var excludedTracks: Set<UUID> = []
    private(set) var excludedPlaylists: Set<UUID> = []

    // MARK: - Building

    static let unknownArtist = "Unknown Artist"
    static let unknownAlbum = "Unknown Album"

    init(plan: SyncPlan) {
        var replacements: [UUID: String] = [:]
        for conflict in plan.trackConflicts {
            replacements[conflict.incoming.trackID] = conflict.differingFields.joined(separator: ", ")
        }
        let tracks = plan.newTracks.map { Track(entry: $0, replaces: nil) }
            + plan.trackConflicts.map { Track(entry: $0.incoming, replaces: replacements[$0.incoming.trackID]) }

        // 1. Albums first, keyed by title *and* folder, never by track artist.
        //    Keying on the track artist splits an EP whose tracks credit
        //    featured artists ("A feat. B") into pieces, and unticking or
        //    ticking the album then misses some of its songs. The folder keeps
        //    two different albums that share a title ("Greatest Hits") apart.
        var albumBuckets: [String: (title: String, tracks: [Track])] = [:]
        for track in tracks {
            let title = Self.displayName(track.entry.album, fallback: Self.unknownAlbum)
            let folder = (track.entry.relativePath as NSString).deletingLastPathComponent
            let key = Self.foldKey(title) + "\u{1F}" + folder
            albumBuckets[key, default: (title, [])].tracks.append(track)
        }

        // 2. Each album is filed under one artist: its album artist if any
        //    track carries one, otherwise the artist most of its tracks credit.
        //    Grouped on a folded key so "Radiohead" and "radiohead " land
        //    together, displayed with the first spelling seen.
        var artistNames: [String: String] = [:]
        var albumsByArtist: [String: [Album]] = [:]
        for (albumKey, bucket) in albumBuckets {
            let artistName = Self.albumArtist(of: bucket.tracks)
            let artistKey = Self.foldKey(artistName)
            if artistNames[artistKey] == nil { artistNames[artistKey] = artistName }

            // Relative path order is disc/track order for any organised
            // library, and a stable order for any other.
            let sorted = bucket.tracks
                .sorted { $0.entry.relativePath < $1.entry.relativePath }
                .map { track -> Track in
                    var track = track
                    let own = Self.displayName(track.entry.artist, fallback: artistName)
                    if Self.foldKey(own) != artistKey { track.creditedArtist = own }
                    return track
                }
            albumsByArtist[artistKey, default: []].append(Album(
                id: artistKey + "\u{1F}" + albumKey,
                title: bucket.title,
                tracks: sorted,
                trackIDs: sorted.map(\.id),
                bytes: sorted.reduce(0) { $0 + $1.entry.fileSize }
            ))
        }

        artists = albumsByArtist.map { artistKey, albums in
            let builtAlbums = albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return Artist(
                id: artistKey,
                name: artistNames[artistKey] ?? Self.unknownArtist,
                albums: builtAlbums,
                trackIDs: builtAlbums.flatMap(\.trackIDs),
                bytes: builtAlbums.reduce(0) { $0 + $1.bytes }
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        playlists = (plan.newPlaylists.map { Playlist(entry: $0, replacesExisting: false) }
                     + plan.playlistConflicts.map { Playlist(entry: $0.incoming, replacesExisting: true) })
            .sorted { $0.entry.name.localizedStandardCompare($1.entry.name) == .orderedAscending }

        allTrackIDs = Set(tracks.map(\.id))
        allPlaylistIDs = Set(playlists.map(\.id))
        bytesByTrack = Dictionary(tracks.map { ($0.id, $0.entry.fileSize) }, uniquingKeysWith: { a, _ in a })
    }

    private static func displayName(_ raw: String?, fallback: String) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// The artist an album is filed under: the most common album-artist tag
    /// among its tracks, else the most common track artist. Ties go to the
    /// alphabetically first, so the result does not depend on track order.
    private static func albumArtist(of tracks: [Track]) -> String {
        func mostCommon(_ names: [String]) -> String? {
            guard !names.isEmpty else { return nil }
            var counts: [String: (name: String, count: Int)] = [:]
            for name in names { counts[foldKey(name), default: (name, 0)].count += 1 }
            return counts.values.max {
                $0.count != $1.count ? $0.count < $1.count : $0.name > $1.name
            }?.name
        }
        let tagged = tracks.compactMap { $0.entry.albumArtist }.map { displayName($0, fallback: "") }.filter { !$0.isEmpty }
        if let name = mostCommon(tagged) { return name }
        let credited = tracks.compactMap { $0.entry.artist }.map { displayName($0, fallback: "") }.filter { !$0.isEmpty }
        return mostCommon(credited) ?? unknownArtist
    }

    private static func foldKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: - Whole library

    /// True while nothing is unticked — the "Entire library" switch.
    var isEverything: Bool { excludedTracks.isEmpty && excludedPlaylists.isEmpty }

    mutating func setEverything(_ included: Bool) {
        excludedTracks = included ? [] : allTrackIDs
        excludedPlaylists = included ? [] : allPlaylistIDs
    }

    // MARK: - Tracks, albums, artists

    /// Tri-state for any group of tracks — an album, an artist, or one track.
    func mark(_ trackIDs: [UUID]) -> Mark {
        let excluded = trackIDs.filter { excludedTracks.contains($0) }.count
        if excluded == 0 { return .all }
        return excluded == trackIDs.count ? .none : .some
    }

    /// Ticking a partly-ticked group ticks all of it, the way Finder and Music
    /// behave. Only a fully-ticked group unticks.
    mutating func toggle(_ trackIDs: [UUID]) {
        if mark(trackIDs) == .all {
            excludedTracks.formUnion(trackIDs)
        } else {
            excludedTracks.subtract(trackIDs)
        }
    }

    func includedCount(of trackIDs: [UUID]) -> Int {
        trackIDs.filter { !excludedTracks.contains($0) }.count
    }

    // MARK: - Playlists

    func isIncluded(playlist id: UUID) -> Bool { !excludedPlaylists.contains(id) }

    mutating func togglePlaylist(_ id: UUID) {
        if excludedPlaylists.contains(id) {
            excludedPlaylists.remove(id)
        } else {
            excludedPlaylists.insert(id)
        }
    }

    // MARK: - Totals

    var selectedTrackCount: Int { allTrackIDs.count - excludedTracks.count }
    var selectedPlaylistCount: Int { allPlaylistIDs.count - excludedPlaylists.count }

    var selectedBytes: Int64 {
        bytesByTrack.reduce(0) { $0 + (excludedTracks.contains($1.key) ? 0 : $1.value) }
    }

    /// Nothing ticked at all — the confirm button should be disabled.
    var isEmptySelection: Bool { selectedTrackCount == 0 && selectedPlaylistCount == 0 }

    // MARK: - Result

    /// What goes on the wire. `.everything` when nothing was unticked.
    var selection: SyncSelection {
        SyncSelection(
            trackIDs: excludedTracks.isEmpty ? nil : allTrackIDs.subtracting(excludedTracks),
            playlistIDs: excludedPlaylists.isEmpty ? nil : allPlaylistIDs.subtracting(excludedPlaylists)
        )
    }
}
