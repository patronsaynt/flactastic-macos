import Foundation
import Testing
@testable import flactastic

// Regression cover for the "For Lack of a Better Name" incident: an album with
// no ALBUMARTIST tag and one guest-credited track rolled up to the display-only
// label "Various Artists", the album editor then wrote that label to every file,
// and the Organizer filed the album under it.

// MARK: - primaryCredit

@Test func primaryCreditTakesLeadOfExplicitList() {
    #expect(ArtistResolver.primaryCredit("Deadmau5 ; Rob Swire") == "Deadmau5")
    #expect(ArtistResolver.primaryCredit("Deadmau5 ; Wolfgang Gartner") == "Deadmau5")
}

@Test func primaryCreditPassesSingleArtistThrough() {
    #expect(ArtistResolver.primaryCredit("Deadmau5") == "Deadmau5")
    #expect(ArtistResolver.primaryCredit("  Deadmau5  ") == "Deadmau5")
}

/// The narrow delimiter set is the point: names containing a comma or an "x"
/// must survive intact, which is why this doesn't reuse `MultiValueParser.splitAmbiguous`.
@Test func primaryCreditLeavesCommaNamesIntact() {
    #expect(ArtistResolver.primaryCredit("Tyler, The Creator") == "Tyler, The Creator")
    #expect(ArtistResolver.primaryCredit("AC/DC") == "AC/DC")
    #expect(ArtistResolver.primaryCredit("Above & Beyond") == "Above & Beyond")
}

@Test func primaryCreditHandlesITunesSlashDelimiter() {
    #expect(ArtistResolver.primaryCredit("Deadmau5 / Rob Swire") == "Deadmau5")
}

// MARK: - album roll-up

/// Mirrors the distinct-artist test in `LibraryStore.albums`: a guest credit on
/// one track must not make the album read as a compilation.
private func rollUpDisplayArtist(trackArtists: [String], albumArtistTag: String?) -> String? {
    if let albumArtistTag { return albumArtistTag }
    let distinct = Set(trackArtists.map(ArtistResolver.primaryCredit))
    if distinct.count > 1 { return "Various Artists" }
    return distinct.first
}

@Test func guestCreditDoesNotMakeAlbumVariousArtists() {
    let artists = Array(repeating: "Deadmau5", count: 9) + ["Deadmau5 ; Rob Swire"]
    #expect(rollUpDisplayArtist(trackArtists: artists, albumArtistTag: nil) == "Deadmau5")
}

@Test func genuinelyMixedAlbumStillReadsVariousArtists() {
    let artists = ["Deadmau5", "Eric Prydz", "Adam Beyer"]
    #expect(rollUpDisplayArtist(trackArtists: artists, albumArtistTag: nil) == "Various Artists")
}

@Test func explicitAlbumArtistTagAlwaysWins() {
    let artists = ["Deadmau5", "Eric Prydz"]
    #expect(rollUpDisplayArtist(trackArtists: artists, albumArtistTag: "deadmau5") == "deadmau5")
}
