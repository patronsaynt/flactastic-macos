import Foundation
import Testing
@testable import flactastic

@MainActor
struct ArtistSummaryTests {
    private func track(_ title: String, artist: String, album: String, albumArtist: String, n: Int) -> Track {
        Track(url: URL(fileURLWithPath: "/m/\(album)/\(n) \(title).flac"), title: title, artist: artist,
              albumArtist: albumArtist, album: album, trackNumber: n, duration: 180, fileFormat: .flac)
    }

    /// A guest spot on someone else's album must contribute only the tracks
    /// that credit the guest — not the whole album — to play / shuffle.
    @Test func appearsOnContributesOnlyCreditedTracks() throws {
        let library = LibraryStore()
        library.tracks = [
            track("Own 1", artist: "Guest", album: "Own Album", albumArtist: "Guest", n: 1),
            track("Own 2", artist: "Guest", album: "Own Album", albumArtist: "Guest", n: 2),
            track("Own 3", artist: "Guest", album: "Own Album", albumArtist: "Guest", n: 3),
            track("Host 1", artist: "Host", album: "Host Album", albumArtist: "Host", n: 1),
            track("Feature", artist: "Host feat. Guest", album: "Host Album", albumArtist: "Host", n: 2),
            track("Host 3", artist: "Host", album: "Host Album", albumArtist: "Host", n: 3),
            track("Host 4", artist: "Host & Guest", album: "Host Album", albumArtist: "Host", n: 4),
        ]
        let summaries = library.allArtists(resolver: library.makeArtistResolver())
        let guest = try #require(summaries.first { $0.displayName == "Guest" })

        #expect(guest.appearsOn.map(\.name) == ["Host Album"])
        #expect(guest.appearsOnTracks.map(\.title) == ["Feature", "Host 4"])
        #expect(guest.playableTracks.map(\.title) == ["Own 1", "Own 2", "Own 3", "Feature", "Host 4"])
        #expect(guest.trackCount == guest.playableTracks.count)

        // The host's own album still plays in full.
        let host = try #require(summaries.first { $0.displayName == "Host" })
        #expect(host.playableTracks.count == 4)
    }
}
