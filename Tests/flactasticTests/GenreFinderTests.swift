import Foundation
import Testing
@testable import flactastic

struct GenreVoteTests {
    private func g(_ name: String, _ votes: Int) -> MusicBrainzClient.Genre { .init(name: name, votes: votes) }

    @Test func albumVotesWinAndRankByVotes() {
        // Census Designated, as MusicBrainz had it in testing.
        let found = GenreVote.decide(
            albumGenres: [g("alternative rock", 3), g("dream pop", 2), g("shoegaze", 4), g("post-rock", 3), g("indie rock", 3)],
            releaseTags: [], artistGenres: [g("digicore", 9)], deezer: ["Alternative"], known: [], vocabulary: [])
        #expect(found?.primary == "Shoegaze")
        #expect(found?.secondary.count == 3)
        #expect(found?.source == .album)
    }

    @Test func fallsBackToArtistThenDeezer() {
        // then i'll be happy: no album votes, so glaive's own.
        let artist = GenreVote.decide(albumGenres: [], releaseTags: [],
                                      artistGenres: [g("hyperpop", 1), g("digicore", 1)], deezer: ["Pop"],
                                      known: [], vocabulary: [])
        #expect(artist?.primary == "Hyperpop")
        #expect(artist?.source == .artist)
        let deezer = GenreVote.decide(albumGenres: [], releaseTags: [], artistGenres: [], deezer: ["Rap/Hip Hop"],
                                      known: [], vocabulary: [])
        #expect(deezer?.primary == "Rap/Hip Hop")
        #expect(deezer?.source == .deezer)
        #expect(GenreVote.decide(albumGenres: [], releaseTags: [], artistGenres: [], deezer: [], known: [], vocabulary: []) == nil)
    }

    @Test func releaseTagsCountOnlyWhenTheyreRealGenres() {
        let found = GenreVote.decide(albumGenres: [], releaseTags: [g("united states", 5), g("dream pop", 2)],
                                     artistGenres: [], deezer: [], known: ["dream pop", "shoegaze"], vocabulary: [])
        #expect(found?.primary == "Dream Pop")
        #expect(found?.source == .releaseTags)
    }

    @Test func usesTheLibrarysOwnSpelling() {
        let found = GenreVote.decide(albumGenres: [g("drum and bass", 3), g("edm", 1)], releaseTags: [], artistGenres: [],
                                     deezer: [], known: [], vocabulary: ["Drum & Bass"])
        #expect(found?.primary == "Drum & Bass")
        #expect(found?.secondary == ["EDM"])
    }

    @Test func tiesGoToGenresAlreadyInTheLibrary() {
        let found = GenreVote.decide(albumGenres: [g("electronic", 4), g("house", 4)], releaseTags: [], artistGenres: [],
                                     deezer: [], known: [], vocabulary: ["House"])
        #expect(found?.primary == "House")
    }

    @Test func displayNames() {
        #expect(GenreVote.display("hip hop") == "Hip Hop")
        #expect(GenreVote.display("drum and bass") == "Drum and Bass")
        #expect(GenreVote.display("lo-fi house") == "Lo-Fi House")
        #expect(GenreVote.display("uk garage") == "UK Garage")
    }
}

/// Writing only into empty genre tags, on real encoded files.
struct GenreWriteTests {
    private func makeFile() throws -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("genrewrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("tone.wav")
        var data = Data("RIFF".utf8)
        let samples = 4410 * 4
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        data += le32(36 + samples) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(2) + le32(44100) + le32(44100 * 4) + le16(4) + le16(16)
        data += Data("data".utf8) + le32(samples) + Data(count: samples)
        try data.write(to: wav)
        let out = dir.appendingPathComponent("tone.m4a")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "m4af", "-d", "alac", wav.path, out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? out : nil
    }

    @Test func writesOnlyWhenEmpty() async throws {
        let url = try #require(try makeFile())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = MetadataWriter()
        let track = Track(url: url, title: "Tone", fileFormat: .alac)

        let first = try await writer.writeGenreIfEmpty(to: track, primary: "Shoegaze", secondary: ["Dream Pop", "Post-Rock"])
        #expect(first?.genre == "Shoegaze")
        #expect(first?.secondaryGenres == ["Dream Pop", "Post-Rock"])
        let read = await LibraryScanner().loadMetadata(for: track)
        #expect(read.genre == "Shoegaze")
        #expect(read.secondaryGenres == ["Dream Pop", "Post-Rock"])

        // Already tagged in the file: left alone, even with a stale Track.
        let second = try await writer.writeGenreIfEmpty(to: track, primary: "Hyperpop", secondary: [])
        #expect(second == nil)
        #expect(await LibraryScanner().loadMetadata(for: track).genre == "Shoegaze")
    }
}

/// The whole lookup against the real services, on albums from this
/// library. Off by default; run with FLACTASTIC_LIVE_GENRES=1.
struct GenreLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLACTASTIC_LIVE_GENRES"] == "1"))
    func realAlbums() async throws {
        let finder = GenreFinder(known: await GenreCache.shared.knownGenres(), vocabulary: [], groups: GenreGroups(),
                                 artistCache: GenreCache.shared)
        for (artist, title, count) in [("Jane Remover", "Census Designated", 10), ("glaive", "then i'll be happy", 8),
                                       ("Avicii", "True", 10), ("Fimiguerrero", "The Statue of a Fool", 8)] {
            let started = Date()
            let found = try await finder.album(artist: artist, title: title, trackCount: count, urgency: .playing)
            print("LIVE \(artist) — \(title): \(found.map { "\($0.primary) + \($0.secondary) [\($0.source), confident: \($0.confident)]" } ?? "none") in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            #expect(found != nil)
        }
        let track = try await finder.track(artist: "Avicii", title: "Wake Me Up", urgency: .playing)
        print("LIVE track Avicii — Wake Me Up: \(track.map { "\($0.primary) + \($0.secondary) [\($0.source)]" } ?? "none")")
    }
}

/// The Settings scan, end to end, on a small in-memory library whose files
/// don't exist (so nothing is written anywhere). Exercises both stages and
/// the progress updates that crashed the first real scan. Needs the
/// network; run with FLACTASTIC_LIVE_GENRES=1.
@MainActor
struct GenreScanLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLACTASTIC_LIVE_GENRES"] == "1"))
    func scanRunsToTheEnd() async throws {
        let store = LibraryStore()
        let albums = [("Jane Remover", "Census Designated"), ("glaive", "then i'll be happy"),
                      ("Avicii", "True"), ("Nobody Real", "No Such Album \(UUID().uuidString.prefix(6))"),
                      ("Fimiguerrero", "The Statue of a Fool"), ("Avicii", "Stories")]
        store.tracks = albums.flatMap { artist, album in
            (1...3).map { n in
                Track(url: URL(fileURLWithPath: "/nonexistent/\(album)/\(n).flac"), title: "\(album) \(n)",
                      artist: artist, albumArtist: artist, album: album, trackNumber: n, fileFormat: .flac)
            }
        }
        store.hasCompletedInitialLoad = true
        let settings = Settings()
        GenreScanner.shared.attach(library: store, writer: MetadataWriter(),
                                   lyrics: LyricsFetcher(cache: LyricsRemoteCache()), settings: settings)
        await GenreCache.shared.clearAlbums()

        GenreScanner.shared.scanLibrary()
        #expect(GenreScanner.shared.isScanning)
        var sawPulling = false
        let deadline = Date().addingTimeInterval(120)
        while GenreScanner.shared.isScanning, Date() < deadline {
            if GenreScanner.shared.scan?.stage == .pulling { sawPulling = true }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!GenreScanner.shared.isScanning)
        #expect(sawPulling)
        let last = try #require(GenreScanner.shared.lastScan)
        print("LIVE scan: \(last.albums) albums, \(last.tracksWritten) written (files don't exist), \(last.notFound) not found")
        #expect(last.albums == albums.count)
        #expect(last.tracksWritten == 0)
        let counts = await GenreCache.shared.counts
        print("LIVE cache: \(counts.found) found, \(counts.notFound) not found")
        #expect(counts.found >= 4)
    }
}
