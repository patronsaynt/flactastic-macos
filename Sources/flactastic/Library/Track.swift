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
        dateAdded: Date? = nil
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
    }

    static func makeFromURL(_ url: URL) -> Track? {
        guard let format = AudioFileFormat.classify(url) else { return nil }
        let title = url.deletingPathExtension().lastPathComponent
        return Track(url: url, title: title, fileFormat: format)
    }
}

extension Track {
    /// Returns a copy of this track with a freshly-generated UUID. Used when enqueuing
    /// a track that may already appear in the queue, so the two instances can be tracked
    /// and displayed independently.
    func withNewID() -> Track {
        Track(
            id: UUID(),
            url: url,
            title: title,
            artist: artist,
            albumArtist: albumArtist,
            album: album,
            trackNumber: trackNumber,
            duration: duration,
            artwork: artwork,
            fileFormat: fileFormat,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            genre: genre,
            secondaryGenres: secondaryGenres,
            year: year,
            isCompilation: isCompilation,
            isMixCompilation: isMixCompilation,
            dateAdded: dateAdded
        )
    }
}

extension Track {
    /// Returns a copy of this track pointing at `newURL`, with every other
    /// field (including its stable ID) carried over. Used after a file move;
    /// the format is re-derived from the new extension when recognizable.
    func withURL(_ newURL: URL) -> Track {
        Track(
            id: id,
            url: newURL,
            title: title,
            artist: artist,
            albumArtist: albumArtist,
            album: album,
            trackNumber: trackNumber,
            duration: duration,
            artwork: artwork,
            fileFormat: AudioFileFormat.classify(newURL, keeping: fileFormat),
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            genre: genre,
            secondaryGenres: secondaryGenres,
            year: year,
            isCompilation: isCompilation,
            isMixCompilation: isMixCompilation,
            dateAdded: dateAdded
        )
    }
}

extension Array where Element == Track {
    /// Sort tracks by (album, trackNumber, title) with stable fallbacks for missing metadata.
    func sortedForLibrary() -> [Track] {
        sorted { a, b in
            let albumA = a.album ?? ""
            let albumB = b.album ?? ""
            if albumA != albumB { return albumA.localizedStandardCompare(albumB) == .orderedAscending }
            let tnA = a.trackNumber ?? Int.max
            let tnB = b.trackNumber ?? Int.max
            if tnA != tnB { return tnA < tnB }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}
