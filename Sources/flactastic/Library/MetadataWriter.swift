import Foundation
import SwiftUI
import CTagLib
import CTagLibHelper

// MARK: - MetadataWriter

/// Writes tag metadata back to source audio files using the TagLib C API.
/// Declared as an `actor` so writes are serialised (no concurrent writes to
/// the same file) and run on the cooperative thread pool, not the main thread.
///
/// Inject via `.environment(\.metadataWriter, …)` and read with
/// `@Environment(\.metadataWriter)` in SwiftUI views.
actor MetadataWriter {

    // MARK: - Public API

    enum ArtworkChange: Sendable {
        /// Leave the existing artwork untouched.
        case unchanged
        /// Remove any embedded artwork from the file.
        case removed
        /// Replace / set artwork with the supplied image data (JPEG or PNG).
        case updated(Data)
    }

    enum WriteError: LocalizedError {
        case fileNotFound(URL)
        case fileOpenFailed(URL)
        case saveFailed(URL)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let url):
                return "File not found: \(url.lastPathComponent)"
            case .fileOpenFailed(let url):
                return "Could not open \"\(url.lastPathComponent)\" for writing. Check file permissions."
            case .saveFailed(let url):
                return "Failed to save changes to \"\(url.lastPathComponent)\"."
            }
        }
    }

    /// Sentinel passed for `albumArtist` to distinguish "leave alone" from
    /// "clear the tag". `.unchanged` skips the write entirely; `.set(nil)` or
    /// `.set("")` clears the ALBUMARTIST tag; `.set("value")` writes a value.
    enum AlbumArtistChange: Sendable {
        case unchanged
        case set(String?)
    }

    /// Sentinel for the COMPILATION tag. `.unchanged` skips the write;
    /// `.set(true)` writes "1"; `.set(false)` clears the tag.
    enum CompilationChange: Sendable {
        case unchanged
        case set(Bool)
    }

    /// Sentinel for the MIXCOMPILATION tag. `.unchanged` skips the write;
    /// `.set(true)` writes "1" and also clears any LYRICS tag (mix
    /// compilations must not carry lyrics); `.set(false)` clears the tag.
    enum MixCompilationChange: Sendable {
        case unchanged
        case set(Bool)
    }

    /// Sentinel for the LABEL tag. `.unchanged` skips the write; `.set(nil)`
    /// or `.set("")` clears it.
    enum LabelChange: Sendable {
        case unchanged
        case set(String?)
    }

    /// Sentinel for the disc tags. `.unchanged` skips the write;
    /// `.set(number: nil, total: nil)` clears them.
    enum DiscChange: Sendable {
        case unchanged
        case set(number: Int?, total: Int?)
    }

    /// Write text tags and optionally artwork to the file at `track.url`.
    ///
    /// - Returns: An updated `Track` value reflecting the written fields.
    ///   The `id`, `url`, `fileFormat`, `sampleRate`, `bitDepth`, and
    ///   `dateAdded` fields are preserved unchanged.
    func write(
        to track: Track,
        title: String,
        artist: String?,
        album: String?,
        year: Int?,
        genre: String?,
        secondaryGenres: [String] = [],
        trackNumber: Int?,
        artworkChange: ArtworkChange = .unchanged,
        albumArtistChange: AlbumArtistChange = .unchanged,
        compilationChange: CompilationChange = .unchanged,
        mixCompilationChange: MixCompilationChange = .unchanged,
        labelChange: LabelChange = .unchanged,
        discChange: DiscChange = .unchanged
    ) throws -> Track {
        let url = track.url

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WriteError.fileNotFound(url)
        }

        guard let file = url.path.withCString({ taglib_file_new($0) }) else {
            throw WriteError.fileOpenFailed(url)
        }
        defer {
            taglib_file_free(file)
            taglib_tag_free_strings()
        }

        guard taglib_file_is_valid(file) != 0 else {
            throw WriteError.fileOpenFailed(url)
        }

        guard let tag = taglib_file_tag(file) else {
            throw WriteError.fileOpenFailed(url)
        }

        // --- Text fields ---
        // Empty string clears a field in TagLib; 0 clears numeric fields.
        title.withCString            { taglib_tag_set_title(tag, $0) }
        (artist      ?? "").withCString { taglib_tag_set_artist(tag, $0) }
        (album       ?? "").withCString { taglib_tag_set_album(tag, $0) }
        // Primary + secondary genres pack into the one GENRE tag string.
        let genreTagString = GenreResolver.join(primary: genre, secondary: secondaryGenres)
        (genreTagString ?? "").withCString { taglib_tag_set_genre(tag, $0) }
        taglib_tag_set_year(tag,  UInt32(max(0, year        ?? 0)))
        taglib_tag_set_track(tag, UInt32(max(0, trackNumber ?? 0)))

        // --- Album artist (via property API / custom helper) ---
        switch albumArtistChange {
        case .unchanged:
            break
        case .set(let value):
            (value ?? "").withCString { taglib_helper_set_album_artist(file, $0) }
        }

        // --- Compilation flag ---
        // Compilation and Mix Compilation are mutually exclusive; whichever is
        // applied here second wins if a caller somehow requests both at once.
        switch compilationChange {
        case .unchanged:
            break
        case .set(let on):
            taglib_helper_set_compilation(file, on ? 1 : 0)
            if on {
                taglib_helper_set_mix_compilation(file, 0)
            }
        }

        // --- Mix Compilation flag ---
        switch mixCompilationChange {
        case .unchanged:
            break
        case .set(let on):
            taglib_helper_set_mix_compilation(file, on ? 1 : 0)
            if on {
                // Turning ON mix compilation clears any existing LYRICS tag in
                // the same save — mix/live-set tracks must not carry a LYRICS
                // tag, and this keeps the file's on-disk state atomic with the
                // toggle flip.
                taglib_helper_set_lyrics(file, "")
                taglib_helper_set_compilation(file, 0)
            }
        }

        // --- Record label ---
        if case .set(let value) = labelChange {
            setProperty(file, "LABEL", value)
        }

        // --- Disc number and total ---
        // FLAC's Vorbis comments keep the total in its own DISCTOTAL field;
        // ID3v2 (TPOS) and MP4 (disk) store both as "1/2" in one.
        if case .set(let number, let total) = discChange {
            let n = number.map(String.init)
            if track.fileFormat == .flac {
                setProperty(file, "DISCNUMBER", n)
                setProperty(file, "DISCTOTAL", n == nil ? nil : total.map(String.init))
                setProperty(file, "TOTALDISCS", nil)
            } else {
                setProperty(file, "DISCNUMBER", n.map { n in total.map { "\(n)/\($0)" } ?? n })
            }
        }

        // --- Artwork ---
        switch artworkChange {
        case .unchanged:
            break
        case .removed:
            taglib_helper_remove_pictures(file)
        case .updated(let data):
            let mime = mimeType(for: data)
            taglib_helper_remove_pictures(file)
            data.withUnsafeBytes { rawBuf in
                guard let ptr = rawBuf.baseAddress else { return }
                mime.withCString { mimePtr in
                    _ = taglib_helper_set_picture(
                        file,
                        ptr.assumingMemoryBound(to: CChar.self),
                        UInt32(data.count),
                        mimePtr
                    )
                }
            }
        }

        // --- Save ---
        guard taglib_file_save(file) != 0 else {
            throw WriteError.saveFailed(url)
        }

        // --- Build updated Track value ---
        var updated = track
        updated.title       = title.isEmpty ? track.title : title
        updated.artist      = artist.flatMap      { $0.isEmpty ? nil : $0 }
        updated.album       = album.flatMap       { $0.isEmpty ? nil : $0 }
        // Re-derive from the string we actually just wrote, not the raw caller
        // input — guarantees `updated` matches what a fresh LibraryScanner read
        // would produce (cap/dedup/case-folding applied consistently).
        let (resolvedGenre, resolvedSecondary) = GenreResolver.split(genreTagString)
        updated.genre           = resolvedGenre
        updated.secondaryGenres = resolvedSecondary
        updated.year        = year
        updated.trackNumber = trackNumber
        switch albumArtistChange {
        case .unchanged:        break
        case .set(let value):
            updated.albumArtist = (value?.isEmpty ?? true) ? nil : value
        }
        switch compilationChange {
        case .unchanged:        break
        case .set(let on):
            updated.isCompilation = on
            if on { updated.isMixCompilation = false }
        }
        switch mixCompilationChange {
        case .unchanged:        break
        case .set(let on):
            updated.isMixCompilation = on
            if on { updated.isCompilation = false }
        }
        if case .set(let value) = labelChange {
            updated.label = (value?.isEmpty ?? true) ? nil : value
        }
        if case .set(let number, let total) = discChange {
            updated.discNumber = number
            updated.discTotal = number == nil ? nil : total
        }
        switch artworkChange {
        case .unchanged:   break
        case .removed:     updated.artwork = nil
        case .updated(let d): updated.artwork = d
        }
        return updated
    }

    /// Writes a GENRE tag (primary plus secondaries) only if the file has
    /// none: the file itself is read first, so a genre set in another app
    /// since the library last read it is never overwritten. Returns the
    /// track with its new genres, or nil if the file already had a genre.
    func writeGenreIfEmpty(to track: Track, primary: String, secondary: [String]) throws -> Track? {
        let url = track.url
        guard FileManager.default.fileExists(atPath: url.path) else { throw WriteError.fileNotFound(url) }
        guard let file = url.path.withCString({ taglib_file_new($0) }) else { throw WriteError.fileOpenFailed(url) }
        defer {
            taglib_file_free(file)
            taglib_tag_free_strings()
        }
        guard taglib_file_is_valid(file) != 0, let tag = taglib_file_tag(file) else { throw WriteError.fileOpenFailed(url) }
        let existing = taglib_tag_genre(tag).map { String(cString: $0) } ?? ""
        guard existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let value = GenreResolver.join(primary: primary, secondary: secondary) else { return nil }
        value.withCString { taglib_tag_set_genre(tag, $0) }
        guard taglib_file_save(file) != 0 else { throw WriteError.saveFailed(url) }
        var updated = track
        let parsed = GenreResolver.split(value)
        updated.genre = parsed.primary
        updated.secondaryGenres = parsed.secondary
        return updated
    }

    /// Write a `LYRICS` tag onto the file at `track.url`. TagLib normalizes
    /// the property name to the format-specific frame (Xiph LYRICS / ID3v2
    /// USLT / MP4 ©lyr / WMA WM/Lyrics). Pass `nil` or `""` to clear.
    /// All other tags are left untouched.
    func writeLyrics(to track: Track, lyrics: String?) throws {
        let url = track.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WriteError.fileNotFound(url)
        }
        guard let file = url.path.withCString({ taglib_file_new($0) }) else {
            throw WriteError.fileOpenFailed(url)
        }
        defer {
            taglib_file_free(file)
            taglib_tag_free_strings()
        }
        guard taglib_file_is_valid(file) != 0 else {
            throw WriteError.fileOpenFailed(url)
        }
        (lyrics ?? "").withCString { taglib_helper_set_lyrics(file, $0) }
        guard taglib_file_save(file) != 0 else {
            throw WriteError.saveFailed(url)
        }
    }

    /// Overwrite *only* the title tag at `url`, leaving every other tag and any
    /// embedded artwork untouched. Used by the playlist rebuild to correct the
    /// title (from Spotify's canonical name) while preserving the album/cover/
    /// year that Lucida embedded from the source — those would otherwise be lost.
    func overrideTitle(at url: URL, title: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WriteError.fileNotFound(url)
        }
        guard let file = url.path.withCString({ taglib_file_new($0) }) else {
            throw WriteError.fileOpenFailed(url)
        }
        defer {
            taglib_file_free(file)
            taglib_tag_free_strings()
        }
        guard taglib_file_is_valid(file) != 0, let tag = taglib_file_tag(file) else {
            throw WriteError.fileOpenFailed(url)
        }
        title.withCString { taglib_tag_set_title(tag, $0) }
        guard taglib_file_save(file) != 0 else {
            throw WriteError.saveFailed(url)
        }
    }

    /// Read the `LYRICS` tag from the file at `track.url`. Returns nil when
    /// the tag is unset. Useful for honoring user-embedded lyrics without a
    /// network roundtrip.
    func readLyrics(from track: Track) throws -> String? {
        let url = track.url
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let file = url.path.withCString({ taglib_file_new($0) }) else { return nil }
        defer {
            taglib_file_free(file)
            taglib_tag_free_strings()
        }
        guard taglib_file_is_valid(file) != 0 else { return nil }
        guard let cstr = taglib_helper_get_lyrics(file) else { return nil }
        defer { free(cstr) }
        let result = String(cString: cstr)
        return result.isEmpty ? nil : result
    }

    /// Write markers as an embedded CUESHEET tag on `track.url`. Pass an empty
    /// array to clear the tag. All other tags are left untouched.
    func writeMarkers(to track: Track, markers: [TrackMarker]) throws {
        let url = track.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WriteError.fileNotFound(url)
        }
        guard let file = url.path.withCString({ taglib_file_new($0) }) else {
            throw WriteError.fileOpenFailed(url)
        }
        defer {
            taglib_file_free(file)
            taglib_tag_free_strings()
        }
        guard taglib_file_is_valid(file) != 0 else {
            throw WriteError.fileOpenFailed(url)
        }
        let cuesheet = markers.isEmpty ? "" : CueSheet.encode(markers: markers, fileName: url.lastPathComponent)
        cuesheet.withCString { taglib_helper_set_cuesheet(file, $0) }
        guard taglib_file_save(file) != 0 else {
            throw WriteError.saveFailed(url)
        }
    }

    /// Read and decode the embedded CUESHEET tag from `track.url`. Returns an
    /// empty array when unset or unparsable.
    func readMarkers(from track: Track) throws -> [TrackMarker] {
        let url = track.url
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let file = url.path.withCString({ taglib_file_new($0) }) else { return [] }
        defer {
            taglib_file_free(file)
            taglib_tag_free_strings()
        }
        guard taglib_file_is_valid(file) != 0 else { return [] }
        guard let cstr = taglib_helper_get_cuesheet(file) else { return [] }
        defer { free(cstr) }
        let raw = String(cString: cstr)
        return raw.isEmpty ? [] : CueSheet.decode(raw)
    }

    // MARK: - Helpers

    /// Writes one text property by name; nil or "" clears it.
    private func setProperty(_ file: UnsafeMutablePointer<TagLib_File>, _ key: String, _ value: String?) {
        key.withCString { k in (value ?? "").withCString { taglib_helper_set_property(file, k, $0) } }
    }

    private func mimeType(for data: Data) -> String {
        let header = data.prefix(4)
        if header.starts(with: [0xFF, 0xD8, 0xFF])       { return "image/jpeg" }
        if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png"  }
        return "image/jpeg" // safe default
    }
}

// MARK: - SwiftUI EnvironmentKey

private struct MetadataWriterKey: EnvironmentKey {
    static let defaultValue = MetadataWriter()
}

extension EnvironmentValues {
    var metadataWriter: MetadataWriter {
        get { self[MetadataWriterKey.self] }
        set { self[MetadataWriterKey.self] = newValue }
    }
}
