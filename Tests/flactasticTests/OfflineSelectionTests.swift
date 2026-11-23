import Foundation
import Testing
@testable import flactastic

// What stays on this Mac: albums, playlists or everything as the server
// picks them, plus tracks downloaded on their own, minus tracks removed one
// by one.

private func entry(_ id: UUID) -> TrackManifestEntry {
    TrackManifestEntry(trackID: id, relativePath: "\(id).flac", fileSize: 1, contentHash: id.uuidString,
                       format: .flac, tagFingerprint: "", title: "", artist: nil, album: nil)
}

@Test("Picked tracks join, removed tracks leave")
func wantedAddsPicksAndDropsExclusions() {
    let inAlbum = (0..<3).map { _ in UUID() }
    let picked = UUID(), notPicked = UUID()
    var selection = OfflineCopies.Selection()
    selection.trackIDs = [picked]
    selection.excludedTrackIDs = [inAlbum[1]]

    let wanted = selection.wanted(inAlbum.map(entry), extra: [entry(picked), entry(notPicked), entry(inAlbum[0])])
    #expect(Set(wanted.map(\.trackID)) == [inAlbum[0], inAlbum[2], picked])
    #expect(wanted.count == 3)   // no duplicates
}

@Test("A selection saved before picks and exclusions still loads")
func oldSelectionDecodes() throws {
    let album = "album-1"
    let json = #"{"everything":false,"albumIDs":["\#(album)"],"playlistIDs":[],"filter":\#(String(decoding: try JSONEncoder().encode(SyncFilter()), as: UTF8.self))}"#
    let selection = try JSONDecoder().decode(OfflineCopies.Selection.self, from: Data(json.utf8))
    #expect(selection.albumIDs == [album])
    #expect(selection.trackIDs.isEmpty)
    #expect(selection.excludedTrackIDs.isEmpty)
}

@Test("Picks and exclusions survive saving")
func selectionRoundTrips() throws {
    var selection = OfflineCopies.Selection()
    selection.trackIDs = [UUID()]
    selection.excludedTrackIDs = [UUID()]
    let back = try JSONDecoder().decode(OfflineCopies.Selection.self, from: JSONEncoder().encode(selection))
    #expect(back == selection)
}
