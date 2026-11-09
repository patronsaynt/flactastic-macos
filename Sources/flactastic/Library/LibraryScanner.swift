import Foundation
import AVFoundation
import CTagLib
import CTagLibHelper

actor LibraryScanner {
    enum ScanError: Error {
        case rootNotFound
        case rootNotReadable
    }

    func scan(root: URL) throws -> [Track] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ScanError.rootNotFound
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .nameKey,
            .addedToDirectoryDateKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ScanError.rootNotReadable
        }

        var tracks: [Track] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile != true { continue }
            if var track = Track.makeFromURL(url) {
                // Prefer APFS "added to directory" (the true "date added" a
                // user expects in a library view), fall back to creation, then
                // modification. Missing timestamps are tolerated — sorts push
                // them to the end.
                track.dateAdded = values?.addedToDirectoryDate
                    ?? values?.creationDate
                    ?? values?.contentModificationDate
                tracks.append(track)
            }
        }
        return tracks.sortedForLibrary()
    }

    /// Loads metadata for a single track. Tag fields (title/artist/album/etc.) are
    /// read via TagLib — the same library used for writes — so edits always round-trip
    /// correctly without relying on AVFoundation's metadata cache. Audio format
    /// properties (duration, sample rate, bit depth) still come from AVFoundation.
    ///
    /// When `cached` is passed and still matches the file on disk (size +
    /// mtime), the parse is skipped entirely: fields hydrate from the cache
    /// and only the embedded picture is re-read (a single TagLib open — or
    /// none at all when the cache says the file has no artwork). A mismatch
    /// falls through to the full parse below.
    ///
    /// Cache hits run off the actor, so the store's eight-wide task group
    /// reads covers in parallel; on the actor they queued one by one. A full
    /// parse stays on it: TagLib's tag strings live in one global list
    /// (`taglib_tag_free_strings`), which isn't safe to share across threads.
    nonisolated func loadMetadata(for track: Track, cached: TrackMetadataCacheEntry? = nil) async -> Track {
        if let cached, cached.isValid(forFileAt: track.url.path), cached.hasFormat(forFileAt: track.url) {
            var updated = track
            cached.apply(to: &updated)
            if cached.hasArtwork, let picture = Self.readPicture(at: track.url) {
                updated.artwork = picture
            }
            return updated
        }
        return await parse(track)
    }

    /// The embedded cover alone. Uses no tag strings (the picture comes back
    /// in its own allocation), so it's safe to run on several threads at once.
    private nonisolated static func readPicture(at url: URL) -> Data? {
        url.path.withCString { pathPtr in
            guard let file = taglib_file_new(pathPtr) else { return nil }
            defer { taglib_file_free(file) }
            guard taglib_file_is_valid(file) != 0 else { return nil }
            var picSize: UInt32 = 0
            guard let picBytes = taglib_helper_read_picture(file, &picSize) else { return nil }
            defer { free(picBytes) }
            return picSize > 0 ? Data(bytes: picBytes, count: Int(picSize)) : nil
        }
    }

    private func parse(_ track: Track) async -> Track {
        var updated = track

        // --- Tag fields via TagLib (bypasses AVFoundation metadata cache) ---
        track.url.path.withCString { pathPtr in
            guard let file = taglib_file_new(pathPtr) else { return }
            defer {
                taglib_file_free(file)
                taglib_tag_free_strings()
            }
            guard taglib_file_is_valid(file) != 0,
                  let tag = taglib_file_tag(file) else { return }

            if let ptr = taglib_tag_title(tag), ptr.pointee != 0 {
                updated.title = String(cString: ptr)
            }
            if let ptr = taglib_tag_album(tag), ptr.pointee != 0 {
                updated.album = String(cString: ptr)
            }

            // Artist, album artist and genre come through the property map,
            // which keeps multi-values as real lists. The basic tag API is the
            // fallback for an empty list: on an MP3 it also reads ID3v1, which
            // the property map skips when an ID3v2 tag exists.
            let fields = Self.multiValueFields(file, tag: tag)
            updated.artist = fields.artist.value
            updated.artistIsList = fields.artist.isList
            updated.albumArtist = fields.albumArtist.value
            updated.albumArtistIsList = fields.albumArtist.isList
            updated.genre = fields.genres.primary
            updated.secondaryGenres = fields.genres.secondary
            updated.tagVersion = fields.tagVersion

            let year = taglib_tag_year(tag)
            if year > 0 { updated.year = Int(year) }
            let track = taglib_tag_track(tag)
            if track > 0 { updated.trackNumber = Int(track) }

            updated.isCompilation = taglib_helper_get_compilation(file) != 0
            updated.isMixCompilation = taglib_helper_get_mix_compilation(file) != 0

            updated.label = Self.property(file, "LABEL")
            let disc = DiscTag.parse(
                number: Self.property(file, "DISCNUMBER"),
                total: Self.property(file, "DISCTOTAL") ?? Self.property(file, "TOTALDISCS")
            )
            updated.discNumber = disc.number
            updated.discTotal = disc.total

            var picSize: UInt32 = 0
            if let picBytes = taglib_helper_read_picture(file, &picSize), picSize > 0 {
                updated.artwork = Data(bytes: picBytes, count: Int(picSize))
                free(picBytes)
            }
        }

        // --- Audio format properties via AVFoundation ---
        let asset = AVURLAsset(url: track.url)
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                updated.duration = seconds
            }
        }

        if let file = try? AVAudioFile(forReading: track.url) {
            updated.sampleRate = file.processingFormat.sampleRate
            let asbd = file.fileFormat.streamDescription.pointee
            if let refined = AudioFileFormat.refine(updated.fileFormat, codec: asbd.mFormatID) {
                updated.fileFormat = refined
            }
            if asbd.mBitsPerChannel > 0 {
                updated.bitDepth = Int(asbd.mBitsPerChannel)
            }
        }

        // AVFoundation reports mBitsPerChannel = 0 for compressed containers, so
        // it never yields a bit depth for FLAC/ALAC. Fall back to TagLib only in
        // that case — and only for lossless formats that have a meaningful bit
        // depth — to avoid a redundant file open for tracks already covered
        // (WAV/AIFF) or where bit depth is meaningless (MP3/AAC).
        let losslessCompressed: Set<AudioFileFormat> = [.flac, .alac]
        if updated.bitDepth == nil, losslessCompressed.contains(updated.fileFormat) {
            let bits = track.url.path.withCString { taglib_helper_bits_per_sample($0) }
            if bits > 0 { updated.bitDepth = Int(bits) }
        }

        return updated
    }

    struct MultiValueFields {
        var artist: (value: String?, isList: Bool)
        var albumArtist: (value: String?, isList: Bool)
        var genres: (primary: String?, secondary: [String])
        var tagVersion: Int?
    }

    /// Artist, album artist, genre and the tag-format marker of an open file,
    /// resolved by `MultiValueParser`. Call on the scanner actor (or another
    /// single thread): `tag` strings live in TagLib's global string list.
    static func multiValueFields(_ file: UnsafeMutablePointer<TagLib_File>, tag: UnsafeMutablePointer<TagLib_Tag>) -> MultiValueFields {
        func basic(_ read: (UnsafePointer<TagLib_Tag>?) -> UnsafeMutablePointer<CChar>?) -> [String] {
            guard let ptr = read(tag), ptr.pointee != 0 else { return [] }
            return [String(cString: ptr)]
        }
        func native(_ key: String, fallback: @autoclosure () -> [String] = []) -> [String] {
            let values = propertyList(file, key)
            return values.isEmpty ? fallback() : values
        }
        let artistIDs = MultiValueParser.splitIdentifiers(propertyList(file, "MUSICBRAINZ_ARTISTID"))
        let albumArtistIDs = MultiValueParser.splitIdentifiers(propertyList(file, "MUSICBRAINZ_ALBUMARTISTID"))
        return MultiValueFields(
            artist: MultiValueParser.storedCredit(
                plural: propertyList(file, "ARTISTS"),
                native: native("ARTIST", fallback: basic(taglib_tag_artist)),
                mbidCount: artistIDs.count),
            albumArtist: MultiValueParser.storedCredit(
                plural: propertyList(file, "ALBUMARTISTS"),
                native: native("ALBUMARTIST"),
                mbidCount: albumArtistIDs.count),
            genres: MultiValueParser.storedGenres(native: native("GENRE", fallback: basic(taglib_tag_genre))),
            tagVersion: propertyList(file, "FLACTASTIC_TAGVERSION").first.flatMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
        )
    }

    /// Every value of a property (TagLib's cross-format key), in file order.
    /// Empty when unset. At most `MultiValueParser.maxValues` + 1 are kept, so
    /// a hostile file can't make the parser walk an unbounded list.
    static func propertyList(_ file: UnsafeMutablePointer<TagLib_File>, _ key: String) -> [String] {
        guard let values = key.withCString({ taglib_property_get(file, $0) }) else { return [] }
        defer { taglib_property_free(values) }
        var out: [String] = []
        var i = 0
        while let ptr = values[i], out.count <= MultiValueParser.maxValues {
            out.append(String(cString: ptr))
            i += 1
        }
        return out
    }

    /// One text property by name, trimmed; nil when unset or blank.
    private static func property(_ file: UnsafeMutablePointer<TagLib_File>, _ key: String) -> String? {
        guard let ptr = key.withCString({ taglib_helper_get_property(file, $0) }) else { return nil }
        defer { free(ptr) }
        let value = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
