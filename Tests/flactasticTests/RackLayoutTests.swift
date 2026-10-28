import Foundation
import Testing
@testable import flactastic

private func album(_ id: String, label: String?) -> Album {
    Album(id: id, name: id, artist: "A", albumArtist: nil, year: 2020, genre: nil, label: label, secondaryGenres: [], artwork: nil,
          tracks: [Track(url: URL(fileURLWithPath: "/tmp/\(id).flac"), title: id, fileFormat: .flac)])
}

/// The rack rebuilds its layout when the album list's revision changes, even
/// when every album keeps its ID: an edited label must reach the spine.
@Test func rackLayoutKeysOnRevisionNotIDs() {
    let metrics = RackMetrics(available: CGSize(width: 1200, height: 600))
    let before = RackLayout(albums: [album("a", label: "Old")], revision: 1, sort: .label, metrics: metrics)
    let after = RackLayout(albums: [album("a", label: "New")], revision: 2, sort: .label, metrics: metrics)
    #expect(before.key != after.key)
    #expect(after.albums.first?.label == "New")
    #expect(after.tabs.first?.label == "New")
}

@Test func rackLayoutFindsAlbumsAndTracksByID() {
    let metrics = RackMetrics(available: CGSize(width: 1200, height: 600))
    let albums = (0..<5).map { album("a\($0)", label: nil) }
    let layout = RackLayout(albums: albums, revision: 1, sort: .album, metrics: metrics)
    #expect(layout.index(of: "a3") == 3)
    #expect(layout.index(of: "missing") == nil)
    #expect(layout.index(ofTrack: albums[4].tracks[0].id) == 4)
}

/// Many small groups don't pile their tabs on top of each other.
@Test func rackTabsDontOverlap() {
    let metrics = RackMetrics(available: CGSize(width: 1200, height: 600))
    let albums = (0..<40).map { album("a\($0)", label: "Some Long Record Label Name \($0)") }
    let layout = RackLayout(albums: albums, revision: 1, sort: .label, metrics: metrics)
    #expect(layout.tabs.count < albums.count)
    #expect(layout.tabs.allSatisfy { $0.label.count <= 22 })
    for (a, b) in zip(layout.tabs, layout.tabs.dropFirst()) {
        #expect(layout.x(of: b.firstIndex) - layout.x(of: a.firstIndex) >= CGFloat(a.label.count) * 7.4)
    }
}

/// The visible spines change in blocks of a dozen, not spine by spine.
@Test func rackVisibleRangeWidensToBlocks() {
    #expect(AlbumRackView.block(3..<20, count: 100) == 0..<24)
    #expect(AlbumRackView.block(13..<27, count: 30) == 12..<30)
    #expect(AlbumRackView.block(0..<0, count: 10).isEmpty)
}
