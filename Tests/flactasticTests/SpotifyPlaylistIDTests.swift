import Foundation
import Testing
@testable import flactastic

@Test func playlistIDAcceptsLinksAndURIs() {
    let id = "37i9dQZF1DXcBWIGoYBM5M"
    #expect(SpotifyPlaylistService.playlistID(from: URL(string: "https://open.spotify.com/playlist/\(id)?si=abc")!) == id)
    #expect(SpotifyPlaylistService.playlistID(from: URL(string: "https://open.spotify.com/intl-de/playlist/\(id)")!) == id)
    #expect(SpotifyPlaylistService.playlistID(from: URL(string: "spotify:playlist:\(id)")!) == id)
}

@Test func playlistIDRejectsAnythingButBase62() {
    #expect(SpotifyPlaylistService.playlistID(from: URL(string: "https://open.spotify.com/playlist/..%2F..%2Fme")!) == nil)
    #expect(SpotifyPlaylistService.playlistID(from: URL(string: "https://open.spotify.com/playlist/a%20b")!) == nil)
    #expect(SpotifyPlaylistService.playlistID(from: URL(string: "https://open.spotify.com/album/abc")!) == nil)
}
