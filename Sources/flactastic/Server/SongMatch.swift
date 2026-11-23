import Foundation

/// Whether a file on this Mac is a song the server already has, even when
/// its bytes differ (other tags, artwork, or another rip): same title,
/// artist, album, track and disc number, and length within 2 seconds.
/// Case, accents, spacing and punctuation don't matter.
enum SongMatch {
    /// Lowercased, accents folded, letters and digits only; nil when empty.
    static func key(_ text: String?) -> String? {
        guard let text else { return nil }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let out = String(String.UnicodeScalarView(kept))
        return out.isEmpty ? nil : out
    }

    static func isSame(_ local: Track, _ server: ServerTrack) -> Bool {
        guard let title = key(local.title), title == key(server.title) else { return false }
        guard key(local.album) == key(server.album) else { return false }
        let mine = Set([local.artist, local.albumArtist].compactMap(key))
        let theirs = Set([server.artist, server.albumArtist].compactMap(key))
        guard !mine.isEmpty, !mine.isDisjoint(with: theirs) else { return false }
        if let a = local.trackNumber, let b = server.trackNumber, a != b { return false }
        if let a = local.discNumber, let b = server.discNumber, a != b { return false }
        if let a = local.duration, let b = server.duration, abs(a - b) > 2 { return false }
        return true
    }

    /// The server's track for this song, preferring one in the same format.
    static func find(_ local: Track, in byTitle: [String: [ServerTrack]]) -> ServerTrack? {
        guard let title = key(local.title), let candidates = byTitle[title] else { return nil }
        let same = candidates.filter { isSame(local, $0) }
        return same.first { AudioFileFormat(rawValue: $0.format) == local.fileFormat } ?? same.first
    }

    /// Server tracks grouped by title key, for `find`.
    static func index<S: Sequence>(_ tracks: S) -> [String: [ServerTrack]] where S.Element == ServerTrack {
        var out: [String: [ServerTrack]] = [:]
        for track in tracks {
            if let title = key(track.title) { out[title, default: []].append(track) }
        }
        return out
    }
}
