import Foundation
import AppKit
import Testing
@testable import flactastic

@MainActor
struct HomeFeedTests {
    /// A small library: each album has three tracks of one quality and genre.
    private func library(_ albums: [(name: String, artist: String, bits: Int, rate: Double, genre: String)]) -> LibraryStore {
        let store = LibraryStore()
        store.tracks = albums.flatMap { a in
            (1...3).map { n in
                Track(url: URL(fileURLWithPath: "/m/\(a.artist)/\(a.name)/\(n).flac"), title: "\(a.name) \(n)",
                      artist: a.artist, albumArtist: a.artist, album: a.name, trackNumber: n, duration: 200,
                      fileFormat: .flac, sampleRate: a.rate, bitDepth: a.bits, genre: a.genre,
                      dateAdded: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)))
            }
        }
        return store
    }

    private func plays(_ album: Album, times: Int, at date: Date) -> [PlayEvent] {
        (0..<times).map { i in
            let t = album.tracks[i % album.tracks.count]
            return PlayEvent(date: date.addingTimeInterval(Double(i) * 300), trackID: t.id, title: t.title, artist: t.artist,
                             albumID: album.id, album: album.name, genre: t.genre, secondsListened: 200, counted: true)
        }
    }

    private func build(_ store: LibraryStore, events: [PlayEvent] = [], rotation: TodayRotation? = nil, now: Date = .now,
                       loaded: Bool = true) -> HomeFeed {
        HomeFeed.build(.init(albums: store.albums, tracks: store.tracks, events: events, recentContexts: [],
                             onThisDay: nil, storedRotation: rotation, resolver: store.makeArtistResolver(), now: now,
                             isLibraryLoaded: loaded))
    }

    @Test func bestSoundingRanksBitDepthThenSampleRate() {
        let store = library([
            ("CD", "A", 16, 44_100, "Rock"), ("Deep", "B", 24, 44_100, "Rock"),
            ("Studio", "C", 24, 48_000, "Rock"), ("Hi", "D", 24, 96_000, "Rock"), ("Ultra", "E", 24, 192_000, "Rock"),
        ])
        let names = build(store).bestSounding.map(\.album.name)
        #expect(names == ["Ultra", "Hi", "Studio", "Deep", "CD"])
    }

    @Test func todaysRotationHoldsForTheDay() throws {
        let store = library((1...14).map { ("Album \($0)", "Artist \($0)", 16, 44_100, "Pop") })
        let morning = build(store)
        let rotation = try #require(morning.rotation)
        #expect(rotation.day == HomeFeed.dayKey(.now))
        #expect(!rotation.albums.contains(rotation.lead))
        // Plays later in the day don't reshuffle it.
        let afternoon = build(store, events: plays(store.albums[0], times: 6, at: .now), rotation: rotation)
        #expect(afternoon.today?.lead.id == rotation.lead)
        #expect(afternoon.today?.albums.map(\.id) == rotation.albums)
        // A new day picks again.
        let tomorrow = build(store, rotation: rotation, now: .now.addingTimeInterval(86_400))
        #expect(tomorrow.rotation?.day != rotation.day)
    }

    @Test func todaysRotationWaitsForTheWholeLibrary() throws {
        let store = library((1...14).map { ("Album \($0)", "Artist \($0)", 16, 44_100, "Pop") })
        let rotation = try #require(build(store).rotation)
        // Mid-launch, before the albums are grouped, the stored picks can't be
        // found: nothing is rolled in their place, so the day's picks survive.
        let loading = library((1...3).map { ("Untagged \($0)", "", 16, 44_100, "") })
        let early = build(loading, rotation: rotation, loaded: false)
        #expect(early.today == nil && early.rotation == nil)
        // Once loaded, the same day's picks come back.
        #expect(build(store, rotation: rotation).rotation == rotation)
    }

    @Test func jumpBackInWantsFavouritesThatWentQuiet() {
        let store = library([("Old Love", "A", 16, 44_100, "Pop"), ("Fresh", "B", 16, 44_100, "Pop"), ("Once", "C", 16, 44_100, "Pop")])
        let albums = Dictionary(uniqueKeysWithValues: store.albums.map { ($0.name, $0) })
        let longAgo = Date.now.addingTimeInterval(-90 * 86_400)
        let events = plays(albums["Old Love"]!, times: 8, at: longAgo)
            + plays(albums["Fresh"]!, times: 8, at: .now.addingTimeInterval(-86_400))
            + plays(albums["Once"]!, times: 1, at: longAgo)
        let picks = build(store, events: events).jumpBackIn
        #expect(picks.map(\.album.name) == ["Old Love"])
        #expect(picks.first?.note == "3 months")
    }

    @Test func onRepeatCountsTheLastThirtyDays() {
        let store = library([("Loop", "A", 16, 44_100, "Pop")])
        let album = store.albums[0]
        let t = album.tracks
        func listen(_ track: Track, _ n: Int, daysAgo: Double) -> [PlayEvent] {
            (0..<n).map { _ in PlayEvent(date: .now.addingTimeInterval(-daysAgo * 86_400), trackID: track.id, title: track.title,
                                          albumID: album.id, secondsListened: 200, counted: true) }
        }
        let events = listen(t[0], 3, daysAgo: 2) + listen(t[1], 5, daysAgo: 1) + listen(t[2], 9, daysAgo: 60) + listen(t[2], 1, daysAgo: 1)
        let rows = build(store, events: events).onRepeat
        #expect(rows.map(\.track.id) == [t[1].id, t[0].id])
        #expect(rows.map(\.plays) == [5, 3])
    }

    @Test func timeOfDayBands() {
        #expect([6, 11, 12, 16, 17, 21, 22, 2].map(HomeFeed.band) == [0, 0, 1, 1, 2, 2, 3, 3])
    }

    @Test func djMixTracksStayOutOfMixes() {
        func track(_ title: String, album: String) -> Track {
            Track(url: URL(fileURLWithPath: "/m/\(title).flac"), title: title, album: album, fileFormat: .flac)
        }
        #expect(HomeFeed.isFromDJMix(track("Strobe (Mixed)", album: "Fabric 50")))
        #expect(HomeFeed.isFromDJMix(track("Ghosts", album: "Cream Ibiza (DJ Mix)")))
        #expect(HomeFeed.isFromDJMix(track("Opus", album: "Global Underground: Mixed by Sasha")))
        #expect(HomeFeed.isFromDJMix(track("Intro", album: "Essential Mix: Continuous Mix")))
        #expect(!HomeFeed.isFromDJMix(track("Strobe (Extended Mix)", album: "For Lack of a Better Name")))
        #expect(!HomeFeed.isFromDJMix(track("Ghosts (Remixed)", album: "Ghosts Remixed")))
        #expect(!HomeFeed.isFromDJMix(track("Some Chords", album: "4x4=12")))

        // A genre with enough tracks only from a DJ mix gets no mix.
        let store = library((1...5).map { ("Bass \($0)", "Artist \($0)", 16, 44_100, "Dubstep") })
        store.tracks = store.tracks.map { var t = $0; t.album = "Bass Nation (DJ Mix)"; return t }
        #expect(build(store).mixes.isEmpty)
    }

    @Test func genreMixesNeedEnoughTracks() {
        let store = library((1...5).map { ("Bass \($0)", "Artist \($0)", 16, 44_100, "Dubstep") }
                            + [("Lonely", "Z", 16, 44_100, "Polka")])
        let mixes = build(store).mixes
        #expect(mixes.map(\.name) == ["Dubstep Mix"])
        #expect(mixes.first?.tracks.count == 15)
    }
}

@MainActor
struct MixCoverTests {
    @Test func savedCoverIsA1024SquareJPEG() throws {
        let mix = HomeFeed.Mix(id: "genre:dubstep", name: "Dubstep Mix", hue: 0, leadArtist: "Virtual Riot",
                               artists: ["Virtual Riot"], tracks: [])
        // A stand-in photo: a 600 × 800 gradient, so the art must crop it square.
        let image = NSImage(size: NSSize(width: 600, height: 800), flipped: false) { rect in
            NSGradient(starting: .white, ending: .darkGray)?.draw(in: rect, angle: 90)
            return true
        }
        let photo = image.tiffRepresentation
        let data = try #require(mix.coverJPEG(photo: photo))
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide == 1024 && rep.pixelsHigh == 1024)
        #expect(data.starts(with: [0xFF, 0xD8]))   // JPEG
        // Without a photo it's the mix's colour and name.
        #expect(mix.coverJPEG(photo: nil) != nil)
    }
}
