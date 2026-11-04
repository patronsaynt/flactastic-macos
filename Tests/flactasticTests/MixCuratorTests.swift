import Foundation
import Testing
@testable import flactastic

@MainActor
struct MixCuratorTests {
    private func track(_ title: String, artist: String, genres: [String], year: Int? = 2010) -> Track {
        var t = Track(url: URL(fileURLWithPath: "/m/\(artist)/\(title).flac"), title: title, album: artist, fileFormat: .flac)
        t.artist = artist
        t.genre = genres.first
        t.secondaryGenres = Array(genres.dropFirst())
        t.year = year
        return t
    }

    private func curator(_ tracks: [Track], signals: MixCurator.Signals = .empty, events: [PlayEvent] = []) -> MixCurator {
        let store = LibraryStore()
        store.tracks = tracks
        return MixCurator(resolver: store.makeArtistResolver(), signals: signals, events: events,
                          tracks: tracks, artistMinutes: [:])
    }

    @Test func anotherGenreFamilyStaysOut() {
        // Hardcore dance and hardcore punk: both "Hardcore", different families.
        let dance = (1...8).map { track("Rave \($0)", artist: "DJ \($0 % 3)", genres: ["Hardcore", "Electronic"]) }
        let punk = track("Mosh", artist: "Minor Riot", genres: ["Hardcore", "Punk"])
        let c = curator(dance + [punk])
        let core = c.core(of: dance + [punk])
        #expect(core.tier != nil)
        if c.tier(punk) != core.tier { #expect(c.fit(punk, to: core) == nil) }
        #expect(c.fit(dance[0], to: core) != nil)
    }

    @Test func fullGenreSetsScoreCloserTracksHigher() {
        let ambient = (1...6).map { track("Drift \($0)", artist: "Calm \($0 % 2)", genres: ["Electronic", "Ambient"]) }
        let close = track("Haze", artist: "Other", genres: ["Electronic", "Ambient"])
        let far = track("Stomp", artist: "Other", genres: ["Electronic", "Breakcore"])
        let c = curator(ambient + [close, far])
        let core = c.core(of: ambient)
        #expect((c.fit(close, to: core) ?? 0) > (c.fit(far, to: core) ?? 0))
    }

    @Test func distantSoundIsAnOutlier() {
        let soft = SoundFingerprint(classes: ["music": 0.9, "piano": 0.6, "ambient": 0.5])
        let loud = SoundFingerprint(classes: ["speech": 0.9, "crowd": 0.8])
        let base = (1...6).map { track("Soft \($0)", artist: "A", genres: ["Electronic"]) }
        let odd = track("Odd", artist: "A", genres: ["Electronic"])
        var prints = Dictionary(uniqueKeysWithValues: base.map { ($0.url.path, soft) })
        prints[odd.url.path] = loud
        let c = curator(base + [odd], signals: .init(fingerprints: prints))
        #expect(c.fit(odd, to: c.core(of: base + [odd])) == nil)
    }

    @Test func rejectedTracksNeverComeBack() {
        let all = (1...20).map { track("T\($0)", artist: "A\($0 % 4)", genres: ["House"]) }
        let gone = all[3]
        let c = curator(all, signals: .init(rejected: ["genre:house": [gone.url.path]]))
        var rng = SeededRandom(seed: 1)
        let picked = c.pick(all, core: c.core(of: all), mixID: "genre:house", count: 20, rng: &rng)
        #expect(!picked.contains { $0.url.path == gone.url.path })
        #expect(picked.count >= 15)
    }

    @Test func artistsPlayedTogetherAreClose() {
        let a = track("x", artist: "Alpha", genres: ["House"]), b = track("y", artist: "Beta", genres: ["House"])
        let start = Date(timeIntervalSince1970: 1_000_000)
        let events = (0..<6).flatMap { i -> [PlayEvent] in
            let day = start.addingTimeInterval(Double(i) * 86_400)
            return [a, b].enumerated().map { j, t in
                PlayEvent(date: day.addingTimeInterval(Double(j) * 300), trackID: t.id, title: t.title,
                          artist: t.artist, albumID: nil, album: nil, genre: "House", secondaryGenres: [],
                          secondsListened: 240, counted: true)
            }
        }
        let c = curator([a, b], events: events)
        let ka = c.artistKey(a)!, kb = c.artistKey(b)!
        #expect(c.closeness(ka, kb) > 0.5)
    }
}
