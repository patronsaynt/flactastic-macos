import Foundation
import Testing
@testable import flactastic

@MainActor
struct DownloadSearchTests {
    @Test func linksAreToldApartFromSearches() {
        #expect(DownloadTabView.isLink("https://www.qobuz.com/us-en/album/x"))
        #expect(DownloadTabView.isLink("open.spotify.com/album/abc"))
        #expect(DownloadTabView.isLink("www.deezer.com/album/955070531"))
        #expect(DownloadTabView.isLink("  https://tidal.com/browse/album/1  "))
        #expect(!DownloadTabView.isLink("virtual riot"))
        #expect(!DownloadTabView.isLink("burning out virtual riot"))
        #expect(!DownloadTabView.isLink("deadmau5"))
        #expect(!DownloadTabView.isLink(""))
    }

    @Test func titlesMatchAcrossEditionSuffixesAndPunctuation() {
        #expect(LibraryOwnership.titleKey("Still Kids - EP") == LibraryOwnership.titleKey("Still Kids"))
        #expect(LibraryOwnership.titleKey("Drop Some EP") == LibraryOwnership.titleKey("Drop Some"))
        #expect(LibraryOwnership.titleKey("Sh*t's On F*re") == LibraryOwnership.titleKey("Sht's on Fre"))
        #expect(LibraryOwnership.titleKey("Café") == LibraryOwnership.titleKey("cafe"))
        #expect(LibraryOwnership.titleKey("Burning Out") != LibraryOwnership.titleKey("Burning"))
    }

    @Test func ownershipMarksAlbumsAndSongsInTheLibrary() {
        let library = LibraryStore()
        library.tracks = [
            Track(url: URL(fileURLWithPath: "/m/a/1.flac"), title: "Burning Out", artist: "Virtual Riot",
                  albumArtist: "Virtual Riot", album: "Burning Out", trackNumber: 1, duration: 179, fileFormat: .flac),
            Track(url: URL(fileURLWithPath: "/m/b/1.flac"), title: "Energy Drink", artist: "Virtual Riot & Friend",
                  albumArtist: "Someone Else", album: "Mix", trackNumber: 1, duration: 300, fileFormat: .flac),
        ]
        let owned = LibraryOwnership(library: library)

        #expect(owned.owns(result(.album, "Burning Out", by: "virtual riot")))
        #expect(!owned.owns(result(.album, "The Classics", by: "Virtual Riot")))
        #expect(owned.owns(result(.track, "Burning Out", by: "Virtual Riot")))
        // A credited artist on a track counts, even on someone else's album.
        #expect(owned.owns(result(.track, "Energy Drink", by: "Virtual Riot")))
        // The same title by another artist doesn't.
        #expect(!owned.owns(result(.album, "Burning Out", by: "Someone Else")))
    }

    /// Opened albums and Spotify playlists mark a track exactly when a
    /// download would skip it as a duplicate.
    @Test func playlistTracksAreMarkedByTheDownloadSkipRule() {
        let library = [
            Track(url: URL(fileURLWithPath: "/m/Virtual Riot/Burning Out/01 - Burning Out.flac"), title: "Burning Out",
                  artist: "Virtual Riot", albumArtist: "Virtual Riot", album: "Burning Out", trackNumber: 1, duration: 179, fileFormat: .flac),
        ]
        let owned = LibraryOwnership(tracks: library, resolver: LibraryStore().makeArtistResolver())
        let playlist = [
            remote("Burning Out", by: "Virtual Riot"),
            remote("Burning Out (Radio Edit)", by: "Virtual Riot"),
            remote("Burning Out", by: "Someone Else"),
            remote("Statues", by: "Virtual Riot"),
        ]
        let marks = playlist.map(owned.owns)
        // A radio edit is its own recording; so is the same title by someone else.
        #expect(marks == [true, false, false, false])
        #expect(marks == playlist.map { DownloadCoordinator.findExistingMatch(for: $0, in: library) != nil })
    }

    private func remote(_ title: String, by artist: String) -> RemoteTrack {
        RemoteTrack(id: title + artist, title: title, artists: [RemoteArtist(id: artist, name: artist, url: nil, pictureURL: nil)],
                    album: nil, trackNumber: nil, discNumber: nil, durationSeconds: 180, coverArt: [],
                    url: URL(string: "https://open.spotify.com/track/x"), serviceID: "lucida", isLossless: true)
    }

    private func result(_ kind: CatalogResult.Kind, _ title: String, by artist: String) -> CatalogResult {
        CatalogResult(id: UUID().uuidString, kind: kind, title: title, artist: artist, album: nil,
                      coverURL: nil, thumbnailURL: nil, trackCount: nil, durationSeconds: nil, year: nil,
                      isExplicit: false, link: URL(string: "https://www.deezer.com/album/1")!)
    }
}
