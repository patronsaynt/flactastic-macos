import Foundation

struct Track: Sendable, Identifiable, Hashable {
    let id: UUID
    let url: URL
    var title: String
    var artist: String?
    var albumArtist: String?
    var album: String?
    var trackNumber: Int?
    var duration: TimeInterval?
    var artwork: Data?
    var fileFormat: AudioFileFormat
    var sampleRate: Double?
    var bitDepth: Int?
    var genre: String?
    /// Up to `GenreResolver.maxSecondaryCount` additional genres beyond the
    /// primary `genre`. Packed into the same single GENRE tag string on disk
    /// via `GenreResolver` — there is no separate file tag for these. Defaults
    /// to empty for tracks/files that predate the feature.
    var secondaryGenres: [String] = []
    var year: Int?
    /// Mirrors the file's COMPILATION tag (Xiph COMPILATION / ID3v2 TCMP /
    /// MP4 cpil). When true the album this track belongs to is treated as a
    /// compilation: it does NOT bucket under any single artist's own releases,
    /// but each track-level performer still picks it up under "Appears On".
    var isCompilation: Bool = false
    /// Marks this track as a mix / live set / radio show / concert recording
    /// rather than a conventional song. Only user-settable when `duration`
    /// exceeds 600s (10 minutes) — see TrackMetadataEditorView. When true,
    /// FLACtastic must not fetch or embed LYRICS for this track, and instead
    /// surfaces user-authored chapter/track markers (stored as an embedded
    /// CUESHEET tag, loaded lazily — see CueSheet.swift / MetadataWriter.readMarkers).
    var isMixCompilation: Bool = false
    /// Filesystem-derived timestamp for when this track's file appeared in the
    /// library folder. Prefers the APFS "added to directory" timestamp when
    /// available, otherwise falls back to file creation / modification.
    var dateAdded: Date?
    /// The record label (LABEL tag: Xiph LABEL / ID3v2 TPUB / MP4 LABEL).
    /// Shown at the foot of the album page; edited per album.
    var label: String?
    /// Which disc of a multi-disc release this track is on (DISCNUMBER), and
    /// how many discs the release has (DISCTOTAL, or the "/2" of "1/2").
    /// Nil when untagged, which reads as a single-disc album.
    var discNumber: Int?
    var discTotal: Int?
    /// FLACTASTIC_TAGVERSION from the file: 2 once the app has written its
    /// multi-value fields as real lists (ARTISTS, native GENRE). Nil before.
    var tagVersion: Int?
    /// True when `artist` / `albumArtist` came from a real list (a plural tag,
    /// native multi-values or matching MusicBrainz IDs) rather than a single
    /// string, so it's never split heuristically.
    var artistIsList = false
    var albumArtistIsList = false
    /// A server track's picture (protocol v2 §9.3), fetched by this ID.
    /// Nil for local files, whose picture is read from the file.
    var artworkID: String?

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        duration: TimeInterval? = nil,
        artwork: Data? = nil,
        fileFormat: AudioFileFormat,
        sampleRate: Double? = nil,
        bitDepth: Int? = nil,
        genre: String? = nil,
        secondaryGenres: [String] = [],
        year: Int? = nil,
        isCompilation: Bool = false,
        isMixCompilation: Bool = false,
        dateAdded: Date? = nil,
        label: String? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.trackNumber = trackNumber
        self.duration = duration
        self.artwork = artwork
        self.fileFormat = fileFormat
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.genre = genre
        self.secondaryGenres = secondaryGenres
        self.year = year
        self.isCompilation = isCompilation
        self.isMixCompilation = isMixCompilation
        self.dateAdded = dateAdded
        self.label = label
        self.discNumber = discNumber
        self.discTotal = discTotal
    }

    static func makeFromURL(_ url: URL) -> Track? {
        guard let format = AudioFileFormat.classify(url) else { return nil }
        let title = url.deletingPathExtension().lastPathComponent
        return Track(url: url, title: title, fileFormat: format)
    }
}

extension Track {
    /// A copy with a new identity, location, format, or date added, and every
    /// other field carried over. The one place a Track is rebuilt field by
    /// field, so a new field can't be dropped by one copy path and not another.
    func rebuilt(id: UUID? = nil, url: URL? = nil, fileFormat: AudioFileFormat? = nil, dateAdded: Date?? = nil) -> Track {
        var copy = Track(
            id: id ?? self.id,
            url: url ?? self.url,
            title: title,
            artist: artist,
            albumArtist: albumArtist,
            album: album,
            trackNumber: trackNumber,
            duration: duration,
            artwork: artwork,
            fileFormat: fileFormat ?? self.fileFormat,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            genre: genre,
            secondaryGenres: secondaryGenres,
            year: year,
            isCompilation: isCompilation,
            isMixCompilation: isMixCompilation,
            dateAdded: dateAdded ?? self.dateAdded,
            label: label,
            discNumber: discNumber,
            discTotal: discTotal
        )
        copy.tagVersion = tagVersion
        copy.artistIsList = artistIsList
        copy.albumArtistIsList = albumArtistIsList
        copy.artworkID = artworkID
        return copy
    }

    /// Returns a copy of this track with a freshly-generated UUID. Used when enqueuing
    /// a track that may already appear in the queue, so the two instances can be tracked
    /// and displayed independently.
    func withNewID() -> Track {
        rebuilt(id: UUID())
    }

    /// Returns a copy of this track pointing at `newURL`, with every other
    /// field (including its stable ID) carried over. Used after a file move;
    /// the format is re-derived from the new extension when recognizable.
    func withURL(_ newURL: URL) -> Track {
        rebuilt(url: newURL, fileFormat: AudioFileFormat.classify(newURL, keeping: fileFormat))
    }
}

extension Array where Element == Track {
    /// Sort tracks by (album, disc, trackNumber, title) with stable fallbacks for missing metadata.
    func sortedForLibrary() -> [Track] {
        sorted { a, b in
            let albumA = a.album ?? ""
            let albumB = b.album ?? ""
            if albumA != albumB { return albumA.localizedStandardCompare(albumB) == .orderedAscending }
            let discA = a.discNumber ?? 1
            let discB = b.discNumber ?? 1
            if discA != discB { return discA < discB }
            let tnA = a.trackNumber ?? Int.max
            let tnB = b.trackNumber ?? Int.max
            if tnA != tnB { return tnA < tnB }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}
