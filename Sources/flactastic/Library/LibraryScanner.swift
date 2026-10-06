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
    func loadMetadata(for track: Track, cached: TrackMetadataCacheEntry? = nil) async -> Track {
        if let cached, cached.isValid(forFileAt: track.url.path), cached.hasFormat(forFileAt: track.url) {
            var updated = track
            cached.apply(to: &updated)
            if cached.hasArtwork {
                track.url.path.withCString { pathPtr in
                    guard let file = taglib_file_new(pathPtr) else { return }
                    defer {
                        taglib_file_free(file)
                        taglib_tag_free_strings()
                    }
                    guard taglib_file_is_valid(file) != 0 else { return }
                    var picSize: UInt32 = 0
                    if let picBytes = taglib_helper_read_picture(file, &picSize), picSize > 0 {
                        updated.artwork = Data(bytes: picBytes, count: Int(picSize))
                        free(picBytes)
                    }
                }
            }
            return updated
        }

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
            if let ptr = taglib_tag_artist(tag), ptr.pointee != 0 {
                updated.artist = String(cString: ptr)
            }
            if let ptr = taglib_tag_album(tag), ptr.pointee != 0 {
                updated.album = String(cString: ptr)
            }
            if let ptr = taglib_tag_genre(tag), ptr.pointee != 0 {
                let (primary, secondary) = GenreResolver.split(String(cString: ptr))
                updated.genre = primary
                updated.secondaryGenres = secondary
            }
            let year = taglib_tag_year(tag)
            if year > 0 { updated.year = Int(year) }
            let track = taglib_tag_track(tag)
            if track > 0 { updated.trackNumber = Int(track) }

            if let aaPtr = taglib_helper_get_album_artist(file) {
                let aa = String(cString: aaPtr)
                if !aa.isEmpty { updated.albumArtist = aa }
                free(aaPtr)
            }

            updated.isCompilation = taglib_helper_get_compilation(file) != 0
            updated.isMixCompilation = taglib_helper_get_mix_compilation(file) != 0

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

}
