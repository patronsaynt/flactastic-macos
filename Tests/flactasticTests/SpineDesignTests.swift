import AppKit
import CoreText
import Foundation
import Testing
@testable import flactastic

private func roll(
    artist: String = "Nova Halden", title: String = "Glasshouse", genres: [String] = ["Shoegaze"],
    label: String? = nil, year: Int? = 2020, discs: Int = 1, shuffles: Int = 0,
    options: SpineDesign.Options = SpineDesign.Options(currentYear: 2026)
) -> SpineDesign {
    SpineDesign.roll(artist: artist, title: title, genres: genres, label: label, year: year, discCount: discs,
                     shuffles: shuffles, options: options)
}

// MARK: - Seeding

@Test func spineRollIsStableForTheSameAlbum() {
    #expect(roll() == roll())
}

@Test func shufflingRollsADifferentSpine() {
    let designs = Set((0..<8).map { "\(roll(shuffles: $0))" })
    #expect(designs.count > 1)
}

@Test func differentAlbumsRollDifferentSpines() {
    let titles = ["Afterglow", "Blue Hour", "Driftwood", "Northbound", "Run Club", "Small Hours"]
    #expect(Set(titles.map { "\(roll(title: $0))" }).count > 1)
}

@Test func spineRandomStaysInRange() {
    var r = SpineRandom(key: "x", shuffles: 3)
    for _ in 0..<1000 {
        let v = r.next()
        #expect(v >= 0 && v < 1)
    }
}

// MARK: - Variety and themes

@Test func uniformVarietyIsOneTidyInsert() {
    let options = SpineDesign.Options(variety: .uniform, currentYear: 2026)
    for title in ["A", "B", "C", "D"] {
        let d = roll(title: title, options: options)
        #expect(!d.isLong)
        #expect(d.position == .center)
        #expect(d.fill == .paper)
        #expect(d.edge == .straight)
        #expect(!d.artistOnArt)
        #expect(d.askew == 0)
        #expect(d.font == GenreTier.raw.fonts[0])
    }
}

@Test func artistSeriesSharesOneDesignPerArtist() {
    let options = SpineDesign.Options(theme: .artistSeries, currentYear: 2026)
    let a = roll(title: "One", year: 2020, options: options)
    let b = roll(title: "Two", year: 2020, options: options)
    #expect(a.isLong == b.isLong && a.position == b.position && a.edge == b.edge && a.font == b.font)
    #expect(a.fill == .art && b.fill == .art)
}

@Test func labelHouseSharesOneDesignPerLabel() {
    let options = SpineDesign.Options(theme: .labelHouse, currentYear: 2026)
    let a = roll(artist: "One", title: "A", label: "Sub Pop", options: options)
    let b = roll(artist: "Two", title: "B", label: "Sub Pop", options: options)
    #expect(a.isLong == b.isLong && a.position == b.position && a.edge == b.edge && a.fill == b.fill)
}

@Test func longInsertsKeepTheArtistOnTheCard() {
    for n in 0..<40 {
        let d = roll(shuffles: n)
        if d.isLong { #expect(!d.artistOnArt) }
    }
}

// MARK: - Fonts and genres

@Test func genreTiersMatchKeywords() {
    #expect(GenreTier.of(["Black Metal"]) == .heavy)
    #expect(GenreTier.of(["Pop Punk"]) == .raw)
    #expect(GenreTier.of(["Jazz Rap"]) == .street)
    #expect(GenreTier.of(["Electronic"]) == .electric)
    #expect(GenreTier.of(["Neo-Soul"]) == .smooth)
    #expect(GenreTier.of(["Singer-Songwriter"]) == .classic)
    #expect(GenreTier.of(["Spoken Word"]) == nil)
    // Falls through to a secondary genre.
    #expect(GenreTier.of(["Spoken Word", "Ambient"]) == .smooth)
}

@Test func unknownGenreKeepsTheAppFace() {
    #expect(roll(genres: []).font == nil)
    #expect(roll(genres: ["Spoken Word"]).font == nil)
}

/// Every face's PostScript name must match the file it ships in, or
/// `Font.custom` silently falls back to the system font.
@Test func bundledSpineFontsResolveByPostScriptName() throws {
    let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/flactastic/Resources/SpineFonts")
    let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
    var names = Set<String>()
    for url in urls {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        for d in descriptors {
            if let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String { names.insert(name) }
        }
    }
    for face in SpineFont.allCases {
        #expect(names.contains(face.postScriptName), "\(face) → \(face.postScriptName)")
    }
}

/// Registers the bundled faces from the source tree, as the app does from
/// its resource bundle at launch.
private func registerSpineFontsFromSource() throws {
    let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/flactastic/Resources/SpineFonts")
    for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

@Test func faceCoverageSpotsMissingCharacters() throws {
    try registerSpineFontsFromSource()
    #expect(SpineFonts.covers(.chomsky, "Night Swim 1984"))
    #expect(!SpineFonts.covers(.stampede, "1984"))
    #expect(!SpineFonts.covers(.chomsky, "영원한 행복"))
}

/// A title a rolled face can't set moves to another face in its group, and
/// one no face can set (Korean here) stays in the app's own face.
@Test func titlesOnlyGetFacesThatCanSetThem() throws {
    try registerSpineFontsFromSource()
    for n in 0..<40 {
        let d = roll(title: "Night Swim 1984", genres: ["Doom Metal"], shuffles: n)
        if let font = d.font { #expect(SpineFonts.covers(font, "Night Swim 1984") || d.lettering != .tagged) }
        #expect(d.font != .stampede || d.lettering != .tagged)
    }
    #expect(roll(title: "영원한 행복", genres: ["Doom Metal"]).font == nil)
}

// MARK: - Age, labels, discs

@Test func ageRisesWithReleaseYear() {
    #expect(roll(year: 2025).age == 0)
    let old = roll(year: 1979).age
    #expect(old > 0.9 && old <= 1)
    #expect(roll(year: nil).age == 0)
    #expect(roll(year: 1979, options: SpineDesign.Options(ageWithYear: false, currentYear: 2026)).age == 0)
}

@Test func labelMarkFollowsTheSetting() {
    #expect(roll(label: "NLV Records").mark?.monogram == "NL")
    #expect(roll(label: "NLV Records").mark?.kind == .badge)
    #expect(roll(label: "Sub Pop", options: SpineDesign.Options(labelMark: .band, currentYear: 2026)).mark?.kind == .band)
    #expect(roll(label: "Sub Pop", options: SpineDesign.Options(labelMark: .off, currentYear: 2026)).mark == nil)
    #expect(roll(label: nil).mark == nil)
    #expect(roll(label: "★ ✦").mark == nil)
}

/// A label's mark looks the same on all its albums; only its end varies.
@Test func labelMarkIsDrawnTheLabelsWay() {
    let marks = ["A", "B", "C", "D", "E", "F"].compactMap { roll(artist: $0, title: $0, label: "Sub Pop").mark }
    #expect(Set(marks.map { "\($0.shape)\($0.face)\($0.style)" }).count == 1)
    let labels = ["Sub Pop", "Warp", "Ninja Tune", "4AD", "XL", "Domino", "Matador", "Merge"]
    #expect(Set(labels.compactMap { roll(label: $0).mark.map { "\($0.shape)\($0.face)" } }).count > 1)
    let ends = Set((0..<30).compactMap { roll(title: "T\($0)", label: "Sub Pop").mark?.end })
    #expect(ends == [.top, .bottom])
    #expect(roll(label: "Sub Pop", options: SpineDesign.Options(variety: .uniform, currentYear: 2026)).mark?.end == .bottom)
}

@Test func monogramsSkipGenericWords() {
    #expect(SpineDesign.monogram("Sub Pop Records") == "SP")
    #expect(SpineDesign.monogram("The Warp Records") == "WA")
    #expect(SpineDesign.monogram("4AD") == "4A")
    #expect(SpineDesign.monogram("Records") == "RE")
}

@Test func discCountCarriesThrough() {
    #expect(roll(discs: 3).discCount == 3)
}

// MARK: - Genre groups

@Test func genreGroupsMoveAndAddKeywords() {
    var groups = GenreGroups()
    #expect(groups.tier(for: ["Pop Punk"]) == .raw)
    groups.move("pop punk", to: .electric)
    #expect(groups.tier(for: ["Pop Punk"]) == .electric)
    // Moving a built-in keyword takes it out of its home group.
    groups.move("rock", to: .classic)
    #expect(groups.tier(for: ["Soft Rock"]) == .classic)
    #expect(!groups.keywords(in: .raw).contains("rock"))
    #expect(groups.keywords(in: .classic).contains("rock"))
    // Moving it home again clears the change.
    groups.move("rock", to: .raw)
    #expect(groups.assigned["rock"] == nil)
    // A keyword of the person's own.
    groups.move("Hyperpop", to: .street)
    #expect(groups.isCustom("hyperpop"))
    #expect(groups.tier(for: ["hyperpop"]) == .street)
    groups.remove("hyperpop")
    #expect(groups.tier(for: ["hyperpop"]) == .electric)
    // Built-in keywords can only be moved, not removed.
    groups.remove("metal")
    #expect(groups.tier(for: ["Metal"]) == .heavy)
}

@Test func genreGroupsSurviveEncoding() throws {
    var groups = GenreGroups()
    groups.move("vaporwave", to: .smooth)
    let decoded = try JSONDecoder().decode(GenreGroups.self, from: JSONEncoder().encode(groups))
    #expect(decoded == groups)
}

@Test func switchedOffFacesAreNeverRolled() {
    let off = Set(GenreTier.raw.fonts.dropFirst())
    let options = SpineDesign.Options(currentYear: 2026, disabledFaces: off)
    for n in 0..<30 {
        #expect(roll(shuffles: n, options: options).font == GenreTier.raw.fonts[0])
    }
    let allOff = SpineDesign.Options(currentYear: 2026, disabledFaces: Set(GenreTier.raw.fonts))
    #expect(roll(options: allOff).font == nil)
}

// MARK: - Overrides and logos

@Test func lockedChoicesBeatTheRoll() {
    var o = SpineOverrides()
    o.isLong = true
    o.position = .bottom
    o.fill = .custom(hex: "#336699")
    o.edge = .ruled
    o.font = .face(.cinzel)
    o.lettering = .caps
    o.separator = .rule
    for n in 0..<12 {
        let d = SpineDesign.roll(artist: "A", title: "T\(n)", genres: ["Punk"], label: nil, year: 2020, discCount: 1,
                                 shuffles: n, options: SpineDesign.Options(currentYear: 2026), overrides: o)
        #expect(d.isLong && d.position == .bottom && d.fill == .custom(hex: "#336699") && d.edge == .ruled)
        #expect(d.font == .cinzel && d.lettering == .caps && d.separator == .rule)
    }
    #expect(o.lockedCount == 7)
    var system = SpineOverrides()
    system.font = .system
    #expect(roll(options: SpineDesign.Options(currentYear: 2026)).font != nil)
    #expect(SpineDesign.roll(artist: "Nova Halden", title: "Glasshouse", genres: ["Shoegaze"], label: nil, year: 2020, discCount: 1,
                             shuffles: 0, options: SpineDesign.Options(currentYear: 2026), overrides: system).font == nil)
}

@Test func artistOnArtLockKeepsTheBandShort() {
    var o = SpineOverrides()
    o.artistOnArt = true
    for n in 0..<20 {
        let d = SpineDesign.roll(artist: "A", title: "T\(n)", genres: [], label: nil, year: nil, discCount: 1,
                                 shuffles: n, options: SpineDesign.Options(currentYear: 2026), overrides: o)
        #expect(d.artistOnArt && !d.isLong)
    }
}

@Test func overridesSurviveEncoding() throws {
    var o = SpineOverrides()
    o.fill = .custom(hex: "#abcdef")
    o.font = .face(.dufay)
    o.markEnd = .top
    let decoded = try JSONDecoder().decode(SpineOverrides.self, from: JSONEncoder().encode(o))
    #expect(decoded == o)
}

@Test func logosReachTheDesignByName() {
    let options = SpineDesign.Options(currentYear: 2026, artistLogos: ["nova halden": "a.png"], labelLogos: ["sub pop": "l.png"])
    let d = roll(label: "Sub Pop", options: options)
    #expect(d.artistLogos == ["a.png"])
    #expect(d.labelLogo == "l.png")
    #expect(roll(artist: "Someone Else", options: options).artistLogos == [nil])
}

// MARK: - Spine scans

@Test func spineScanFilesAreFoundByName() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(SpineScanCache.scanFile(in: dir) == nil)
    for name in ["cover.jpg", "01 Track.flac", "spinel.png"] {
        try Data([0]).write(to: dir.appendingPathComponent(name))
    }
    #expect(SpineScanCache.scanFile(in: dir) == nil)
    try Data([0]).write(to: dir.appendingPathComponent("CD Spine.JPG"))
    #expect(SpineScanCache.scanFile(in: dir)?.lastPathComponent == "CD Spine.JPG")
}

/// Long Insert and Artist on the Art can't both hold; Edit Spine keeps only
/// the latest, and if both ever arrive the artist wins rather than either
/// silently snapping back.
@Test func artistOnTheArtWinsOverALongInsert() {
    var o = SpineOverrides()
    o.isLong = true
    o.artistOnArt = true
    let d = SpineDesign.roll(artist: "A", title: "T", genres: [], label: nil, year: nil, discCount: 1,
                             shuffles: 0, options: SpineDesign.Options(currentYear: 2026), overrides: o)
    #expect(d.artistOnArt && !d.isLong)
}

@Test func logoTintsReachTheDesign() {
    let options = SpineDesign.Options(
        currentYear: 2026, artistLogos: ["nova halden": "a.png"], labelLogos: ["sub pop": "l.png"],
        artistLogoTints: ["nova halden": .cover], labelLogoTints: [:]
    )
    let d = roll(label: "Sub Pop", options: options)
    #expect(d.artistLogoTints == [.cover])
    #expect(d.labelLogoTint == .auto)
    #expect(d.logoTintRoll >= 0 && d.logoTintRoll < 1)
}

@Test func logoTintsSurviveEncoding() throws {
    let tints: [String: LogoTint] = ["sub pop": .original, "warp": .white]
    #expect(try JSONDecoder().decode([String: LogoTint].self, from: JSONEncoder().encode(tints)) == tints)
}

// MARK: - Design cache

@MainActor
@Test func designCacheFollowsWhatTheDesignDependsOn() {
    let track = Track(url: URL(fileURLWithPath: "/tmp/c.flac"), title: "t", album: "Glasshouse", fileFormat: .flac)
    let album = Album(id: "c", name: "Glasshouse", artist: "Nova Halden", albumArtist: nil, year: 2020, genre: "Shoegaze",
                      secondaryGenres: [], artwork: nil, tracks: [track])
    let cache = SpineDesignCache.shared
    let options = SpineDesign.Options(currentYear: 2026)
    let first = cache.design(for: album, credit: "Nova Halden", shuffles: 0, options: options)
    #expect(first == SpineDesign.roll(for: album, credit: "Nova Halden", shuffles: 0, options: options))
    // Shuffles, locks and settings each give the design rolled for them.
    #expect(cache.design(for: album, credit: "Nova Halden", shuffles: 3, options: options)
            == SpineDesign.roll(for: album, credit: "Nova Halden", shuffles: 3, options: options))
    var locked = SpineOverrides()
    locked.edge = .ruled
    #expect(cache.design(for: album, credit: "Nova Halden", shuffles: 0, options: options, overrides: locked).edge == .ruled)
    let uniform = SpineDesign.Options(variety: .uniform, currentYear: 2026)
    #expect(cache.design(for: album, credit: "Nova Halden", shuffles: 0, options: uniform).position == .center)
    // A disc break changes the album, and its disc mark.
    var two = track
    two.discNumber = 2
    let boxed = Album(id: "c", name: "Glasshouse", artist: "Nova Halden", albumArtist: nil, year: 2020, genre: "Shoegaze",
                      secondaryGenres: [], artwork: nil, tracks: [track, two])
    #expect(cache.design(for: boxed, credit: "Nova Halden", shuffles: 0, options: options).discCount == 2)
}

@MainActor
@Test func spineFontsReportReadyAfterRegistering() async throws {
    SpineFonts.register()
    for _ in 0..<50 where !SpineFontsState.shared.isReady {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(SpineFontsState.shared.isReady)
}

// MARK: - Hidden parts

@Test func hiddenPartsLeaveTheDesign() {
    var o = SpineOverrides()
    o.hidden = [.labelMark, .discCount, .wear, .title]
    let d = SpineDesign.roll(artist: "A", title: "T", genres: [], label: "Sub Pop", year: 1975, discCount: 3,
                             shuffles: 0, options: SpineDesign.Options(currentYear: 2026), overrides: o)
    #expect(d.mark == nil)
    #expect(d.discCount == 1)
    #expect(d.age == 0)
    #expect(d.hidden.contains(.title))
    #expect(!o.isEmpty)
    #expect(o.lockedCount == 0)
}

/// Overrides saved before parts could be hidden still load.
@Test func overridesFromBeforeHidingStillDecode() throws {
    let old = Data(#"{"edge":"torn","position":"top"}"#.utf8)
    let o = try JSONDecoder().decode(SpineOverrides.self, from: old)
    #expect(o.edge == .torn)
    #expect(o.hiddenElements.isEmpty)
}

// MARK: - Several artists and the art's position

/// Each artist keeps their own logo and colouring; the others print their
/// names.
@Test func eachArtistGetsTheirOwnLogo() {
    let options = SpineDesign.Options(currentYear: 2026, artistLogos: ["isoxo": "x.png"], artistLogoTints: ["isoxo": .white])
    let d = SpineDesign.roll(artist: "ISOKNOCK ; ISOxo ; Knock2", title: "4EVR", genres: [], label: nil, year: 2024, discCount: 1,
                             shuffles: 0, options: options, artists: ["ISOKNOCK", "ISOxo", "Knock2"])
    #expect(d.artists == ["ISOKNOCK", "ISOxo", "Knock2"])
    #expect(d.artistLogos == [nil, "x.png", nil])
    #expect(d.artistLogoTints == [.auto, .white, .auto])
}

@Test func lockedArtPositionBeatsTheRoll() {
    var o = SpineOverrides()
    o.slice = 0.25
    for n in 0..<10 {
        #expect(SpineDesign.roll(artist: "A", title: "T", genres: [], label: nil, year: nil, discCount: 1,
                                 shuffles: n, options: SpineDesign.Options(currentYear: 2026), overrides: o).slice == 0.25)
    }
    #expect(o.lockedCount == 1)
}

@MainActor
@Test func artPositionReportsItsLock() {
    let art = ArtPosition()
    #expect(!art.isLocked)
    art.slice = 0.4
    #expect(art.isLocked)
    art.slice = 0.6
    #expect(art.isLocked)
    art.slice = nil
    #expect(!art.isLocked)
}

// MARK: - Label logo backing and rotation

@Test func labelLogoBackingAndRotationReachTheDesign() {
    let options = SpineDesign.Options(
        currentYear: 2026, labelLogos: ["sub pop": "l.png"],
        labelLogoBackings: ["sub pop": false], labelLogoRotations: ["sub pop": .upright]
    )
    let d = roll(label: "Sub Pop", options: options)
    #expect(!d.labelLogoBacking)
    #expect(d.labelLogoRotation == .upright)
    // Defaults: backing on, facing right.
    let plain = roll(label: "Warp", options: options)
    #expect(plain.labelLogoBacking)
    #expect(plain.labelLogoRotation == .right)
}

/// A spine at a new size (the case lifted off the shelf) finds the slice
/// already cut at the shelf's size while its own is cut.
@Test func spineArtIsFoundAtAnySizeOnceCut() async throws {
    let image = NSImage(size: NSSize(width: 64, height: 64))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: 64, height: 64).fill()
    image.unlockFocus()
    let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
    let size = CGSize(width: 30, height: 384)
    let key = SpineArtCache.key(data: data, slice: 0.5, pixelSize: size, age: 0)
    _ = await SpineArtCache.shared.art(for: data, key: key, slice: 0.5, pixelSize: size, age: 0)
    #expect(SpineArtCache.shared.anySize(SpineArtCache.sizeFreeKey(data: data, slice: 0.5, age: 0))?.image != nil)
    #expect(SpineArtCache.shared.anySize(SpineArtCache.sizeFreeKey(data: data, slice: 0.9, age: 0)) == nil)
}

// MARK: - Acronym and custom titles

@Test func acronymsAreInitialsWithDots() {
    #expect(SpineDesign.acronym("Come Over When You're Sober") == "C.O.W.Y.S.")
    #expect(SpineDesign.acronym("Pink Moon (Remastered)") == "P.M.")
    #expect(SpineDesign.acronym("Nevermind (Remastered) [Deluxe]") == nil)
    #expect(SpineDesign.acronym("Black Holes & Revelations") == "B.H.R.")
    #expect(SpineDesign.acronym("1999 Vol 2") == "1999.V.2.")
    #expect(SpineDesign.acronym("(What's the Story) Morning Glory?") == "W.T.S.M.G.")
    #expect(SpineDesign.acronym("Blonde") == nil)
}

@Test func acronymIsPickedNeverRolled() {
    let options = SpineDesign.Options(variety: .wild, currentYear: 2026)
    for i in 0..<300 {
        let d = SpineDesign.roll(artist: "A\(i)", title: "Some Long Title", genres: ["rock"], label: nil, year: nil,
                                 discCount: 1, shuffles: 0, options: options)
        #expect(d.lettering != .acronym && d.title == "Some Long Title")
    }
}

@Test func customTitleAndAcronymReachTheDesign() {
    let options = SpineDesign.Options(currentYear: 2026)
    func roll(_ o: SpineOverrides) -> SpineDesign {
        SpineDesign.roll(artist: "A", title: "Come Over When You're Sober", genres: [], label: nil, year: nil,
                         discCount: 1, shuffles: 0, options: options, overrides: o)
    }
    var o = SpineOverrides()
    o.lettering = .acronym
    #expect(roll(o).title == "C.O.W.Y.S.")
    o.title = "Pt. 1"
    #expect(roll(o).title == "P.1.")
    o.lettering = .tagged
    #expect(roll(o).title == "Pt. 1")
    o.title = "   "
    #expect(roll(o).title == "Come Over When You're Sober")
    var custom = SpineOverrides()
    custom.title = "Sober"
    #expect(!custom.isEmpty)
}
