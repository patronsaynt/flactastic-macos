import Foundation

/// A genre answer for an album or a track: a primary genre and up to three
/// secondary ones, in the library's own spelling where it already has one.
struct FoundGenres: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable {
        /// Votes on the album in MusicBrainz.
        case album
        /// Tags on the matched release, filtered to real genres.
        case releaseTags
        /// Votes on the artist in MusicBrainz (the album had none).
        case artist
        /// Deezer's broad genre (MusicBrainz had nothing).
        case deezer
    }

    var primary: String
    var secondary: [String]
    var source: Source
    /// False when Deezer's broad genre points to a different genre family
    /// than MusicBrainz's answer: written anyway, but worth a look.
    var confident: Bool
}

/// Turns what Deezer and MusicBrainz say into one answer. Pure, so it can be
/// tested without the network.
enum GenreVote {
    /// The best source that has anything, its genres ranked by votes (ties
    /// go to a genre the library already uses), as primary + three secondary.
    static func decide(albumGenres: [MusicBrainzClient.Genre],
                       releaseTags: [MusicBrainzClient.Genre],
                       artistGenres: [MusicBrainzClient.Genre],
                       deezer: [String],
                       known: Set<String>,
                       vocabulary: [String],
                       groups: GenreGroups = GenreGroups()) -> FoundGenres? {
        let tags = releaseTags.filter { known.isEmpty || known.contains($0.name.lowercased()) }
        let (picked, source): ([MusicBrainzClient.Genre], FoundGenres.Source)
        if !albumGenres.isEmpty { (picked, source) = (albumGenres, .album) }
        else if !tags.isEmpty { (picked, source) = (tags, .releaseTags) }
        else if !artistGenres.isEmpty { (picked, source) = (artistGenres, .artist) }
        else if !deezer.isEmpty { (picked, source) = (deezer.map { .init(name: $0, votes: 1) }, .deezer) }
        else { return nil }

        let spelling = Dictionary(vocabulary.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        let ranked = picked.enumerated()
            .sorted { a, b in
                if a.element.votes != b.element.votes { return a.element.votes > b.element.votes }
                let ia = spelling[key(a.element.name)] != nil, ib = spelling[key(b.element.name)] != nil
                if ia != ib { return ia }
                return a.offset < b.offset
            }
            .map { spelling[key($0.element.name)] ?? display($0.element.name) }
            .filter { seen.insert(key($0)).inserted }
        guard let primary = ranked.first else { return nil }

        var confident = true
        if source != .deezer, let broad = deezer.first,
           let a = groups.tier(for: [broad]), let b = groups.tier(for: [primary]), a != b {
            confident = false
        }
        return FoundGenres(primary: primary, secondary: Array(ranked.dropFirst().prefix(GenreResolver.maxSecondaryCount)),
                           source: source, confident: confident)
    }

    /// Spelling-insensitive identity: "Drum & Bass" = "drum and bass" = "Drum-n-Bass".
    static func key(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'n'", with: " and ")
            .replacingOccurrences(of: "-n-", with: " and ")
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// MusicBrainz's lower-case names as tags read: "drum and bass" → "Drum and Bass".
    static func display(_ s: String) -> String {
        let upper: Set<String> = ["edm", "idm", "uk", "us", "r&b", "ebm", "dnb", "jpop", "kpop", "lofi", "dj", "mpb"]
        let small: Set<String> = ["and", "of", "the", "n", "in"]
        return s.split(separator: " ").enumerated().map { i, w in
            let word = String(w)
            if upper.contains(word.lowercased()) { return word.uppercased() }
            if i > 0, small.contains(word.lowercased()) { return word.lowercased() }
            return word.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: "-")
        }.joined(separator: " ")
    }
}

/// Looks up genres: Deezer to identify the album (barcode, ISRCs, a broad
/// genre), MusicBrainz for the genres themselves. Network errors are thrown
/// (so the caller tries again later); "not found" is nil.
struct GenreFinder: Sendable {
    let known: Set<String>
    let vocabulary: [String]
    let groups: GenreGroups
    /// Artist genres already fetched (MusicBrainz artist ID → genres).
    let artistCache: GenreCache

    /// An album, by album artist and title.
    func album(artist: String, title: String, trackCount: Int, urgency: MusicBrainzClient.Urgency,
               stage: (@Sendable (GenreJobStage) async -> Void)? = nil) async throws -> FoundGenres? {
        await stage?(.identifying)
        let deezer = try? await DeezerClient.shared.album(artist: artist, title: title, trackCount: trackCount)
        await stage?(.pulling)
        let mb = MusicBrainzClient.shared
        var match: MusicBrainzClient.Match?
        if let upc = deezer?.upc, !upc.isEmpty { match = try await mb.release(barcode: upc, urgency: urgency) }
        if match == nil { match = try await mb.releaseGroup(title: title, artist: artist, urgency: urgency) }
        return try await finish(match, deezer: deezer?.genres ?? [], urgency: urgency)
    }

    /// An album already found on Deezer (the library scan's first stage).
    func album(identified deezer: DeezerClient.Album, artist: String, title: String,
               urgency: MusicBrainzClient.Urgency) async throws -> FoundGenres? {
        let mb = MusicBrainzClient.shared
        var match: MusicBrainzClient.Match?
        if let upc = deezer.upc, !upc.isEmpty { match = try await mb.release(barcode: upc, urgency: urgency) }
        if match == nil { match = try await mb.releaseGroup(title: title, artist: artist, urgency: urgency) }
        return try await finish(match, deezer: deezer.genres, urgency: urgency)
    }

    /// A single track, by artist and title (loose tracks, and compilations).
    func track(artist: String, title: String, urgency: MusicBrainzClient.Urgency,
               stage: (@Sendable (GenreJobStage) async -> Void)? = nil) async throws -> FoundGenres? {
        await stage?(.identifying)
        let found = try? await DeezerClient.shared.track(artist: artist, title: title)
        var deezerGenres: [String] = []
        if let albumID = found?.albumID, let album = try? await DeezerClient.shared.album(id: albumID) {
            deezerGenres = album.genres
        }
        await stage?(.pulling)
        var match: MusicBrainzClient.Match?
        if let isrc = found?.isrc, !isrc.isEmpty {
            match = try await MusicBrainzClient.shared.recording(isrc: isrc, urgency: urgency)
        }
        return try await finish(match, deezer: deezerGenres, urgency: urgency)
    }

    /// From a MusicBrainz match: the album's votes; failing those, the
    /// release's own tags (real genres only); failing those, the lead
    /// artist's votes. (Tags alone were tried as a shortcut and rank badly:
    /// they carry no votes, so "Singer-Songwriter" beat a 4-vote "Shoegaze".)
    private func finish(_ match: MusicBrainzClient.Match?, deezer: [String],
                        urgency: MusicBrainzClient.Urgency) async throws -> FoundGenres? {
        let mb = MusicBrainzClient.shared
        var albumGenres: [MusicBrainzClient.Genre] = []
        var artistGenres: [MusicBrainzClient.Genre] = []
        let tags = match?.tags.filter { known.isEmpty || known.contains($0.name.lowercased()) } ?? []
        if let match {
            albumGenres = try await mb.releaseGroupGenres(match.releaseGroupID, urgency: urgency)
            if albumGenres.isEmpty, tags.isEmpty, let artist = match.artistIDs.first {
                if let cached = await artistCache.artist(artist) {
                    artistGenres = cached
                } else {
                    artistGenres = try await mb.artistGenres(artist, urgency: urgency)
                    await artistCache.store(artist: artist, genres: artistGenres)
                }
            }
        }
        return GenreVote.decide(albumGenres: albumGenres, releaseTags: tags, artistGenres: artistGenres,
                                deezer: deezer, known: known, vocabulary: vocabulary, groups: groups)
    }
}

enum GenreJobStage: Sendable { case identifying, pulling, writing, lyrics }
