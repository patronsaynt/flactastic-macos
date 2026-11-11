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

    // MARK: - Server library

    /// Set while a server profile is the library: tag writes become `PATCH`
    /// requests (§10) instead of file writes.
    private(set) var server: ServerTagEditor?

    func setServer(_ editor: ServerTagEditor?) { server = editor }

    /// Marks writes the user reviewed in an editor. Only those reach a
    /// server, with one exception: fetched lyrics, which the user opts into
    /// with Save Lyrics. Other background writers (found genres, tag
    /// upgrades) are refused there.
    @TaskLocal static var isUserEdit = false

    private func serverEditor() throws -> ServerTagEditor? {
        guard let server else { return nil }
        guard Self.isUserEdit else { throw WriteError.serverLibrary }
        return server
    }

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
        case serverLibrary

        var errorDescription: String? {
            switch self {
            case .serverLibrary:
                return "Tags on the server are changed from the editors."

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
    ) async throws -> Track {
        if let server = try serverEditor() {
            return try await server.apply(TagEdit.from(
                track, title: title, artist: artist, album: album, year: year, genre: genre,
                secondaryGenres: secondaryGenres, trackNumber: trackNumber, artwork: artworkChange,
                albumArtist: albumArtistChange, compilation: compilationChange, mix: mixCompilationChange,
                label: labelChange, disc: discChange), to: track)
        }
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
        (album       ?? "").withCString { taglib_tag_set_album(tag, $0) }
        taglib_tag_set_year(tag,  UInt32(max(0, year        ?? 0)))
        taglib_tag_set_track(tag, UInt32(max(0, trackNumber ?? 0)))

        // --- Artist, album artist and genre, as real lists ---
        var albumArtistValue: String??
        if case .set(let value) = albumArtistChange { albumArtistValue = .some(value) }
        Self.writeMultiValueFields(file, artist: .some(artist), albumArtist: albumArtistValue,
                                   genres: (genre, secondaryGenres))

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
        // Artist, album artist and genre are read back from the tags as they
        // now stand, through the scanner's own code, so `updated` is exactly
        // what a fresh LibraryScanner read will produce.
        let fields = LibraryScanner.multiValueFields(file, tag: tag)
        var updated = track
        updated.title       = title.isEmpty ? track.title : title
        updated.artist      = fields.artist.value
        updated.artistIsList = fields.artist.isList
        updated.album       = album.flatMap       { $0.isEmpty ? nil : $0 }
        updated.genre           = fields.genres.primary
        updated.secondaryGenres = fields.genres.secondary
        updated.tagVersion  = fields.tagVersion
        updated.year        = year
        updated.trackNumber = trackNumber
        switch albumArtistChange {
        case .unchanged:        break
        case .set:
            updated.albumArtist = fields.albumArtist.value
            updated.albumArtistIsList = fields.albumArtist.isList
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
        guard GenreResolver.join(primary: primary, secondary: secondary) != nil else { return nil }
        // The field is empty, so this only adds: genres as native values.
        Self.writeGenres(file, primary: primary, secondary: secondary)
        guard taglib_file_save(file) != 0 else { throw WriteError.saveFailed(url) }
        var updated = track
        let parsed = MultiValueParser.storedGenres(native: LibraryScanner.propertyList(file, "GENRE"))
        updated.genre = parsed.primary
        updated.secondaryGenres = parsed.secondary
        return updated
    }

    /// Write a `LYRICS` tag onto the file at `track.url`. TagLib normalizes
    /// the property name to the format-specific frame (Xiph LYRICS / ID3v2
    /// USLT / MP4 ©lyr / WMA WM/Lyrics). Pass `nil` or `""` to clear.
    /// All other tags are left untouched.
    func writeLyrics(to track: Track, lyrics: String?) async throws {
        if let server {
            var edit = TagEdit()
            edit.fields["lyrics"] = (lyrics ?? "").isEmpty ? .null : .string(lyrics!)
            _ = try await server.apply(edit, to: track)
            return
        }
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
    func readLyrics(from track: Track) async throws -> String? {
        // A server track's lyrics come from the server, unless a verified
        // offline copy is here: then from it, so they work offline.
        if let server, !server.hasCurrentCopy(track) {
            return try await server.detail(track).lyrics.flatMap { $0.isEmpty ? nil : $0 }
        }
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
    func writeMarkers(to track: Track, markers: [TrackMarker]) async throws {
        if let server = try serverEditor() {
            var edit = TagEdit()
            edit.fields["cueSheet"] = markers.isEmpty ? .null
                : .string(CueSheet.encode(markers: markers, fileName: track.url.lastPathComponent))
            _ = try await server.apply(edit, to: track)
            return
        }
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
    func readMarkers(from track: Track) async throws -> [TrackMarker] {
        if let server, !server.hasCurrentCopy(track) {
            return (try await server.detail(track).cueSheet).map(CueSheet.decode) ?? []
        }
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

    // MARK: - Multi-value fields

    /// The FLACTASTIC_TAGVERSION written once a file's artist, album artist
    /// and genre are stored as real lists.
    static let currentTagVersion = 2

    /// Writes artist, album artist and genre to an open file as real lists,
    /// then marks it FLACTASTIC_TAGVERSION=2. Doesn't save. Pass `nil` for a
    /// field to leave it alone; `.some(nil)` clears it.
    ///
    /// Credits ("A ; B" as the editor joins them): the singular tag keeps the
    /// display string, and the plural tag (ARTISTS / ALBUMARTISTS) holds one
    /// value per artist when there are two or more. A singular tag that
    /// already reads as the same list is left as it is, so another tagger's
    /// "A feat. B" survives next to the plural tag. Genres are written as
    /// repeated native values. Every list is read back; a container that
    /// drops it gets the joined `" ; "` string instead.
    static func writeMultiValueFields(
        _ file: UnsafeMutablePointer<TagLib_File>,
        artist: String??,
        albumArtist: String??,
        genres: (primary: String?, secondary: [String])?,
        appendOnly: Bool = false,
        separator: String? = nil
    ) {
        let separator = separator ?? MultiValueParser.preferredDisplaySeparator
        if let artist {
            writeCredit(file, singular: "ARTIST", plural: "ARTISTS", value: artist, appendOnly: appendOnly, separator: separator)
        }
        if let albumArtist {
            writeCredit(file, singular: "ALBUMARTIST", plural: "ALBUMARTISTS", value: albumArtist, appendOnly: appendOnly, separator: separator)
        }
        if let genres, !appendOnly { writeGenres(file, primary: genres.primary, secondary: genres.secondary) }
        setList(file, "FLACTASTIC_TAGVERSION", [String(currentTagVersion)])
    }

    /// One credit field. The plural tag holds the list; the singular tag is a
    /// display string for people and other players, rewritten only when the
    /// artists change: joined with the separator the file already uses, or
    /// the user's chosen one when it has none. `appendOnly` (Upgrade Tags)
    /// never touches the singular tag at all, only adds the plural.
    private static func writeCredit(
        _ file: UnsafeMutablePointer<TagLib_File>, singular: String, plural: String, value: String?,
        appendOnly: Bool, separator preferred: String
    ) {
        let desired = MultiValueParser.values(ofStored: value)
        let currentSingular = LibraryScanner.propertyList(file, singular)
        let currentPlural = LibraryScanner.propertyList(file, plural)
        // Native repeated values already hold exactly this list (another
        // tagger's ARTIST=A, ARTIST=B): that's the best form there is.
        if currentSingular.count > 1, MultiValueParser.normalize(currentSingular) == desired { return }

        if appendOnly {
            guard desired.count > 1, MultiValueParser.normalize(currentPlural) != desired else { return }
            setList(file, plural, desired)
            if LibraryScanner.propertyList(file, plural) != desired { setList(file, plural, []) }
            return
        }

        guard !desired.isEmpty else {
            setList(file, singular, [])
            setList(file, plural, [])
            return
        }
        let current = MultiValueParser.storedCredit(plural: currentPlural, native: currentSingular)
        let currentValues = MultiValueParser.values(ofStored: current.value)
        var display: String?
        if currentValues != desired || currentSingular.count != 1 {
            display = desired.count == 1
                ? (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                : desired.joined(separator: displaySeparator(existing: currentSingular, currentValues: currentValues,
                                                             desired: desired, preferred: preferred))
            setList(file, singular, display.map { [$0] } ?? [])
        }
        if desired.count > 1 {
            if MultiValueParser.normalize(currentPlural) != desired {
                setList(file, plural, desired)
                if LibraryScanner.propertyList(file, plural) != desired {
                    // The container can't hold the plural: the singular must
                    // then carry the list itself, so it falls back to " ; ".
                    setList(file, plural, [])
                    if let display, MultiValueParser.values(ofStored: display) != desired {
                        setList(file, singular, [MultiValueParser.joinList(desired)])
                    }
                }
            }
        } else if !currentPlural.isEmpty {
            setList(file, plural, [])
        }
    }

    /// The separator for a rewritten display string: the one the file's
    /// current string uses between artists, when it was really a list (or the
    /// new list confirms its parts are separate artists), else `preferred`.
    private static func displaySeparator(existing: [String], currentValues: [String], desired: [String], preferred: String) -> String {
        guard existing.count == 1 else { return preferred }
        let raw = existing[0]
        let parts = currentValues.count > 1 ? currentValues : MultiValueParser.normalize(MultiValueParser.splitAmbiguous(raw))
        let isList = currentValues.count > 1
            || (parts.count > 1 && parts.allSatisfy { p in desired.contains { $0.caseInsensitiveCompare(p) == .orderedSame } })
        guard isList, let kept = MultiValueParser.separator(in: raw, joining: parts) else { return preferred }
        return kept
    }

    private static func writeGenres(_ file: UnsafeMutablePointer<TagLib_File>, primary: String?, secondary: [String]) {
        let joined = GenreResolver.join(primary: primary, secondary: secondary)
        let desired = MultiValueParser.values(ofStored: joined)
        // Already stored as these exact native values: leave it.
        if LibraryScanner.propertyList(file, "GENRE") == desired { return }
        setList(file, "GENRE", desired)
        if desired.count > 1, LibraryScanner.propertyList(file, "GENRE") != desired {
            setList(file, "GENRE", joined.map { [$0] } ?? [])
        }
    }

    /// Replaces every value of `key` with `values`; empty removes the key.
    private static func setList(_ file: UnsafeMutablePointer<TagLib_File>, _ key: String, _ values: [String]) {
        key.withCString { k in
            guard let first = values.first else {
                taglib_property_set(file, k, nil)
                return
            }
            first.withCString { taglib_property_set(file, k, $0) }
            for value in values.dropFirst() {
                value.withCString { taglib_property_set_append(file, k, $0) }
            }
        }
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
