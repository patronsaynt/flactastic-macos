import Foundation
import Testing
@testable import flactastic

// Tests for TagFingerprint, ContentHasher, and SyncFilter.
//
// The fingerprint decides whether the user gets shown an "this will overwrite"
// prompt. Too sensitive and every sync nags about whitespace; too loose and a
// real metadata difference gets overwritten without anyone being told. Both
// failure modes are covered below.

private func track(
    title: String = "Song",
    artist: String? = "Artist",
    albumArtist: String? = nil,
    album: String? = "Album",
    trackNumber: Int? = 1,
    genre: String? = "Electronic",
    secondaryGenres: [String] = [],
    year: Int? = 2002,
    isCompilation: Bool = false,
    isMixCompilation: Bool = false
) -> Track {
    Track(
        url: URL(fileURLWithPath: "/tmp/song.flac"),
        title: title, artist: artist, albumArtist: albumArtist, album: album,
        trackNumber: trackNumber, fileFormat: .flac, genre: genre,
        secondaryGenres: secondaryGenres, year: year,
        isCompilation: isCompilation, isMixCompilation: isMixCompilation
    )
}

// MARK: - Fingerprint sensitivity

@Test("Identical tags produce an identical fingerprint")
func fingerprintIsStable() {
    #expect(TagFingerprint.compute(for: track()) == TagFingerprint.compute(for: track()))
}

@Test("Every meaningful tag change moves the fingerprint")
func fingerprintDetectsRealChanges() {
    let baseline = TagFingerprint.compute(for: track())
    let variants: [(String, Track)] = [
        ("title",           track(title: "Different")),
        ("artist",          track(artist: "Other")),
        ("albumArtist",     track(albumArtist: "Various")),
        ("album",           track(album: "Other")),
        ("trackNumber",     track(trackNumber: 2)),
        ("genre",           track(genre: "Ambient")),
        ("secondaryGenres", track(secondaryGenres: ["IDM"])),
        ("year",            track(year: 2003)),
        ("isCompilation",   track(isCompilation: true)),
        ("isMixCompilation", track(isMixCompilation: true)),
    ]
    for (field, variant) in variants {
        #expect(TagFingerprint.compute(for: variant) != baseline, "\(field) did not affect the fingerprint")
    }
}

@Test("Cosmetic differences do not manufacture a conflict")
func fingerprintIgnoresCosmetics() {
    let baseline = TagFingerprint.compute(for: track())
    // Trailing whitespace, and NFD vs NFC spelling of the same name, are not
    // changes the user made — surfacing them as conflicts would train people
    // to click through the overwrite prompt without reading it.
    #expect(TagFingerprint.compute(for: track(title: "Song  ")) == baseline)
    #expect(TagFingerprint.compute(for: track(title: "\nSong")) == baseline)
}

@Test("Decomposed and precomposed spellings agree")
func fingerprintNormalisesUnicode() {
    let precomposed = TagFingerprint.compute(for: track(artist: "Bj\u{00F6}rk"))
    let decomposed  = TagFingerprint.compute(for: track(artist: "Bjo\u{0308}rk"))
    #expect(precomposed == decomposed)
}

@Test("A nil tag and an empty tag are the same thing")
func fingerprintTreatsNilAsEmpty() {
    #expect(TagFingerprint.compute(for: track(album: nil))
            == TagFingerprint.compute(for: track(album: "")))
}

@Test("Secondary genre order does not matter")
func fingerprintSortsSecondaryGenres() {
    #expect(TagFingerprint.compute(for: track(secondaryGenres: ["IDM", "Ambient"]))
            == TagFingerprint.compute(for: track(secondaryGenres: ["Ambient", "IDM"])))
}

@Test("Field values cannot forge a boundary and collide")
func fingerprintResistsFieldConfusion() {
    // Without a separator that cannot occur in a tag, "AB" + "" and "A" + "B"
    // would hash identically and two genuinely different tag sets would look
    // the same.
    #expect(TagFingerprint.compute(for: track(title: "AB", artist: ""))
            != TagFingerprint.compute(for: track(title: "A", artist: "B")))
}

@Test("The macOS-only mix flag is omitted rather than defaulted for iOS peers")
func fingerprintOmitsUnsetMixFlag() {
    // The iOS port has no isMixCompilation field, so it passes nil. That must
    // agree with a Mac sending false — otherwise every single track would look
    // like a conflict across platforms.
    let iOSStyle = TagFingerprint.compute(
        title: "Song", artist: "Artist", albumArtist: nil, album: "Album",
        trackNumber: 1, genre: "Electronic", secondaryGenres: [], year: 2002,
        isCompilation: false, isMixCompilation: nil
    )
    let macStyleFalse = TagFingerprint.compute(
        title: "Song", artist: "Artist", albumArtist: nil, album: "Album",
        trackNumber: 1, genre: "Electronic", secondaryGenres: [], year: 2002,
        isCompilation: false, isMixCompilation: false
    )
    #expect(iOSStyle == macStyleFalse)
}

// MARK: - ContentHasher

@Test("File hashing matches in-memory hashing")
func fileHashMatchesDataHash() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flactastic-hash-\(UUID().uuidString).bin")
    // Larger than one read chunk, so the streaming loop actually iterates.
    let payload = Data((0 ..< (ContentHasher.readChunkBytes + 4096)).map { UInt8($0 % 251) })
    try payload.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try ContentHasher.hexDigest(ofFileAt: url) == ContentHasher.hexDigest(of: payload))
}

@Test("An empty file hashes to the known empty SHA-256")
func emptyFileHash() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flactastic-hash-\(UUID().uuidString).bin")
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try ContentHasher.hexDigest(ofFileAt: url)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@Test("Digest comparison rejects mismatches and length differences")
func digestComparison() {
    let a = String(repeating: "a", count: 64)
    #expect(ContentHasher.digestsMatch(a, a))
    #expect(!ContentHasher.digestsMatch(a, String(repeating: "b", count: 64)))
    #expect(!ContentHasher.digestsMatch(a, "short"))
    #expect(!ContentHasher.digestsMatch(a, a + "a"))
}

// MARK: - SyncFilter

@Test("An unrestricted filter allows everything")
func unrestrictedFilterAllowsAll() {
    let filter = SyncFilter.unrestricted
    #expect(filter.allows(format: .flac, artistKey: "anyone", fileSize: .max))
    #expect(filter.allows(playlistID: UUID()))
    #expect(!filter.exceedsTotalCap(.max))
}

@Test("Each filter dimension excludes independently")
func filterDimensions() {
    #expect(!SyncFilter(excludedFormats: [.mp3]).allows(format: .mp3, artistKey: nil, fileSize: 1))
    #expect(SyncFilter(excludedFormats: [.mp3]).allows(format: .flac, artistKey: nil, fileSize: 1))

    let byArtist = SyncFilter(excludedArtistKeys: [ArtistResolver.key(for: "Bj\u{00F6}rk")])
    // Keying through ArtistResolver is what makes this survive the casing and
    // diacritic drift between two independently tagged libraries.
    #expect(!byArtist.allows(format: .flac, artistKey: ArtistResolver.key(for: "BJORK"), fileSize: 1))
    #expect(byArtist.allows(format: .flac, artistKey: ArtistResolver.key(for: "Boards of Canada"), fileSize: 1))

    let bySize = SyncFilter(maxFileSizeBytes: 1000)
    #expect(bySize.allows(format: .flac, artistKey: nil, fileSize: 1000))
    #expect(!bySize.allows(format: .flac, artistKey: nil, fileSize: 1001))
}

@Test("Playlist inclusion honours the switch and the allowlist")
func playlistFiltering() {
    let wanted = UUID(), unwanted = UUID()
    #expect(!SyncFilter(includePlaylists: false).allows(playlistID: wanted))
    let allowlisted = SyncFilter(playlistIDAllowlist: [wanted])
    #expect(allowlisted.allows(playlistID: wanted))
    #expect(!allowlisted.allows(playlistID: unwanted))
}

@Test("The per-run transfer cap is inclusive")
func totalCapIsInclusive() {
    let filter = SyncFilter(maxTotalTransferBytes: 1_000_000)
    #expect(!filter.exceedsTotalCap(1_000_000))
    #expect(filter.exceedsTotalCap(1_000_001))
}

@Test("A filter written by an older build still decodes")
func filterDecodesLegacyPayload() throws {
    // Matches the migration discipline in Library/Playlist.swift: every field
    // is optional on the way in, so a peer on an older protocol minor version
    // does not break the connection.
    let legacy = Data(#"{"excludedFormats":["mp3"]}"#.utf8)
    let filter = try JSONDecoder().decode(SyncFilter.self, from: legacy)
    #expect(filter.excludedFormats == [.mp3])
    #expect(filter.includePlaylists)          // defaulted, not nil
    #expect(filter.maxFileSizeBytes == nil)
}
