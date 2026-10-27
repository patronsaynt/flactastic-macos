import Foundation
import Testing
@testable import flactastic

// MARK: - ReleaseLabel

@Test func releaseLabelPrefersTheLabelField() {
    #expect(ReleaseLabel.from(label: " Sub Pop ", copyright: "℗ 2020 Someone Else") == "Sub Pop")
}

@Test func releaseLabelReadsCopyrightLines() {
    #expect(ReleaseLabel.from(label: nil, copyright: "℗ 2026 NLV Records") == "NLV Records")
    #expect(ReleaseLabel.from(label: nil, copyright: "(P) 2019 Warp Records") == "Warp Records")
    #expect(ReleaseLabel.from(label: nil, copyright: "© 2001-2004 Ninja Tune") == "Ninja Tune")
    #expect(ReleaseLabel.from(label: nil, copyright: "2026 NLV Records") == "NLV Records")
    #expect(ReleaseLabel.from(label: nil, copyright: "Sub Pop Records, under exclusive license to Warner") == "Sub Pop Records")
}

@Test func releaseLabelIsNilWhenNothingUsable() {
    #expect(ReleaseLabel.from(label: "  ", copyright: nil) == nil)
    #expect(ReleaseLabel.from(label: nil, copyright: "℗ 2026") == nil)
}

// MARK: - Lucida metadata

private func decode(_ json: String) throws -> LucidaMetadata {
    try JSONDecoder().decode(LucidaMetadata.self, from: Data(json.utf8))
}

@Test func lucidaAlbumCarriesLabelAndDiscTotal() throws {
    let meta = try decode("""
    {"success": true, "type": "album", "title": "Box",
     "album": {"title": "Box", "label": {"name": "Sub Pop"}},
     "tracks": [{"title": "a", "discNumber": 1}, {"title": "b", "discNumber": 2}]}
    """)
    guard case .album(let album) = meta.toRemote(originalURL: URL(string: "https://example.com/a")!) else {
        Issue.record("expected an album"); return
    }
    #expect(album.tracks.map(\.discNumber) == [1, 2])
    #expect(album.tracks.first?.album?.label == "Sub Pop")
    #expect(album.tracks.first?.album?.discTotal == 2)
}

@Test func lucidaTrackFallsBackToCopyright() throws {
    let meta = try decode("""
    {"success": true, "type": "track", "title": "CSIRAC", "discNumber": 1,
     "album": {"title": "CSIRAC", "copyright": "℗ 2026 NLV Records"}}
    """)
    guard case .track(let track) = meta.toRemote(originalURL: URL(string: "https://example.com/t")!) else {
        Issue.record("expected a track"); return
    }
    #expect(track.album?.label == "NLV Records")
    #expect(track.discNumber == 1)
    #expect(track.album?.discTotal == nil)
}

/// An unexpected shape for either field must not sink the whole payload.
@Test func lucidaToleratesOddLabelShapes() throws {
    let meta = try decode("""
    {"success": true, "type": "track", "title": "x", "label": 42,
     "copyright": [{"text": "℗ 2020 Warp Records", "type": "P"}]}
    """)
    #expect(meta.releaseLabel == "Warp Records")
}
