import Foundation
import Testing
import CTagLib
@testable import flactastic

// Edit → write → rescan on real FLAC, MP3 and M4A files. A file in the old
// single-string format, saved unchanged through the editor's path, must read
// back with identical models and identical display output, and must now hold
// the list fields (ARTISTS, native GENRE values, FLACTASTIC_TAGVERSION=2).

/// Reads every value of `key` from the file at `url`.
func readPropertyList(_ url: URL, _ key: String) -> [String] {
    url.path.withCString { path in
        guard let file = taglib_file_new(path) else { return [] }
        defer { taglib_file_free(file) }
        return LibraryScanner.propertyList(file, key)
    }
}

/// Sets each key to the given values straight through TagLib (another
/// tagger, or FLACtastic's old single-string format).
@discardableResult
func writeRawProperties(_ url: URL, _ props: [(String, [String])]) -> Bool {
    url.path.withCString { path in
        guard let file = taglib_file_new(path) else { return false }
        defer { taglib_file_free(file) }
        for (key, values) in props {
            key.withCString { k in
                if values.isEmpty { taglib_property_set(file, k, nil) }
                for (i, v) in values.enumerated() {
                    v.withCString { i == 0 ? taglib_property_set(file, k, $0) : taglib_property_set_append(file, k, $0) }
                }
            }
        }
        return taglib_file_save(file) != 0
    }
}

/// Saves `track` through MetadataWriter exactly as the track editor would
/// when nothing was changed: chips back to text, genres as primary plus
/// secondaries.
func saveUnchanged(_ track: Track) async throws -> Track {
    try await MetadataWriter().write(
        to: track, title: track.title,
        artist: TagText.joined(TagText.chips(track.artist)),
        album: track.album, year: track.year,
        genre: track.genre, secondaryGenres: track.secondaryGenres,
        trackNumber: track.trackNumber,
        albumArtistChange: .set(TagText.joined(TagText.chips(track.albumArtist)))
    )
}

private struct ModelFields: Equatable {
    var title: String, artist: String?, albumArtist: String?, album: String?
    var genre: String?, secondaryGenres: [String], year: Int?, trackNumber: Int?
    init(_ t: Track) {
        title = t.title; artist = t.artist; albumArtist = t.albumArtist; album = t.album
        genre = t.genre; secondaryGenres = t.secondaryGenres; year = t.year; trackNumber = t.trackNumber
    }
}

private let oldFormatCases: [(name: String, props: [(String, [String])])] = [
    ("multi", [("TITLE", ["Ghosts n Stuff"]), ("ARTIST", ["Deadmau5 ; Rob Swire"]), ("ALBUMARTIST", ["Deadmau5 ; Kaskade"]),
               ("ALBUM", ["For Lack of a Better Name"]), ("GENRE", ["Electronic ; House ; Progressive House"]),
               ("DATE", ["2009"]), ("TRACKNUMBER", ["2"])]),
    ("download", [("TITLE", ["I Remember"]), ("ARTIST", ["Deadmau5; Kaskade"]), ("ALBUM", ["Random Album Title"]),
                  ("GENRE", ["House"]), ("DATE", ["2008"]), ("TRACKNUMBER", ["3"])]),
    ("single", [("TITLE", ["Mrs Robinson"]), ("ARTIST", ["Simon & Garfunkel"]), ("ALBUMARTIST", ["Simon & Garfunkel"]),
                ("ALBUM", ["Bookends"]), ("GENRE", ["Folk Rock"]), ("DATE", ["1968"]), ("TRACKNUMBER", ["1"])]),
]

@MainActor
private func roundTrip(ext: String) async throws {
    let dir = try FixtureSupport.makeTempDir("roundtrip-\(ext)")
    defer { try? FileManager.default.removeItem(at: dir) }
    for testCase in oldFormatCases {
        guard let url = try FixtureSupport.makeSilentAudio(ext: ext, in: dir, name: testCase.name) else { return }
        #expect(writeRawProperties(url, testCase.props))
        let scanner = LibraryScanner()
        let before = await scanner.loadMetadata(for: try #require(Track.makeFromURL(url)))

        let written = try await saveUnchanged(before)
        let after = await scanner.loadMetadata(for: try #require(Track.makeFromURL(url)))

        let label = "\(testCase.name).\(ext)"
        #expect(ModelFields(after) == ModelFields(before), "\(label): model changed")
        #expect(ModelFields(written) == ModelFields(after), "\(label): writer's track differs from a rescan")
        #expect(written.artistIsList == after.artistIsList && written.albumArtistIsList == after.albumArtistIsList, "\(label)")
        #expect(after.tagVersion == 2, "\(label): no TAGVERSION marker")
        let pre = DisplayBaseline.capture([before]), post = DisplayBaseline.capture([after])
        DisplayBaseline.expectMatches(post, pre)

        // The new list fields are on disk.
        let artists = MultiValueParser.values(ofStored: before.artist)
        if artists.count > 1 { #expect(readPropertyList(url, "ARTISTS") == artists, "\(label): ARTISTS") }
        else { #expect(readPropertyList(url, "ARTISTS").isEmpty, "\(label): stray ARTISTS") }
        let genres = MultiValueParser.values(ofStored: GenreResolver.join(primary: before.genre, secondary: before.secondaryGenres))
        #expect(readPropertyList(url, "GENRE") == genres, "\(label): GENRE not native values")
        #expect(readPropertyList(url, "FLACTASTIC_TAGVERSION") == ["2"], "\(label)")
    }
}

@MainActor
struct MultiValueRoundTripTests {
    @Test func flacRoundTrip() async throws { try await roundTrip(ext: "flac") }
    @Test(.enabled(if: FixtureSupport.ffmpegPath != nil, "ffmpeg not installed"))
    func mp3RoundTrip() async throws { try await roundTrip(ext: "mp3") }
    @Test func m4aRoundTrip() async throws { try await roundTrip(ext: "m4a") }

    /// Another tagger's display string ("A feat. B") next to its ARTISTS list
    /// survives a save that doesn't change the artists.
    @Test func foreignDisplayStringSurvivesUnrelatedEdit() async throws {
        let dir = try FixtureSupport.makeTempDir("foreign")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try #require(try FixtureSupport.makeSilentAudio(ext: "flac", in: dir))
        writeRawProperties(url, [("TITLE", ["Move for Me"]), ("ARTIST", ["Kaskade feat. Deadmau5"]),
                                 ("ARTISTS", ["Kaskade", "Deadmau5"]), ("GENRE", ["House"])])
        let before = await LibraryScanner().loadMetadata(for: try #require(Track.makeFromURL(url)))
        #expect(before.artist == "Kaskade ; Deadmau5")
        #expect(before.artistIsList)

        var renamed = before
        renamed.title = "Move for Me (Edit)"
        _ = try await saveUnchanged(renamed)
        #expect(readPropertyList(url, "ARTIST") == ["Kaskade feat. Deadmau5"])
        #expect(readPropertyList(url, "ARTISTS") == ["Kaskade", "Deadmau5"])
    }

    /// Going from several artists to one clears the plural tag, so it can't
    /// bring the old list back on the next scan.
    @Test func singleArtistClearsPlural() async throws {
        let dir = try FixtureSupport.makeTempDir("plural-clear")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try #require(try FixtureSupport.makeSilentAudio(ext: "flac", in: dir))
        writeRawProperties(url, [("TITLE", ["Song"]), ("ARTIST", ["A ; B"]), ("ARTISTS", ["A", "B"])])
        let track = await LibraryScanner().loadMetadata(for: try #require(Track.makeFromURL(url)))
        let written = try await MetadataWriter().write(to: track, title: "Song", artist: "C", album: nil, year: nil,
                                                       genre: nil, trackNumber: nil)
        #expect(written.artist == "C")
        #expect(readPropertyList(url, "ARTISTS").isEmpty)
        let reread = await LibraryScanner().loadMetadata(for: try #require(Track.makeFromURL(url)))
        #expect(reread.artist == "C")
    }
}

/// Writes `artists` through the writer's list code to a fresh FLAC that
/// first holds `props`, and returns the file.
private func writeArtists(_ artists: [String], over props: [(String, [String])], separator: String = ", ",
                          appendOnly: Bool = false, in dir: URL) throws -> URL {
    let url = try #require(try FixtureSupport.makeSilentAudio(ext: "flac", in: dir, name: UUID().uuidString))
    if !props.isEmpty { #expect(writeRawProperties(url, props)) }
    let saved: Bool = url.path.withCString { path in
        guard let file = taglib_file_new(path) else { return false }
        defer { taglib_file_free(file) }
        MetadataWriter.writeMultiValueFields(file, artist: .some(MultiValueParser.joinList(artists)), albumArtist: nil,
                                             genres: nil, appendOnly: appendOnly, separator: separator)
        return taglib_file_save(file) != 0
    }
    #expect(saved)
    return url
}

struct DisplaySeparatorTests {
    @Test func newFileUsesChosenSeparator() async throws {
        let dir = try FixtureSupport.makeTempDir("sep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let comma = try writeArtists(["Daft Punk", "Pharrell Williams"], over: [], in: dir)
        #expect(readPropertyList(comma, "ARTIST") == ["Daft Punk, Pharrell Williams"])
        #expect(readPropertyList(comma, "ARTISTS") == ["Daft Punk", "Pharrell Williams"])
        let slash = try writeArtists(["Daft Punk", "Pharrell Williams"], over: [], separator: " / ", in: dir)
        #expect(readPropertyList(slash, "ARTIST") == ["Daft Punk / Pharrell Williams"])

        // FLACtastic reads the list, and shows it as it always has.
        let track = await LibraryScanner().loadMetadata(for: try #require(Track.makeFromURL(comma)))
        #expect(track.artist == "Daft Punk ; Pharrell Williams")
        #expect(ArtistResolver.displayString(track.artist) == "Daft Punk, Pharrell Williams")
    }

    @Test func rewriteKeepsTheFilesOwnSeparator() throws {
        let dir = try FixtureSupport.makeTempDir("sep-keep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let slash = try writeArtists(["A", "B", "C"], over: [("ARTIST", ["A / B"])], in: dir)
        #expect(readPropertyList(slash, "ARTIST") == ["A / B / C"])
        let semi = try writeArtists(["A", "B", "C"], over: [("ARTIST", ["A; B"])], in: dir)
        #expect(readPropertyList(semi, "ARTIST") == ["A; B; C"])
        // "Host & Guest" was a list after all: the new artist joins it the same way.
        let amp = try writeArtists(["Host", "Guest", "Third"], over: [("ARTIST", ["Host & Guest"])], in: dir)
        #expect(readPropertyList(amp, "ARTIST") == ["Host & Guest & Third"])
        // "feat." isn't a list separator: the chosen one is used instead.
        let feat = try writeArtists(["A", "B", "C"], over: [("ARTIST", ["A feat. B"]), ("ARTISTS", ["A", "B"])], in: dir)
        #expect(readPropertyList(feat, "ARTIST") == ["A, B, C"])
        #expect(readPropertyList(feat, "ARTISTS") == ["A", "B", "C"])
    }

    @Test func unchangedArtistsLeaveTheStringAlone() throws {
        let dir = try FixtureSupport.makeTempDir("sep-same")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeArtists(["A", "B"], over: [("ARTIST", ["A ; B"])], in: dir)
        #expect(readPropertyList(url, "ARTIST") == ["A ; B"])
        #expect(readPropertyList(url, "ARTISTS") == ["A", "B"])
    }

    @Test func appendOnlyNeverTouchesTheSingularTag() throws {
        let dir = try FixtureSupport.makeTempDir("sep-append")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeArtists(["Calvin Harris", "Dua Lipa"], over: [("ARTIST", ["Calvin Harris & Dua Lipa"])],
                                   appendOnly: true, in: dir)
        #expect(readPropertyList(url, "ARTIST") == ["Calvin Harris & Dua Lipa"])
        #expect(readPropertyList(url, "ARTISTS") == ["Calvin Harris", "Dua Lipa"])
    }

    @Test func separatorDetection() {
        #expect(MultiValueParser.separator(in: "A / B", joining: ["A", "B"]) == " / ")
        #expect(MultiValueParser.separator(in: "A;B", joining: ["A", "B"]) == ";")
        #expect(MultiValueParser.separator(in: "A feat. B", joining: ["A", "B"]) == nil)
        #expect(MultiValueParser.separator(in: "A", joining: ["A"]) == nil)
    }
}
