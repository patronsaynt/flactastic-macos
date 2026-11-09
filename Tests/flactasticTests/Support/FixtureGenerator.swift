import Foundation
import Testing
import CTagLib
@testable import flactastic

// Regenerates the committed audio fixtures in Tests/Fixtures/audio. Runs only
// with FLACTASTIC_GEN_FIXTURES=1, since the display baseline is recorded
// against these exact files:
//
//   FLACTASTIC_GEN_FIXTURES=1 swift test --filter FixtureGenerator
//
// "cur-" files are tagged by MetadataWriter, i.e. the app's own format at the
// time they were generated. "ext-" files are tagged straight through TagLib's
// property API, the way other taggers write native multi-values and plural
// tags.

private struct WriterSpec {
    var title: String
    var artist: String?
    var album: String?
    var albumArtist: String? = nil
    var genre: String? = nil
    var secondaryGenres: [String] = []
    var year: Int? = nil
    var track: Int? = nil
    var compilation: Bool = false
}

private let writerFixtures: [(file: String, spec: WriterSpec)] = [
    ("cur-single.flac", .init(title: "One More Time", artist: "Daft Punk", album: "Discovery", albumArtist: "Daft Punk", genre: "Electronic", year: 2001, track: 1)),
    ("cur-multi.flac", .init(title: "Ghosts n Stuff", artist: "Deadmau5 ; Rob Swire", album: "For Lack of a Better Name", albumArtist: "Deadmau5",
                             genre: "Electronic", secondaryGenres: ["House", "Progressive House"], year: 2009, track: 2)),
    ("cur-dl.flac", .init(title: "I Remember", artist: "Deadmau5; Kaskade", album: "Random Album Title", albumArtist: "Deadmau5", genre: "House", year: 2008, track: 3)),
    ("cur-dl-solo.flac", .init(title: "Faxing Berlin", artist: "Deadmau5", album: "Random Album Title", albumArtist: "Deadmau5", genre: "House", year: 2008, track: 1)),
    ("cur-aa-diff.mp3", .init(title: "Otis", artist: "Kanye West", album: "Watch the Throne", albumArtist: "Jay-Z ; Kanye West",
                              genre: "Hip-Hop", secondaryGenres: ["Rap"], year: 2011, track: 4)),
    ("cur-comp1.m4a", .init(title: "Comp Song One", artist: "Artist One", album: "Now Hits", genre: "Pop", year: 2010, track: 1, compilation: true)),
    ("cur-comp2.m4a", .init(title: "Comp Song Two", artist: "Artist Two ; Artist Three", album: "Now Hits", genre: "Pop", year: 2010, track: 2, compilation: true)),
    ("cur-host1.flac", .init(title: "Host Solo", artist: "Host", album: "Host Album", albumArtist: "Host", genre: "Soul", year: 2015, track: 1)),
    ("cur-host2.flac", .init(title: "Host and Guest", artist: "Host & Guest", album: "Host Album", albumArtist: "Host", genre: "Soul", year: 2015, track: 2)),
    ("cur-host3.mp3", .init(title: "Feature", artist: "Host feat. Guest", album: "Host Album", albumArtist: "Host", genre: "Soul", year: 2015, track: 3)),
    ("cur-guest.flac", .init(title: "Guest Solo", artist: "Guest", album: "Guest Album", albumArtist: "Guest", genre: "Soul ; R&B", year: 2016, track: 1)),
    ("cur-simon.mp3", .init(title: "Mrs Robinson", artist: "Simon & Garfunkel", album: "Bookends", albumArtist: "Simon & Garfunkel", genre: "Folk Rock", year: 1968, track: 1)),
    ("cur-tyler.m4a", .init(title: "See You Again", artist: "Tyler, The Creator", album: "Flower Boy", genre: "Hip-Hop", year: 2017, track: 6)),
    ("cur-acdc.flac", .init(title: "Back in Black", artist: "AC/DC", album: "Back in Black", albumArtist: "AC/DC", genre: "Hard Rock", year: 1980, track: 6)),
    ("cur-ewf.flac", .init(title: "September", artist: "Earth, Wind & Fire", album: "The Best of Earth, Wind & Fire", genre: "Funk", secondaryGenres: ["Soul", "Disco"], year: 1978, track: 1)),
    ("cur-dnb.mp3", .init(title: "Tarantula", artist: "Pendulum", album: "Hold Your Colour", genre: "Drum & Bass", year: 2005, track: 2)),
]

private let tagFixtures: [(file: String, props: [(String, [String])])] = [
    ("ext-native.flac", [("TITLE", ["Scenario"]), ("ARTIST", ["A Tribe Called Quest", "Busta Rhymes"]), ("ALBUM", ["The Low End Theory"]),
                         ("GENRE", ["Hip-Hop", "Jazz Rap"]), ("TRACKNUMBER", ["14"]), ("DATE", ["1991"])]),
    ("ext-native.m4a", [("TITLE", ["Get Lucky"]), ("ARTIST", ["Daft Punk", "Pharrell Williams"]), ("ALBUM", ["Random Access Memories"]),
                        ("GENRE", ["Disco"]), ("TRACKNUMBER", ["8"]), ("DATE", ["2013"])]),
    ("ext-native.mp3", [("TITLE", ["Under Pressure"]), ("ARTIST", ["Queen", "David Bowie"]), ("ALBUM", ["Hot Space"]),
                        ("GENRE", ["Rock", "Art Rock"]), ("TRACKNUMBER", ["11"]), ("DATE", ["1982"])]),
    ("ext-plural.flac", [("TITLE", ["Move for Me"]), ("ARTIST", ["Kaskade feat. Deadmau5"]), ("ARTISTS", ["Kaskade", "Deadmau5"]),
                         ("ALBUM", ["Strobelite Seduction"]), ("ALBUMARTIST", ["Kaskade"]), ("GENRE", ["House"]), ("TRACKNUMBER", ["5"])]),
    ("ext-plural.mp3", [("TITLE", ["Stay"]), ("ARTIST", ["Zedd & Alessia Cara"]), ("ARTISTS", ["Zedd", "Alessia Cara"]),
                        ("ALBUM", ["Stay"]), ("GENRE", ["Pop"]), ("TRACKNUMBER", ["1"])]),
    ("ext-slash.flac", [("TITLE", ["Raise Your Weapon"]), ("ARTIST", ["Deadmau5 / Greta Svabo Bech"]), ("ALBUM", ["4x4=12"]),
                        ("GENRE", ["Electronic / Dubstep"]), ("TRACKNUMBER", ["7"])]),
    ("ext-backslash.flac", [("TITLE", ["Lose Yourself to Dance"]), ("ARTIST", ["Daft Punk\\Pharrell Williams"]),
                            ("ALBUM", ["Random Access Memories"]), ("GENRE", ["Disco"]), ("TRACKNUMBER", ["6"])]),
    ("ext-mbid.flac", [("TITLE", ["One Kiss"]), ("ARTIST", ["Calvin Harris & Dua Lipa"]), ("ALBUM", ["One Kiss"]), ("GENRE", ["House"]),
                       ("MUSICBRAINZ_ARTISTID", ["8dd98bdc-80ec-4e93-8509-2f46bafc09a7", "6f1a58bf-9b1b-49cf-a44a-6cefad7ae04f"]),
                       ("TRACKNUMBER", ["1"])]),
    ("ext-comma.flac", [("TITLE", ["Ice Ice Baby"]), ("ARTIST", ["Unknown One, Unknown Two"]), ("ALBUM", ["Commas"]), ("GENRE", ["Rock, Pop"]),
                        ("TRACKNUMBER", ["1"])]),
    ("ext-semicolon.mp3", [("TITLE", ["Semis"]), ("ARTIST", ["Alpha;Beta"]), ("ALBUMARTIST", ["Alpha;Beta"]), ("ALBUM", ["Semis"]),
                           ("GENRE", ["Trance;Techno"]), ("TRACKNUMBER", ["1"])]),
]

private func applyProperties(_ props: [(String, [String])], to url: URL) -> Bool {
    url.path.withCString { path in
        guard let file = taglib_file_new(path) else { return false }
        defer { taglib_file_free(file) }
        guard taglib_file_is_valid(file) != 0 else { return false }
        for (key, values) in props {
            for (i, value) in values.enumerated() {
                key.withCString { k in
                    value.withCString { v in
                        if i == 0 { taglib_property_set(file, k, v) } else { taglib_property_set_append(file, k, v) }
                    }
                }
            }
        }
        return taglib_file_save(file) != 0
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["FLACTASTIC_GEN_FIXTURES"] == "1", "set FLACTASTIC_GEN_FIXTURES=1 to regenerate"))
func generateTagFixtures() async throws {
    let fm = FileManager.default
    let out = FixtureSupport.audioDir
    try? fm.removeItem(at: out)
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    let work = try FixtureSupport.makeTempDir("fixturegen")
    defer { try? fm.removeItem(at: work) }

    let writer = MetadataWriter()
    for (file, spec) in writerFixtures {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        let src = try #require(try FixtureSupport.makeSilentAudio(ext: ext, in: work, name: name), "no encoder for \(ext)")
        let dest = out.appendingPathComponent(file)
        try fm.moveItem(at: src, to: dest)
        let track = try #require(Track.makeFromURL(dest))
        _ = try await writer.write(
            to: track, title: spec.title, artist: spec.artist, album: spec.album, year: spec.year,
            genre: spec.genre, secondaryGenres: spec.secondaryGenres, trackNumber: spec.track,
            albumArtistChange: spec.albumArtist.map { .set($0) } ?? .unchanged,
            compilationChange: spec.compilation ? .set(true) : .unchanged
        )
    }
    for (file, props) in tagFixtures {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        let src = try #require(try FixtureSupport.makeSilentAudio(ext: ext, in: work, name: name), "no encoder for \(ext)")
        let dest = out.appendingPathComponent(file)
        try fm.moveItem(at: src, to: dest)
        #expect(applyProperties(props, to: dest), "couldn't tag \(file)")
    }
}
