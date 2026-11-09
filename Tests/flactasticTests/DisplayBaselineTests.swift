import Foundation
import Testing
@testable import flactastic

// Golden master for everything the app shows from artist, album artist and
// genre data. Scans the committed fixtures (Tests/Fixtures/audio) through the
// real pipeline and compares every consumer's output with
// Tests/Fixtures/display-baseline.json, which was recorded with the code as it
// was before multi-value tags. Any difference is a regression.
//
// Re-record (only when a display change is intended):
//   FLACTASTIC_RECORD_BASELINE=1 swift test --filter DisplayBaseline

struct DisplayBaseline: Codable, Equatable {
    struct TrackRecord: Codable, Equatable {
        var file: String
        var title: String
        var artist: String?
        var albumArtist: String?
        var album: String?
        var genre: String?
        var secondaryGenres: [String]
        var isCompilation: Bool
        var displayArtist: String?
        var displayArtistOrAlbumArtist: String?
        var displayAlbumArtist: String?
        var primaryCredit: String?
        var splitArtist: [String]
        var artistKeys: [String]
        var splitAlbumArtist: [String]
        var albumArtistKeys: [String]
        var editorArtistChips: [String]
        var editorAlbumArtistChips: [String]
        var editorGenreString: String?
        var castDIDL: String
        var organizerPath: String
        var organizerPrimaryPath: String
        var discordArtist: String
        var nowPlayingArtist: String?
    }
    struct AlbumRecord: Codable, Equatable {
        var id: String
        var name: String
        var artist: String?
        var albumArtist: String?
        var genre: String?
        var secondaryGenres: [String]
        var isCompilation: Bool
        var cardArtist: String
        var rackArtist: String
        var trackFiles: [String]
    }
    struct ArtistRecord: Codable, Equatable {
        var id: String
        var displayName: String
        var albums: [String]
        var singles: [String]
        var appearsOn: [String]
        var appearsOnTracks: [String]
        var trackCount: Int
    }
    var tracks: [TrackRecord]
    var albums: [AlbumRecord]
    var artists: [ArtistRecord]
    var canonicalNames: [String: String]
    var albumsSortedByArtist: [String]
    var albumsSortedByGenre: [String]
    var tracksSortedByArtist: [String]
    var trackSearch: [String: [String]]
    var albumSearch: [String: [String]]
    var downloadMatches: [String: String]

    static let searchQueries = ["deadmau5", "rob", ";", " ; ", "&", "guest", "hip", "punk", "/", "\\", ",", "kaskade", "busta"]

    static let remoteProbes: [(title: String, artists: [String])] = [
        ("I Remember", ["Kaskade"]),
        ("Ghosts n Stuff", ["Rob Swire"]),
        ("Scenario", ["Busta Rhymes"]),
        ("Move for Me", ["Deadmau5"]),
        ("Feature", ["Guest"]),
        ("Mrs Robinson", ["Garfunkel"]),
        ("Back in Black", ["AC/DC"]),
        ("Get Lucky", ["Pharrell Williams"]),
    ]

    /// Builds every consumer's output for `tracks`, already loaded from disk.
    @MainActor
    static func capture(_ loaded: [Track]) -> DisplayBaseline {
        let library = LibraryStore()
        library.tracks = loaded.sortedForLibrary()
        library.normaliseArtistTags()
        let resolver = library.makeArtistResolver()
        let tracks = library.tracks
        func file(_ t: Track) -> String { t.url.lastPathComponent }

        let trackRecords = tracks.map { t in
            TrackRecord(
                file: file(t), title: t.title, artist: t.artist, albumArtist: t.albumArtist, album: t.album,
                genre: t.genre, secondaryGenres: t.secondaryGenres, isCompilation: t.isCompilation,
                displayArtist: ArtistResolver.displayString(t.artist),
                displayArtistOrAlbumArtist: ArtistResolver.displayString(t.artist ?? t.albumArtist),
                displayAlbumArtist: ArtistResolver.displayString(t.albumArtist),
                primaryCredit: t.artist.map(ArtistResolver.primaryCredit),
                splitArtist: resolver.split(t.artist),
                artistKeys: resolver.keys(forCredit: t.artist),
                splitAlbumArtist: resolver.split(t.albumArtist),
                albumArtistKeys: resolver.keys(forCredit: t.albumArtist),
                editorArtistChips: TagText.chips(t.artist),
                editorAlbumArtistChips: TagText.chips(t.albumArtist),
                editorGenreString: GenreResolver.join(primary: t.genre, secondary: t.secondaryGenres),
                // Fixed id: the DIDL item id is the track's random UUID.
                castDIDL: DIDLLite.metadata(
                    for: t.rebuilt(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))), resource: .init(url: URL(string: "http://127.0.0.1:1/t")!, mimeType: "audio/flac"), artworkURL: nil),
                organizerPath: OrganizerTemplate.render("{albumArtist}/{album}/{artist} - {title} [{genre}]", for: t),
                organizerPrimaryPath: OrganizerTemplate.render("{albumArtist}/{album}/{artist} - {title} [{genre}]", for: t, primaryArtistOnly: true),
                discordArtist: DiscordPresenceService.artistLine(for: t),
                nowPlayingArtist: t.artist
            )
        }

        let albums = library.albums.sorted { $0.id < $1.id }
        let albumRecords = albums.map { a in
            AlbumRecord(
                id: a.id, name: a.name, artist: a.artist, albumArtist: a.albumArtist, genre: a.genre,
                secondaryGenres: a.secondaryGenres, isCompilation: a.isCompilation,
                cardArtist: ArtistResolver.displayString(a.artist) ?? "Unknown Artist",
                rackArtist: a.isCompilation ? "Compilation" : (ArtistResolver.displayString(a.albumArtist ?? a.artist) ?? "Unknown Artist"),
                trackFiles: a.tracks.map(file)
            )
        }

        let artistRecords = library.allArtists(resolver: resolver).sorted { $0.id < $1.id }.map { s in
            ArtistRecord(
                id: s.id, displayName: s.displayName,
                albums: s.albums.map(\.id).sorted(), singles: s.singles.map(\.id).sorted(),
                appearsOn: s.appearsOn.map(\.id).sorted(), appearsOnTracks: s.appearsOnTracks.map(file).sorted(),
                trackCount: s.trackCount
            )
        }

        // Same comparators as CollectionView and AllTracksView, with the id as
        // a tiebreak so the recorded order is deterministic.
        func tie(_ a: String, _ b: String, _ r: ComparisonResult, _ ia: String, _ ib: String) -> Bool {
            r == .orderedSame ? ia < ib : r == .orderedAscending
        }
        let byArtist = albums.sorted {
            tie($0.artist ?? "", $1.artist ?? "", ($0.artist ?? "").localizedStandardCompare($1.artist ?? ""), $0.id, $1.id)
        }.map(\.id)
        let byGenre = albums.sorted {
            tie("", "", ($0.genre ?? "Unknown").localizedStandardCompare($1.genre ?? "Unknown"), $0.id, $1.id)
        }.map(\.id)
        let tracksByArtist = tracks.sorted { a, b in
            let lhs = a.artist ?? "", rhs = b.artist ?? ""
            if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
            return tie(lhs, rhs, lhs.localizedStandardCompare(rhs), file(a), file(b))
        }.map(file)

        var trackSearch: [String: [String]] = [:]
        var albumSearch: [String: [String]] = [:]
        for raw in searchQueries {
            let q = raw.lowercased()
            trackSearch[raw] = tracks.filter { t in
                t.title.localizedCaseInsensitiveContains(q)
                    || (t.artist?.localizedCaseInsensitiveContains(q) ?? false)
                    || (t.album?.localizedCaseInsensitiveContains(q) ?? false)
            }.map(file).sorted()
            albumSearch[raw] = albums.filter {
                $0.name.localizedCaseInsensitiveContains(q) ||
                ($0.artist?.localizedCaseInsensitiveContains(q) ?? false) ||
                $0.tracks.contains { $0.title.localizedCaseInsensitiveContains(q) }
            }.map(\.id).sorted()
        }

        let index = LibraryMatchIndex(tracks)
        var matches: [String: String] = [:]
        for probe in remoteProbes {
            let remote = RemoteTrack(
                id: probe.title, title: probe.title,
                artists: probe.artists.map { RemoteArtist(id: $0, name: $0, url: nil, pictureURL: nil) },
                album: nil, trackNumber: nil, discNumber: nil, durationSeconds: nil, coverArt: [], url: nil,
                serviceID: "test", isLossless: true)
            matches["\(probe.title) / \(probe.artists.joined(separator: ", "))"] = index.match(remote).map(file) ?? "-"
        }

        return DisplayBaseline(
            tracks: trackRecords, albums: albumRecords, artists: artistRecords,
            canonicalNames: resolver.canonicalByKey,
            albumsSortedByArtist: byArtist, albumsSortedByGenre: byGenre, tracksSortedByArtist: tracksByArtist,
            trackSearch: trackSearch, albumSearch: albumSearch, downloadMatches: matches
        )
    }

    static func encode(_ value: DisplayBaseline) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func load() throws -> DisplayBaseline {
        try JSONDecoder().decode(DisplayBaseline.self, from: Data(contentsOf: FixtureSupport.baselineURL))
    }

    /// Compares field by field so a failure names exactly what changed.
    static func expectMatches(_ actual: DisplayBaseline, _ expected: DisplayBaseline,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.tracks.map(\.file) == expected.tracks.map(\.file), sourceLocation: sourceLocation)
        for (a, e) in zip(actual.tracks, expected.tracks) where a != e {
            #expect(a == e, "track \(e.file) differs", sourceLocation: sourceLocation)
        }
        #expect(actual.albums.map(\.id) == expected.albums.map(\.id), sourceLocation: sourceLocation)
        for (a, e) in zip(actual.albums, expected.albums) where a != e {
            #expect(a == e, "album \(e.id) differs", sourceLocation: sourceLocation)
        }
        #expect(actual.artists.map(\.id) == expected.artists.map(\.id), sourceLocation: sourceLocation)
        for (a, e) in zip(actual.artists, expected.artists) where a != e {
            #expect(a == e, "artist \(e.id) differs", sourceLocation: sourceLocation)
        }
        #expect(actual.canonicalNames == expected.canonicalNames, sourceLocation: sourceLocation)
        #expect(actual.albumsSortedByArtist == expected.albumsSortedByArtist, sourceLocation: sourceLocation)
        #expect(actual.albumsSortedByGenre == expected.albumsSortedByGenre, sourceLocation: sourceLocation)
        #expect(actual.tracksSortedByArtist == expected.tracksSortedByArtist, sourceLocation: sourceLocation)
        #expect(actual.trackSearch == expected.trackSearch, sourceLocation: sourceLocation)
        #expect(actual.albumSearch == expected.albumSearch, sourceLocation: sourceLocation)
        #expect(actual.downloadMatches == expected.downloadMatches, sourceLocation: sourceLocation)
    }
}

@MainActor
struct DisplayBaselineTests {
    @Test func displayMatchesBaseline() async throws {
        let dir = try FixtureSupport.copyFixtures()
        defer { try? FileManager.default.removeItem(at: dir) }
        let actual = DisplayBaseline.capture(try await FixtureSupport.scan(dir))

        if ProcessInfo.processInfo.environment["FLACTASTIC_RECORD_BASELINE"] == "1" {
            try DisplayBaseline.encode(actual).write(to: FixtureSupport.baselineURL, options: .atomic)
            return
        }
        DisplayBaseline.expectMatches(actual, try DisplayBaseline.load())
    }
}
