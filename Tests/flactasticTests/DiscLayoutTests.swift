import Foundation
import Testing
@testable import flactastic

// MARK: - DiscTag

@Test func discTagReadsPlainNumberAndSeparateTotal() {
    let disc = DiscTag.parse(number: "2", total: "3")
    #expect(disc.number == 2)
    #expect(disc.total == 3)
}

@Test func discTagReadsSlashForm() {
    let disc = DiscTag.parse(number: " 1/2 ", total: nil)
    #expect(disc.number == 1)
    #expect(disc.total == 2)
}

/// A separate DISCTOTAL wins over the "/n" half when both are present.
@Test func discTagPrefersSeparateTotal() {
    #expect(DiscTag.parse(number: "1/2", total: "4").total == 4)
}

@Test func discTagIgnoresZeroAndJunk() {
    let disc = DiscTag.parse(number: "0", total: "x")
    #expect(disc.number == nil)
    #expect(disc.total == nil)
    #expect(DiscTag.parse(number: nil, total: nil).number == nil)
}

// MARK: - DiscLayout

@Test func discLayoutFindsBreaksFromDiscNumbers() {
    #expect(DiscLayout.breaks(forDiscs: [1, 1, 2, 2, 3]) == [2, 4])
    #expect(DiscLayout.breaks(forDiscs: [nil, nil, nil]).isEmpty)
    // Untagged reads as disc 1.
    #expect(DiscLayout.breaks(forDiscs: [nil, 1, 2]) == [2])
}

@Test func discLayoutPlacesTracksOnDiscs() {
    let breaks: Set<Int> = [3, 5]
    #expect((0..<7).map { DiscLayout.disc(at: $0, breaks: breaks) } == [1, 1, 1, 2, 2, 3, 3])
}

@Test func discLayoutNumbersRestartPerDisc() {
    #expect(DiscLayout.trackNumbers(count: 6, breaks: [2, 5]) == [1, 2, 1, 2, 3, 1])
    #expect(DiscLayout.trackNumbers(count: 3, breaks: []) == [1, 2, 3])
}

@Test func discLayoutClampsBreaksToTheList() {
    #expect(DiscLayout.clamped([0, 2, 9], count: 4) == [2])
}

// MARK: - Album and sorting

private func track(_ title: String, disc: Int?, number: Int) -> Track {
    Track(url: URL(fileURLWithPath: "/tmp/\(title).flac"), title: title, album: "Box", trackNumber: number,
          fileFormat: .flac, discNumber: disc)
}

@Test func libraryOrderSortsByDiscBeforeTrackNumber() {
    let sorted = [track("b1", disc: 2, number: 1), track("a2", disc: 1, number: 2), track("a1", disc: 1, number: 1)]
        .sortedForLibrary()
    #expect(sorted.map(\.title) == ["a1", "a2", "b1"])
}

@Test func albumGroupsTracksByDisc() {
    let album = Album(id: "x", name: "Box", artist: nil, albumArtist: nil, year: nil, genre: nil, secondaryGenres: [],
                      artwork: nil, tracks: [track("a1", disc: 1, number: 1), track("b1", disc: 2, number: 1)])
    #expect(album.discs.map(\.number) == [1, 2])
    #expect(album.discs.map { $0.tracks.map(\.title) } == [["a1"], ["b1"]])
}

@Test func singleDiscAlbumHasNoDiscGroups() {
    let album = Album(id: "x", name: "Box", artist: nil, albumArtist: nil, year: nil, genre: nil, secondaryGenres: [],
                      artwork: nil, tracks: [track("a1", disc: nil, number: 1), track("a2", disc: 1, number: 2)])
    #expect(album.discs.isEmpty)
}

// MARK: - Metadata cache

/// Sidecar entries written before label and disc tags were cached must be
/// re-parsed, or those fields would hydrate as nil until the file changed.
@Test func metadataCacheEntryFromOlderSchemaIsStale() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("disc-cache-\(UUID().uuidString).flac")
    try Data([0]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    var entry = TrackMetadataCacheEntry(
        track: Track(url: url, title: "t", fileFormat: .flac, label: "Sub Pop", discNumber: 2, discTotal: 2),
        fileSize: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
        mtime: attrs[.modificationDate] as? Date ?? Date()
    )
    #expect(entry.isValid(forFileAt: url.path))
    var hydrated = Track(url: url, title: "", fileFormat: .flac)
    entry.apply(to: &hydrated)
    #expect(hydrated.label == "Sub Pop")
    #expect(hydrated.discNumber == 2)
    entry.schema = nil
    #expect(!entry.isValid(forFileAt: url.path))
}
