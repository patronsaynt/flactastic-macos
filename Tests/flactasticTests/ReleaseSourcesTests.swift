import Foundation
import Testing
@testable import flactastic

@MainActor
struct ReleaseSourcesTests {
    @Test func servicesRankHiResFirstAndSpotifyLast() {
        let ranked = [
            "https://open.spotify.com/track/1", "https://www.deezer.com/track/2",
            "https://music.apple.com/us/album/x/1?i=3", "https://tidal.com/browse/track/4",
            "https://www.qobuz.com/us-en/album/y/5", "https://music.amazon.com/albums/B0",
        ].compactMap(URL.init(string:)).map(SourceService.init).sorted()
        #expect(ranked == [.qobuz, .tidal, .amazon, .deezer, .appleMusic, .spotify])
        #expect(SourceService(URL(string: "https://listen.tidal.com/album/1")!).isHiRes)
        #expect(!SourceService(URL(string: "https://www.deezer.com/album/1")!).isHiRes)
    }

    @Test func deezerLinksGiveTheirIDs() {
        #expect(DeezerCatalogSearch.id(in: URL(string: "https://www.deezer.com/album/799664331")!, kind: "album") == 799664331)
        #expect(DeezerCatalogSearch.id(in: URL(string: "https://www.deezer.com/us/track/3943657011")!, kind: "track") == 3943657011)
        #expect(DeezerCatalogSearch.id(in: URL(string: "https://www.deezer.com/album/1")!, kind: "track") == nil)
    }

    @Test func aTrackIsPickedByISRCThenPositionThenTitle() {
        let album = [
            track("Intro", number: 1, isrc: "AAA111"),
            track("Speed Run", number: 2, isrc: "BBB222"),
            track("Bound (Remastered)", number: 3, isrc: nil),
        ]
        #expect(ReleaseSources.pick(from: album, isrc: "bbb222", disc: 1, position: 9, title: "x")?.title == "Speed Run")
        #expect(ReleaseSources.pick(from: album, isrc: "ZZZ", disc: nil, position: 1, title: "x")?.title == "Intro")
        #expect(ReleaseSources.pick(from: album, isrc: nil, disc: 2, position: 1, title: "Bound - 2023 Remaster")?.title == "Bound (Remastered)")
        #expect(ReleaseSources.pick(from: album, isrc: nil, disc: nil, position: nil, title: "Missing") == nil)
    }

    @Test func droppedRequestsAreRetriedButRealRefusalsAreNot() {
        #expect(LucidaWebProvider.isTransient(StreamerError.unavailable("Load failed")))
        #expect(LucidaWebProvider.isTransient(StreamerError.unavailable("streamV2 HTTP 429")))
        #expect(LucidaWebProvider.isTransient(StreamerError.unavailable("Cannot read properties of undefined (reading 'name')")))
        #expect(!LucidaWebProvider.isTransient(StreamerError.unavailable("This release isn't available in your region")))
    }

    private func track(_ title: String, number: Int, isrc: String?) -> RemoteTrack {
        RemoteTrack(id: title, title: title, artists: [], album: nil, trackNumber: number, discNumber: 1,
                    durationSeconds: 200, coverArt: [], url: URL(string: "https://tidal.com/browse/track/\(number)"),
                    serviceID: "lucida", isLossless: true, isrc: isrc)
    }
}

@MainActor
struct RebuildFailureTests {
    @Test func aCombinedFailureIsPermanentOnlyWhenEverySourceIs() {
        let mixed = "Tried every source (Tidal, Deezer, Spotify) and none could download this track. Tidal: not found · Deezer: Load failed · Spotify: not found"
        let allGone = "Tried every source (Tidal, Spotify) and none could download this track. Tidal: not found · Spotify: unavailable in your region"
        #expect(!PlaylistRebuildCoordinator.isPermanentFailure(mixed))
        #expect(PlaylistRebuildCoordinator.isPermanentFailure(allGone))
        #expect(PlaylistRebuildCoordinator.isPermanentFailure("Track not found"))
        #expect(!PlaylistRebuildCoordinator.isPermanentFailure("streamV2 HTTP 429"))
    }
}
