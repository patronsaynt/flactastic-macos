import Foundation

/// Answers "is this remote track already in the library?" with the rule
/// `DownloadCoordinator.findExistingMatch` documents. That rule decides what
/// a download skips, so the Download tab's "In Library" marks use it too and
/// the two always agree.
///
/// Every library track's title keys are worked out once and indexed, so a
/// lookup is a few dictionary hits. A 500-track playlist can be checked in
/// one go instead of rescanning the library per track.
struct LibraryMatchIndex: Sendable {
    private var fileExact: [String: [Track]] = [:]
    private var fileLoose: [String: [Track]] = [:]
    private var tagExact: [String: [Track]] = [:]
    private var tagLoose: [String: [Track]] = [:]

    init(_ tracks: [Track]) {
        for t in tracks {
            var stem = t.url.deletingPathExtension().lastPathComponent
            let stemRange = NSRange(stem.startIndex..., in: stem)
            if let m = Self.leadingTrackNumber.firstMatch(in: stem, range: stemRange),
               let r = Range(m.range, in: stem) {
                stem = String(stem[r.upperBound...])
            }
            fileExact[Self.normalize(stem), default: []].append(t)
            fileLoose[Self.looseTitle(stem), default: []].append(t)
            tagExact[Self.normalize(t.title), default: []].append(t)
            tagLoose[Self.looseTitle(t.title), default: []].append(t)
        }
    }

    func match(_ remote: RemoteTrack) -> Track? {
        let exactKey = Self.normalize(remote.title)
        guard !exactKey.isEmpty else { return nil }
        let looseKey = Self.looseTitle(remote.title)

        let remoteArtists = Self.artistTokens(remote.artists.map(\.name).joined(separator: "; "))
        let remoteAlbum = remote.album.map { Self.normalize($0.title) } ?? ""

        // Strategy tiers, tried in order. `requireOverlap` gates the looser
        // tiers on artist/album overlap to avoid false positives.
        let tiers: [(key: String, index: [String: [Track]], requireOverlap: Bool)] = [
            (exactKey, fileExact, false),
            (exactKey, tagExact, false),
            (looseKey, fileLoose, true),
            (looseKey, tagLoose, true),
        ]

        // A title match alone is never enough to call something a duplicate —
        // many distinct recordings share a title (covers, different artists).
        // We require the library track to share an artist or the album with the
        // remote track. A bare title-only match is accepted *only* when we have
        // no artist/album info on the remote track to compare against (so we
        // can't do any better).
        let canDisambiguate = !remoteArtists.isEmpty || !remoteAlbum.isEmpty

        for tier in tiers {
            guard !tier.key.isEmpty, let hits = tier.index[tier.key], !hits.isEmpty else { continue }

            // Prefer a hit that shares an artist or album.
            if let m = hits.first(where: { Self.overlaps($0, remoteArtists: remoteArtists, remoteAlbum: remoteAlbum) }) {
                return m
            }

            // No artist/album overlap. The loose tiers always demand it; the
            // exact-title tiers accept a title-only match only when there's
            // nothing to disambiguate on. Otherwise this is a same-title but
            // different recording — not a duplicate — so keep looking.
            if tier.requireOverlap || canDisambiguate { continue }
            return hits[0]
        }
        return nil
    }

    /// True when a library track shares an artist token or its album name with
    /// the remote track (used to disambiguate same-title matches).
    ///
    /// When *both* sides carry artist info and no artist matches, that's a
    /// veto: they're different recordings, full stop. The album name is only
    /// consulted when one side lacks artist info — otherwise a self-titled
    /// single ("Kiss" by X vs the single "Kiss" by Y, both on an album named
    /// "Kiss") would falsely read as the same track.
    private static func overlaps(_ t: Track, remoteArtists: Set<String>, remoteAlbum: String) -> Bool {
        let libArtists = artistTokens(t.artist).union(artistTokens(t.albumArtist))
        if !remoteArtists.isEmpty, !libArtists.isEmpty {
            return !remoteArtists.isDisjoint(with: libArtists)
        }
        if !remoteAlbum.isEmpty, normalize(t.album ?? "") == remoteAlbum { return true }
        return false
    }

    /// Compiled once; NSRegularExpression is immutable and Sendable.
    private static let leadingTrackNumber =
        try! NSRegularExpression(pattern: #"^\d{1,3}\s*-\s*"#)

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A forgiving title key: lowercased, with version markers (" - " and any
    /// parenth/bracket grouping) flattened and whitespace collapsed, so the
    /// same track tagged "Song - Radio Edit" or "Song (Radio Edit)" compares
    /// equal across services.
    private static func looseTitle(_ s: String) -> String {
        var t = s.lowercased()
        for ch in ["(", ")", "[", "]"] { t = t.replacingOccurrences(of: ch, with: " ") }
        t = t.replacingOccurrences(of: " - ", with: " ")
        let collapsed = t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return collapsed.joined(separator: " ")
    }

    /// Split a (possibly multi-artist) artist tag into a set of normalized
    /// names, tolerating every separator different services use. Permissive
    /// on purpose: this only decides whether two credits overlap.
    private static func artistTokens(_ raw: String?) -> Set<String> {
        guard let raw, !raw.isEmpty else { return [] }
        return Set(MultiValueParser.splitPermissive(raw.lowercased()))
    }
}
