import Foundation

/// Filesystem helpers shared by every import flow. Copies source files into
/// the library root (or an album subfolder) and resolves filename collisions
/// by appending a numeric suffix — matching Finder's "file (2).ext" pattern.
extension Track {
    /// Returns a copy of this track pointing at a new file URL with a fresh
    /// `id` and `dateAdded`. Used by import flows after the source file has
    /// been copied into the library, so the library sees a new entry rather
    /// than a move of the out-of-library original.
    func relocated(to newURL: URL) -> Track {
        Track(
            id: UUID(),
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
            year: year,
            dateAdded: Date()
        )
    }
}

enum ImportCopy {
    enum Error: LocalizedError {
        case noLibraryRoot
        case copyFailed(URL, Swift.Error)

        var errorDescription: String? {
            switch self {
            case .noLibraryRoot:
                return "Choose a library folder in Settings before importing."
            case .copyFailed(let url, let underlying):
                return "Failed to copy \"\(url.lastPathComponent)\": \(underlying.localizedDescription)"
            }
        }
    }

    /// Strips characters that would create an invalid filesystem component.
    /// Returns a fallback when stripping leaves nothing usable.
    static func sanitize(_ name: String, fallback: String = "Unknown") -> String {
        let invalid: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        let cleaned = name
            .filter { !invalid.contains($0) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return fallback }
        // Files starting with "." are hidden on macOS/Unix; prefix with "_" to keep them visible.
        return cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
    }

    /// Builds the standard album folder name used by `Import Album`:
    /// `[artist] - [album title]`, sanitised for filesystem use.
    static func albumFolderName(artist: String?, album: String) -> String {
        let artistPart = sanitize(artist?.trimmingCharacters(in: .whitespaces) ?? "",
                                  fallback: "Unknown Artist")
        let albumPart  = sanitize(album.trimmingCharacters(in: .whitespaces),
                                  fallback: "Untitled Album")
        return "\(artistPart) - \(albumPart)"
    }

    /// Returns a URL inside `directory` that does not already exist. If the
    /// preferred name is taken, appends `(1)`, `(2)`, etc. before the
    /// extension until a free slot is found.
    static func uniqueDestination(for filename: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension

        var candidate = directory.appendingPathComponent(filename)
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty
                ? "\(base) (\(counter))"
                : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }

    /// Builds a filename formatted `[artist] - [song title].[ext]`, with both
    /// parts sanitised for filesystem safety. Falls back to "Unknown Artist"
    /// or "Untitled" when the respective field is blank.
    static func trackFileName(artist: String?, title: String, pathExtension ext: String) -> String {
        let artistPart = sanitize(artist?.trimmingCharacters(in: .whitespaces) ?? "",
                                  fallback: "Unknown Artist")
        let titlePart  = sanitize(title.trimmingCharacters(in: .whitespaces),
                                  fallback: "Untitled")
        let base = "\(artistPart) - \(titlePart)"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Copies `source` into `directory` using `filename` as the destination
    /// name (extension preserved from `source` if `filename` has none).
    /// Creates the directory if needed. If the source already lives at the
    /// resolved target path, returns it unchanged — no copy is performed.
    static func copy(_ source: URL, into directory: URL, named filename: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let wouldBe = directory.appendingPathComponent(filename).standardizedFileURL
        if wouldBe == source.standardizedFileURL {
            return source
        }

        let dest = uniqueDestination(for: filename, in: directory)
        do {
            try fm.copyItem(at: source, to: dest)
        } catch {
            throw Error.copyFailed(source, error)
        }
        return dest
    }
}
