import Foundation
import Testing
@testable import flactastic

// The checklist on the confirmation sheet. Shared with iOS, so these rules —
// grouping, tri-state, and what goes on the wire — hold on both.

private func track(_ artist: String?, _ album: String?, _ path: String, bytes: Int64 = 100,
                   albumArtist: String? = nil) -> TrackManifestEntry {
    TrackManifestEntry(trackID: UUID(), relativePath: path, fileSize: bytes, contentHash: path,
                       format: .flac, tagFingerprint: "", title: path, artist: artist, album: album,
                       albumArtist: albumArtist)
}

@Test("An EP with featured artists stays one album under its album artist")
func picklistKeepsFeaturedTracksWithTheirAlbum() {
    // The reported bug: ticking the EP missed the tracks crediting guests.
    let picks = SyncPickList(plan: plan([
        track("Madeon", "Good Faith EP", "Madeon/Good Faith EP/01", albumArtist: "Madeon"),
        track("Madeon feat. Mark Foster", "Good Faith EP", "Madeon/Good Faith EP/02", albumArtist: "Madeon"),
        track("Madeon & Vic Mensa", "Good Faith EP", "Madeon/Good Faith EP/03", albumArtist: "Madeon"),
    ]))
    #expect(picks.artists.map(\.name) == ["Madeon"])
    let album = try! #require(picks.artists.first?.albums.first)
    #expect(album.tracks.count == 3)
    #expect(album.tracks[1].creditedArtist == "Madeon feat. Mark Foster")
    #expect(album.tracks[0].creditedArtist == nil)
}

@Test("Without an album-artist tag, an album is filed under its most credited artist")
func picklistUntaggedAlbumArtist() {
    let picks = SyncPickList(plan: plan([
        track("Porter Robinson", "Nurture EP", "PR/Nurture/01"),
        track("Porter Robinson", "Nurture EP", "PR/Nurture/02"),
        track("Porter Robinson feat. Totally Enormous", "Nurture EP", "PR/Nurture/03"),
    ]))
    #expect(picks.artists.map(\.name) == ["Porter Robinson"])
    #expect(picks.artists[0].albums.count == 1)
    #expect(picks.artists[0].albums[0].tracks.count == 3)
}

@Test("Same-titled albums in different folders stay separate")
func picklistSameTitleDifferentFolders() {
    let picks = SyncPickList(plan: plan([
        track("A", "Greatest Hits", "A/Greatest Hits/01"),
        track("B", "Greatest Hits", "B/Greatest Hits/01"),
    ]))
    #expect(picks.artists.map(\.name) == ["A", "B"])
}

private func plan(_ tracks: [TrackManifestEntry], playlists: [PlaylistManifestEntry] = []) -> SyncPlan {
    SyncPlan(direction: .pull, newTracks: tracks, trackConflicts: [], newPlaylists: playlists, playlistConflicts: [])
}

@Test("Tracks group by artist then album, case- and accent-insensitively")
func picklistGroups() {
    let picks = SyncPickList(plan: plan([
        track("Björk", "Homogenic", "b/h/02"),
        track("bjork ", "Homogenic", "b/h/01"),
        track("Radiohead", "OK Computer", "r/ok/01"),
        track(nil, nil, "loose"),
    ]))
    #expect(picks.artists.map(\.name) == ["Björk", "Radiohead", "Unknown Artist"])
    let bjork = picks.artists[0]
    #expect(bjork.albums.count == 1)
    // Ordered by path, which is disc/track order in an organised library.
    #expect(bjork.albums[0].tracks.map(\.entry.relativePath) == ["b/h/01", "b/h/02"])
    #expect(picks.artists[2].albums[0].title == "Unknown Album")
}

@Test("Changing nothing sends 'everything', not a list of IDs")
func picklistDefaultIsEverything() {
    let picks = SyncPickList(plan: plan([track("A", "X", "1"), track("A", "X", "2")]))
    #expect(picks.isEverything)
    #expect(picks.selection == .everything)
    #expect(picks.selectedTrackCount == 2)
    #expect(picks.selectedBytes == 200)
}

@Test("Unticking an album marks its artist as partly selected")
func picklistTriState() {
    var picks = SyncPickList(plan: plan([
        track("A", "X", "a/x/1"), track("A", "Y", "a/y/1"), track("A", "Y", "a/y/2"),
    ]))
    let artist = picks.artists[0]
    let albumY = artist.albums.first { $0.title == "Y" }!

    picks.toggle(albumY.trackIDs)
    #expect(picks.mark(albumY.trackIDs) == .none)
    #expect(picks.mark(artist.trackIDs) == .some)
    #expect(picks.selectedTrackCount == 1)
    #expect(!picks.isEverything)

    // Ticking a partly-ticked group ticks all of it.
    picks.toggle(artist.trackIDs)
    #expect(picks.mark(artist.trackIDs) == .all)
    #expect(picks.isEverything)
}

@Test("The wire selection lists exactly what is ticked")
func picklistSelection() {
    let keep = track("A", "X", "1"), drop = track("B", "Y", "2")
    let playlist = PlaylistManifestEntry(id: UUID(), name: "P", dateCreated: .now, entryCount: 0, contentHash: "")
    var picks = SyncPickList(plan: plan([keep, drop], playlists: [playlist]))

    picks.toggle([drop.trackID])
    #expect(picks.selection.trackIDs == [keep.trackID])
    #expect(picks.selection.playlistIDs == nil)      // playlists untouched → all

    picks.togglePlaylist(playlist.id)
    #expect(picks.selection.playlistIDs == [])
    #expect(!picks.isEmptySelection)

    picks.setEverything(false)
    #expect(picks.isEmptySelection)
    picks.setEverything(true)
    #expect(picks.selection == .everything)
}

@Test("Replacements are flagged in the checklist")
func picklistFlagsReplacements() {
    let incoming = track("A", "X", "1")
    let conflict = TrackConflict(incoming: incoming, existing: incoming, differingFields: ["Title", "Album"])
    let picks = SyncPickList(plan: SyncPlan(direction: .push, newTracks: [], trackConflicts: [conflict],
                                            newPlaylists: [], playlistConflicts: []))
    #expect(picks.artists[0].albums[0].tracks[0].replaces == "Title, Album")
}
