import Foundation

/// Renders folder/file names from token templates against a Track's metadata.
/// Tokens use {curly} syntax. Missing/blank fields fall back to humane defaults
/// ("Unknown Artist", "Untitled", etc.) so the output is always a valid path.
enum OrganizerTemplate {
    /// All tokens supported by the renderer, in display order. Used to populate
    /// the token-chip palette in the UI.
    static let allTokens: [Token] = [
        Token(key: "artist", description: "Track artist"),
        Token(key: "albumArtist", description: "Album artist"),
        Token(key: "album", description: "Album title"),
        Token(key: "title", description: "Track title"),
        Token(key: "track", description: "Track number, zero-padded"),
        Token(key: "year", description: "Release year"),
        Token(key: "decade", description: "Release decade (e.g. 1990)"),
        Token(key: "genre", description: "Genre"),
        Token(key: "format", description: "File format (FLAC, MP3, …)"),
        Token(key: "ext", description: "File extension (lowercased)"),
        Token(key: "artistInitial", description: "First letter of artist")
    ]

    struct Token: Identifiable, Hashable {
        let key: String
        let description: String
        var id: String { key }
        var placeholder: String { "{\(key)}" }
    }

    /// Renders `template` using values from `track`. Result is sanitised for
    /// filesystem safety (path separators stripped, etc.). Empty result falls
    /// back to `fallback`. When `primaryArtistOnly` is true, multi-artist
    /// values are reduced to the first credited artist, split the way the rest
    /// of the app splits them (`resolver`; explicit lists only without one).
    static func render(_ template: String, for track: Track, fallback: String = "Unknown", primaryArtistOnly: Bool = false,
                       resolver: ArtistResolver? = nil) -> String {
        var out = template
        for token in allTokens {
            out = out.replacingOccurrences(of: token.placeholder, with: value(for: token.key, track: track, primaryArtistOnly: primaryArtistOnly, resolver: resolver))
        }
        return ImportCopy.sanitize(out, fallback: fallback)
    }

    /// The first credited artist of a multi-artist string. Explicit lists
    /// ("A ; B") always split; ambiguous credits ("A & B", "A, B") split only
    /// when `resolver` confirms it, so "Earth, Wind & Fire" stays whole.
    static func primaryArtist(_ raw: String, resolver: ArtistResolver? = nil) -> String {
        let pieces = resolver?.split(raw) ?? MultiValueParser.splitSafe(raw) ?? [raw]
        return (pieces.first ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func value(for key: String, track: Track, primaryArtistOnly: Bool, resolver: ArtistResolver?) -> String {
        switch key {
        case "artist":
            let raw = track.artist ?? "Unknown Artist"
            return primaryArtistOnly ? primaryArtist(raw, resolver: resolver) : raw
        case "albumArtist":
            let raw = track.albumArtist ?? track.artist ?? "Unknown Artist"
            return primaryArtistOnly ? primaryArtist(raw, resolver: resolver) : raw
        case "album": return track.album ?? "Unknown Album"
        case "title": return track.title.isEmpty ? "Untitled" : track.title
        case "track": return track.trackNumber.map { String(format: "%02d", $0) } ?? "00"
        case "year": return track.year.map(String.init) ?? ""
        case "decade": return track.year.map { "\(($0 / 10) * 10)" } ?? ""
        case "genre": return track.genre ?? ""
        case "format": return track.fileFormat.rawValue.uppercased()
        case "ext": return track.url.pathExtension.lowercased()
        case "artistInitial":
            var name = track.albumArtist ?? track.artist ?? ""
            if primaryArtistOnly { name = primaryArtist(name, resolver: resolver) }
            return name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "#"
        default: return ""
        }
    }
}
