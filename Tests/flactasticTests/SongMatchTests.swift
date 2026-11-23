import Foundation
import Testing
@testable import flactastic

// A local file is "already on the server" when it's the same song, even if
// its bytes differ: then it isn't uploaded.

private func server(_ title: String, artist: String? = "Baby Keem", album: String? = "The Melodic Blue",
                    track: Int? = 1, disc: Int? = nil, duration: Double? = 200, format: String = "flac") throws -> ServerTrack {
    var json: [String: Any] = [
        "id": UUID().uuidString, "relativePath": "x/\(title).\(format)", "format": format,
        "fileSize": 1, "tagFingerprint": "", "title": title,
    ]
    if let artist { json["artist"] = artist }
    if let album { json["album"] = album }
    if let track { json["trackNumber"] = track }
    if let disc { json["discNumber"] = disc }
    if let duration { json["duration"] = duration }
    return try ServerClient.decoder.decode(ServerTrack.self, from: JSONSerialization.data(withJSONObject: json))
}

private func local(_ title: String, artist: String? = "Baby Keem", albumArtist: String? = nil, album: String? = "The Melodic Blue",
                   track: Int? = 1, disc: Int? = nil, duration: Double? = 200, format: AudioFileFormat = .flac) -> Track {
    var t = Track(url: URL(fileURLWithPath: "/m/\(title).flac"), title: title, album: album, fileFormat: format)
    t.artist = artist
    t.albumArtist = albumArtist
    t.trackNumber = track
    t.discNumber = disc
    t.duration = duration
    return t
}

@Test("Same song with different case, accents and punctuation matches")
func matchesLooseText() throws {
    let s = try server("Trademark USA", artist: "JAŸ-Z", album: "Magna Carta... Holy Grail")
    #expect(SongMatch.isSame(local("trademark usa", artist: "Jay Z", album: "Magna Carta Holy Grail"), s))
}

@Test("Album artist counts as the artist")
func matchesAlbumArtist() throws {
    let s = try server("Range Brothers", artist: "Baby Keem, Kendrick Lamar")
    #expect(SongMatch.isSame(local("range brothers", artist: "Someone Else", albumArtist: "Baby Keem, Kendrick Lamar"), s))
}

@Test("A different track number, disc, length or album isn't the same song")
func rejectsDifferences() throws {
    let s = try server("Intro", track: 1, disc: 1, duration: 200)
    #expect(!SongMatch.isSame(local("Intro", track: 2), s))
    #expect(!SongMatch.isSame(local("Intro", disc: 2), s))
    #expect(!SongMatch.isSame(local("Intro", duration: 205), s))
    #expect(!SongMatch.isSame(local("Intro", album: "Another Album"), s))
    #expect(SongMatch.isSame(local("Intro", duration: 201.5), s))
    // Missing numbers on one side don't rule it out.
    #expect(SongMatch.isSame(local("Intro", track: nil, disc: nil, duration: nil), s))
}

@Test("The same format is preferred")
func findPrefersSameFormat() throws {
    let mp3 = try server("Song", format: "mp3")
    let flac = try server("Song", format: "flac")
    let index = SongMatch.index([mp3, flac])
    #expect(SongMatch.find(local("Song", format: .flac), in: index)?.id == flac.id)
    #expect(SongMatch.find(local("Song", format: .mp3), in: index)?.id == mp3.id)
    #expect(SongMatch.find(local("Other"), in: index) == nil)
}
