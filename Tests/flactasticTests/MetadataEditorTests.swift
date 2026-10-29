import Foundation
import Testing
@testable import flactastic

@Test func appleArtworkURLAsksForAnySize() {
    let thumb = "https://is1-ssl.mzstatic.com/image/thumb/Music124/v4/18/28/41/1828417c/802644721064.jpg/100x100bb.jpg"
    #expect(ArtworkFinder.appleArtworkURL(thumb, size: 3000)?.absoluteString
            == "https://is1-ssl.mzstatic.com/image/thumb/Music124/v4/18/28/41/1828417c/802644721064.jpg/3000x3000bb.jpg")
    #expect(ArtworkFinder.appleArtworkURL("https://example.com/cover.jpg", size: 3000) == nil)
}

@MainActor
@Test func removingTimingsKeepsTheWords() {
    let lrc = "[00:12.40] Sunlight on the lawn\n[01:02.5]Smoke rising\nPlain line"
    #expect(TrackMetadataEditorView.hasTimings(lrc))
    #expect(TrackMetadataEditorView.stripTimings(lrc) == "Sunlight on the lawn\nSmoke rising\nPlain line")
    #expect(!TrackMetadataEditorView.hasTimings("No timings here"))
}

@Test func artistChipsRoundTrip() {
    #expect(TagText.joined([" A ", "", "B"]) == ArtistResolver.joinExplicit(["A", "B"]))
    #expect(TagText.joined(["  "]) == nil)
    #expect(TagText.chips(nil).isEmpty)
    #expect(TagText.chips("Solo") == ["Solo"])
}

@MainActor
@Test func writeSessionRetriesOnlyWhatFailed() async {
    let session = MetadataWriteSession()
    let a = FileChange(id: UUID(), fileName: "a.flac", rows: [TagDiff(tag: "TITLE", old: "x", new: "y")])
    let b = FileChange(id: UUID(), fileName: "b.flac", rows: [TagDiff(tag: "TITLE", old: "x", new: "y")])
    var attempts: [String] = []
    struct Boom: Error {}
    let ok = await session.write([a, b]) { file in
        attempts.append(file.fileName)
        if file.fileName == "b.flac" { throw Boom() }
    }
    #expect(!ok)
    #expect(session.failedIDs == [b.id])
    #expect(session.phase == .reviewing)
    let retried = await session.write([a, b]) { file in attempts.append(file.fileName) }
    #expect(retried)
    #expect(attempts == ["a.flac", "b.flac", "b.flac"])
    #expect(session.phase == .finished)
}
