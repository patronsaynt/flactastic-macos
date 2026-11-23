import Foundation
import Testing
@testable import flactastic

// In a server library, music only on this Mac shows in the Collection but
// doesn't count toward Home, stats or the Fidelidex until it has uploaded.

@MainActor
private func track(_ title: String, album: String, root: String) -> Track {
    var t = Track(url: URL(fileURLWithPath: "\(root)/\(album)/\(title).flac"), title: title, album: album, fileFormat: .flac)
    t.artist = "Artist"
    return t
}

@MainActor
@Test("Local-only music is in the library but not counted")
func localOnlyIsNotCounted() {
    let store = LibraryStore()
    let onServer = [track("One", album: "Server Album", root: "/m"), track("Two", album: "Server Album", root: "/m")]
    let localOnly = track("Three", album: "Local Album", root: "/m")
    store.tracks = onServer
    store.setLocalExtras([localOnly])

    #expect(store.tracks.count == 3)
    #expect(Set(store.counted.tracks.map(\.title)) == ["One", "Two"])
    #expect(store.counted.albums.map(\.name) == ["Server Album"])
    #expect(store.albums.count == 2)

    // Uploaded: no longer an extra, so it counts.
    store.setLocalExtras([])
    #expect(store.counted.tracks.map(\.title).sorted() == ["One", "Two"])
}

@MainActor
@Test("A folder library counts everything")
func folderLibraryCountsAll() {
    let store = LibraryStore()
    store.tracks = [track("One", album: "A", root: "/m"), track("Two", album: "B", root: "/m")]
    #expect(store.counted.tracks.count == 2)
    #expect(store.counted.albums.count == 2)
}
