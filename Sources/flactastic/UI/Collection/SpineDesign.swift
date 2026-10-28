import AppKit
import Observation
import CoreText
import Foundation

// MARK: - Settings

/// How far the Albums rack's spine designs range.
enum SpineVariety: String, CaseIterable, Identifiable, Sendable {
    /// One tidy insert for every album: a short white band, centred.
    case uniform
    case varied
    /// Wider ranges, inserts set a little askew, faces borrowed from the
    /// neighbouring tier now and then.
    case wild

    var id: String { rawValue }

    var label: String {
        switch self {
        case .uniform: return "Uniform"
        case .varied: return "Varied"
        case .wild: return "Wild"
        }
    }
}

/// What a rack spine shows.
enum SpineStyle: String, CaseIterable, Identifiable, Sendable {
    /// The paper insert, title face, marks and wear (`SpineDesign`).
    case designed
    /// The art with the title and artist printed plainly down it.
    case artAndTitle
    /// The art alone.
    case artOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .designed: return "Designed"
        case .artAndTitle: return "Art + Title"
        case .artOnly: return "Art Only"
        }
    }
}

/// How a logo the person added is coloured on the spines.
enum LogoTint: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Each album picks white, black or the cover's colour, whichever reads
    /// on what the logo sits on, like the inserts' own colours.
    case auto
    case white
    case black
    /// The cover's dominant colour.
    case cover
    /// The logo's own colours, untouched.
    case original

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .white: return "White"
        case .black: return "Black"
        case .cover: return "Cover Colour"
        case .original: return "Original"
        }
    }
}

/// A part of a designed spine the person can hide in Edit Spine.
enum SpineElement: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    /// The paper strip; its type then prints straight on the art.
    case insert
    case title
    case artist
    case labelMark
    case discCount
    /// Ageing: the yellowed paper, faded art and scuffed lid.
    case wear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .insert: return "Insert"
        case .title: return "Title"
        case .artist: return "Artist"
        case .labelMark: return "Label Mark"
        case .discCount: return "Disc Count"
        case .wear: return "Wear"
        }
    }
}

/// Which way a label logo faces on the spine, as you look at the shelf.
enum LogoRotation: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Turned a quarter anticlockwise: its top faces left.
    case left
    /// Level, as the logo was made.
    case upright
    /// Turned with the spine's own type: its top faces right.
    case right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left: return "Left"
        case .upright: return "Upright"
        case .right: return "Right"
        }
    }
}

/// Spines that share a design across a run of albums.
enum ShelfTheme: String, CaseIterable, Identifiable, Sendable {
    case off
    /// One design per artist; each album in its own cover's colour.
    case artistSeries
    /// One design per record label.
    case labelHouse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .artistSeries: return "Artist Series"
        case .labelHouse: return "Label House Style"
        }
    }
}

/// The record label's mark at the foot of a spine.
enum LabelMarkStyle: String, CaseIterable, Identifiable, Sendable {
    case off
    case badge
    case band

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .badge: return "Badge"
        case .band: return "Foot Band"
        }
    }
}

// MARK: - Fonts

/// The bundled title faces (Resources/SpineFonts; where each comes from and
/// its licence are in Licenses/SOURCES.md). Each carries a size and tracking
/// that line its caps up with the others at the spine's 12.5pt.
enum SpineFont: String, CaseIterable, Codable, Sendable {
    case unifraktur, metalMania, pirataOne
    case permanentMarker, specialElite, rubikDirt
    case bungee, anton, rubikMonoOne
    case orbitron, audiowide, majorMono
    case dmSerifItalic, fraunces, yeseva
    case cinzel, cormorant, imFell
    // Added from the design handoff.
    case chomsky, jslBlackletter, infiltrace, stampede
    case report1942, sekuntia, phorssa, magicialGame
    case freshman, moderniz, tagmarker, blackout
    case higher, infinity, dolceVita, dolceVitaHeavy
    case mayonice, khodijah, dolceVitaLight, jefferson
    case aquiline, dufay

    /// The family's name, as shown in Edit Spine and Genre Groups.
    var displayName: String {
        switch self {
        case .unifraktur: return "UnifrakturMaguntia"
        case .metalMania: return "Metal Mania"
        case .pirataOne: return "Pirata One"
        case .permanentMarker: return "Permanent Marker"
        case .specialElite: return "Special Elite"
        case .rubikDirt: return "Rubik Dirt"
        case .bungee: return "Bungee"
        case .anton: return "Anton"
        case .rubikMonoOne: return "Rubik Mono One"
        case .orbitron: return "Orbitron"
        case .audiowide: return "Audiowide"
        case .majorMono: return "Major Mono Display"
        case .dmSerifItalic: return "DM Serif Display"
        case .fraunces: return "Fraunces"
        case .yeseva: return "Yeseva One"
        case .cinzel: return "Cinzel"
        case .cormorant: return "Cormorant Garamond"
        case .imFell: return "IM Fell English"
        case .chomsky: return "Chomsky"
        case .jslBlackletter: return "JSL Blackletter"
        case .infiltrace: return "Infiltrace"
        case .stampede: return "Stampede"
        case .report1942: return "1942 Report"
        case .sekuntia: return "60sekuntia"
        case .phorssa: return "Phorssa"
        case .magicialGame: return "Magicial Game"
        case .freshman: return "Freshman"
        case .moderniz: return "Moderniz"
        case .tagmarker: return "Tagmarker"
        case .blackout: return "Blackout"
        case .higher: return "Higher"
        case .infinity: return "Infinity"
        case .dolceVita: return "Dolce Vita"
        case .dolceVitaHeavy: return "Dolce Vita Heavy"
        case .mayonice: return "Mayonice"
        case .khodijah: return "Khodijah"
        case .dolceVitaLight: return "Dolce Vita Light"
        case .jefferson: return "Jefferson"
        case .aquiline: return "AquilineTwo"
        case .dufay: return "Dufay"
        }
    }

    var postScriptName: String {
        switch self {
        case .unifraktur: return "UnifrakturMaguntia"
        case .metalMania: return "MetalMania-Regular"
        case .pirataOne: return "PirataOne-Regular"
        case .permanentMarker: return "PermanentMarker-Regular"
        case .specialElite: return "SpecialElite-Regular"
        case .rubikDirt: return "RubikDirt-Regular"
        case .bungee: return "Bungee-Regular"
        case .anton: return "Anton-Regular"
        case .rubikMonoOne: return "RubikMonoOne-Regular"
        case .orbitron: return "Orbitron-Bold"
        case .audiowide: return "Audiowide-Regular"
        case .majorMono: return "MajorMonoDisplay-Regular"
        case .dmSerifItalic: return "DMSerifDisplay-Italic"
        case .fraunces: return "Fraunces-SemiBoldItalic"
        case .yeseva: return "YesevaOne-Regular"
        case .cinzel: return "CinzelRoman-Bold"
        case .cormorant: return "CormorantGaramond-SemiBold"
        case .imFell: return "IM_FELL_English_Roman"
        case .chomsky: return "Chomsky"
        case .jslBlackletter: return "JSL-Blackletter"
        case .infiltrace: return "InfiltraceItalic"
        case .stampede: return "Stampede"
        case .report1942: return "1942report"
        case .sekuntia: return "60sekuntia"
        case .phorssa: return "Phorssa"
        case .magicialGame: return "Magicial-Game"
        case .freshman: return "Freshman"
        case .moderniz: return "MODERNIZ"
        case .tagmarker: return "Tagmarker"
        case .blackout: return "Blackout"
        case .higher: return "Higher"
        case .infinity: return "Infinity"
        case .dolceVita: return "DolceVita"
        case .dolceVitaHeavy: return "DolceVitaHeavy-Bold"
        case .mayonice: return "Mayonice"
        case .khodijah: return "KhodijahFree"
        case .dolceVitaLight: return "DolceVitaLight"
        case .jefferson: return "Jefferson"
        case .aquiline: return "AquilineTwo"
        case .dufay: return "Dufay"
        }
    }

    /// Size relative to the spine's base title size.
    var scale: CGFloat {
        switch self {
        case .unifraktur: return 1.18
        case .metalMania: return 1.12
        case .pirataOne: return 1.2
        case .permanentMarker: return 1.0
        case .specialElite: return 1.02
        case .rubikDirt: return 1.0
        case .bungee: return 0.92
        case .anton: return 1.2
        case .rubikMonoOne: return 0.8
        case .orbitron: return 0.86
        case .audiowide: return 0.94
        case .majorMono: return 0.9
        case .dmSerifItalic: return 1.12
        case .fraunces: return 1.06
        case .yeseva: return 1.04
        case .cinzel: return 0.96
        case .cormorant: return 1.22
        case .imFell: return 1.14
        // Cap height matched to SF's; the scripts by their lowercase instead,
        // since their swash capitals stand far taller.
        case .chomsky: return 1.05
        case .jslBlackletter: return 1.0
        case .infiltrace: return 0.82
        case .stampede: return 1.0
        case .report1942: return 1.12
        case .sekuntia: return 1.05
        case .phorssa: return 0.95
        case .magicialGame: return 1.05
        case .freshman: return 0.84
        case .moderniz: return 0.8
        case .tagmarker: return 1.0
        case .blackout: return 1.05
        case .higher: return 1.2
        case .infinity: return 0.95
        case .dolceVita, .dolceVitaHeavy, .dolceVitaLight: return 1.0
        case .mayonice: return 1.1
        case .khodijah: return 0.85
        case .jefferson: return 0.92
        case .aquiline: return 0.95
        case .dufay: return 0.85
        }
    }

    /// Letter spacing, in ems.
    var tracking: CGFloat {
        switch self {
        case .unifraktur, .rubikMonoOne, .fraunces: return 0
        case .metalMania, .pirataOne, .permanentMarker, .rubikDirt, .bungee, .majorMono, .yeseva: return 0.02
        case .specialElite: return 0.03
        case .anton, .audiowide: return 0.04
        case .orbitron: return 0.08
        case .dmSerifItalic, .cormorant, .imFell: return 0.01
        case .cinzel: return 0.06
        case .chomsky, .jslBlackletter, .infiltrace, .stampede, .phorssa, .sekuntia, .mayonice, .khodijah,
             .jefferson, .aquiline, .dufay, .moderniz, .blackout, .infinity, .magicialGame, .report1942:
            return 0
        case .freshman, .dolceVita, .dolceVitaHeavy: return 0.02
        case .dolceVitaLight, .tagmarker: return 0.04
        case .higher: return 0.06
        }
    }
}

/// Registers the bundled spine faces with the process, so `Font.custom` finds
/// them by PostScript name. Started at launch on a background thread: forty
/// font files take tens of milliseconds to register, which the main thread
/// shouldn't wait on. The rack holds its spines back until `isReady`.
enum SpineFonts {
    static func register() {
        Task.detached(priority: .userInitiated) {
            _ = registered
            await MainActor.run { SpineFontsState.shared.isReady = true }
            warm()
        }
    }

    private static let registered: Bool = {
        guard let folder = resourceFolder,
              let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return false }
        for url in urls where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    /// Opens every face and checks it against the everyday characters, in
    /// the background once they're registered: the first title set in a
    /// face, or the first look at Genre Groups, then finds it loaded and its
    /// coverage known instead of doing that work mid-scroll on the main thread.
    private static func warm() {
        let everyday = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,:;'’\"“”!?&()-–/#+@×•"
        for face in SpineFont.allCases {
            // One character at a time: a face missing one still gets the
            // rest checked.
            for scalar in everyday.unicodeScalars { _ = covers(face, String(scalar)) }
        }
    }

    /// Whether `face` can draw every visible character of `text`. Many of the
    /// display faces lack numbers, punctuation or non-Latin letters; a title
    /// they can't set picks another face rather than falling back glyph by
    /// glyph. Unknown faces (not registered, as in tests) count as covering.
    ///
    /// Answers are kept per face and character, so each glyph's outline is
    /// looked at once a session however many titles use it.
    static func covers(_ face: SpineFont, _ text: String) -> Bool {
        guard let font = font(face) else { return true }
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            if !covers(font, face, scalar) { return false }
        }
        return true
    }

    private static func covers(_ font: CTFont, _ face: SpineFont, _ scalar: Unicode.Scalar) -> Bool {
        let key = CoverageKey(face: face, scalar: scalar.value)
        lock.lock()
        let known = coverage[key]
        lock.unlock()
        if let known { return known }
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        // Some faces map a character to an empty outline, so a glyph alone
        // isn't proof.
        let drawn = CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
            && glyphs.first.map { $0 != 0 && CTFontCreatePathForGlyph(font, $0, nil) != nil } == true
        lock.lock()
        coverage[key] = drawn
        lock.unlock()
        return drawn
    }

    private struct CoverageKey: Hashable {
        let face: SpineFont
        let scalar: UInt32
    }

    /// Per face and character, whether it draws. Guarded by `lock`.
    private nonisolated(unsafe) static var coverage: [CoverageKey: Bool] = [:]

    /// How far (in ems) to raise a face so its capitals sit centred in the
    /// strip. Text is centred by its line box, and faces whose ascent and
    /// descent are out of proportion to their capitals (swash scripts, some
    /// blackletters) otherwise sit visibly low or high. 0 when unknown.
    static func capCentring(_ face: SpineFont) -> CGFloat {
        guard let font = font(face) else { return 0 }
        let size = CTFontGetSize(font)
        return (CTFontGetAscent(font) - CTFontGetDescent(font) - CTFontGetCapHeight(font)) / 2 / size
    }

    /// One CTFont per face, made on first use. Guarded by `lock`.
    private nonisolated(unsafe) static var fonts: [SpineFont: CTFont] = [:]
    private static let lock = NSLock()

    private static func font(_ face: SpineFont) -> CTFont? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = fonts[face] { return hit }
        let font = CTFontCreateWithName(face.postScriptName as CFString, 12, nil)
        // CoreText substitutes a default font for unknown names.
        guard (CTFontCopyPostScriptName(font) as String) == face.postScriptName else { return nil }
        fonts[face] = font
        return font
    }

    /// Finds the SwiftPM resource bundle the same way `Wordmark` does, so a
    /// packaged `.app` (bundle in Contents/Resources) works as well as a
    /// `swift run` build.
    private static var resourceFolder: URL? {
        let name = "flactastic_flactastic.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
            Bundle.main.resourceURL,
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url), let folder = bundle.url(forResource: "SpineFonts", withExtension: nil) {
                return folder
            }
        }
        return nil
    }
}

/// Whether the spine faces are registered yet.
@MainActor
@Observable
final class SpineFontsState {
    static let shared = SpineFontsState()
    var isReady = false
}

// MARK: - Genre tiers

/// Mood groups that pick a title face from the album's genre: harder genres
/// get rougher faces, gentler ones smoother.
enum GenreTier: Int, CaseIterable, Codable, Identifiable, Sendable {
    case heavy, raw, street, electric, smooth, classic

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .heavy: return "Heavy"
        case .raw: return "Raw"
        case .street: return "Street"
        case .electric: return "Electric"
        case .smooth: return "Smooth"
        case .classic: return "Classic"
        }
    }

    var fonts: [SpineFont] {
        switch self {
        case .heavy: return [.unifraktur, .metalMania, .pirataOne, .chomsky, .jslBlackletter, .infiltrace, .stampede]
        case .raw: return [.permanentMarker, .specialElite, .rubikDirt, .report1942, .sekuntia, .phorssa, .magicialGame, .stampede]
        case .street: return [.bungee, .anton, .rubikMonoOne, .freshman, .moderniz, .tagmarker, .blackout]
        case .electric: return [.orbitron, .audiowide, .majorMono, .higher, .infinity, .dolceVita, .dolceVitaHeavy]
        case .smooth: return [.dmSerifItalic, .fraunces, .yeseva, .mayonice, .khodijah, .dolceVitaLight, .jefferson]
        case .classic: return [.cinzel, .cormorant, .imFell, .aquiline, .jefferson, .dufay]
        }
    }

    /// Keywords matched inside a genre name. Checked in `matchOrder`, so a
    /// "pop punk" record reads as raw before the broad "pop" makes it
    /// electric, and "jazz rap" reads as street.
    var defaultKeywords: [String] {
        switch self {
        case .heavy: return ["metal", "hardcore", "deathcore", "grindcore", "doom", "sludge", "industrial", "thrash", "screamo"]
        case .street: return ["hip-hop", "hip hop", "hiphop", "rap", "trap", "drill", "grime", "phonk", "boom bap"]
        case .raw: return ["punk", "grunge", "garage", "noise", "shoegaze", "emo", "post-rock", "rock"]
        case .smooth: return ["r&b", "rnb", "soul", "jazz", "lo-fi", "lofi", "funk", "ambient", "chill", "bossa", "downtempo"]
        case .classic: return ["classical", "folk", "country", "singer-songwriter", "acoustic", "bluegrass", "opera",
                               "soundtrack", "orchestral", "americana"]
        case .electric: return ["electronic", "electronica", "techno", "house", "edm", "dubstep", "drum and bass", "drum & bass",
                                "dnb", "synth", "pop", "trance", "bass", "dance", "idm", "breakbeat", "glitch", "disco", "future"]
        }
    }

    static let matchOrder: [GenreTier] = [.heavy, .street, .raw, .smooth, .classic, .electric]

    /// The tier with the built-in keywords alone.
    static func of(_ genres: [String]) -> GenreTier? {
        GenreGroups().tier(for: genres)
    }

    static func defaultTier(of keyword: String) -> GenreTier? {
        allCases.first { $0.defaultKeywords.contains(keyword) }
    }
}

/// The person's changes to which genres go in which group: built-in keywords
/// moved to another group, and keywords of their own. Everything else keeps
/// the built-in lists.
struct GenreGroups: Codable, Hashable, Sendable {
    /// Lower-cased keyword → the group it now belongs to.
    var assigned: [String: GenreTier] = [:]

    /// The tier of the first genre that matches: the main genre, then the
    /// secondary ones. The person's own keywords are tried first, longest
    /// first (so "pop punk" beats "pop"); then the built-in lists, in
    /// `matchOrder`. Nil when none matches.
    func tier(for genres: [String]) -> GenreTier? {
        let own = assigned.keys.sorted { $0.count > $1.count }
        for genre in genres {
            let g = genre.lowercased()
            if let key = own.first(where: { g.contains($0) }) { return assigned[key] }
            for tier in GenreTier.matchOrder where tier.defaultKeywords.contains(where: { assigned[$0] == nil && g.contains($0) }) {
                return tier
            }
        }
        return nil
    }

    /// The keywords now in `tier`, built-in ones first.
    func keywords(in tier: GenreTier) -> [String] {
        tier.defaultKeywords.filter { assigned[$0] == nil }
            + assigned.filter { $0.value == tier }.keys.sorted()
    }

    func isCustom(_ keyword: String) -> Bool { GenreTier.defaultTier(of: keyword) == nil }

    /// Puts `keyword` in `tier`. A built-in keyword moved home again goes
    /// back to being unassigned.
    mutating func move(_ keyword: String, to tier: GenreTier) {
        let key = keyword.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        assigned[key] = GenreTier.defaultTier(of: key) == tier ? nil : tier
    }

    /// Drops a keyword of the person's own (built-in ones can only move).
    mutating func remove(_ keyword: String) {
        if isCustom(keyword) { assigned[keyword] = nil }
    }
}

// MARK: - The roll

/// Seeded randomness that matches the design mockups: FNV-1a over the seed
/// key, then mulberry32. The same album rolls the same spine in every
/// session, on every machine; nothing is stored.
struct SpineRandom {
    private var state: UInt32

    init(key: String, shuffles: Int) {
        state = Self.hash(key) &+ UInt32(truncatingIfNeeded: shuffles) &* 7919
    }

    init(seed: UInt32) {
        state = seed
    }

    static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for unit in s.utf16 {
            h ^= UInt32(unit)
            h = h &* 16_777_619
        }
        return h
    }

    mutating func next() -> Double {
        state = state &+ 0x6D2B_79F5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }

    /// An index chosen by relative weight.
    mutating func pick(_ weights: [Double]) -> Int {
        var x = next() * weights.reduce(0, +)
        for (i, w) in weights.enumerated() {
            x -= w
            if x < 0 { return i }
        }
        return weights.count - 1
    }
}

/// One album's spine: a paper insert on its art, every choice rolled from a
/// seed hashed from the album (plus how many times it's been shuffled).
/// Pure data; `RackSpine` draws it.
struct SpineDesign: Equatable, Sendable {
    enum Position: String, Codable, CaseIterable, Sendable { case top, center, bottom }
    enum Fill: Equatable, Sendable {
        case paper, black
        /// The cover's dominant colour, resolved when the art is sampled.
        case art
        /// A record label's own colour (Label House Style).
        case house(hue: Double)
        /// A colour picked in Edit Spine, as "#rrggbb".
        case custom(hex: String)
    }
    enum Edge: String, Codable, CaseIterable, Sendable { case straight, torn, ruled }
    /// Acronym is never rolled, only picked: initials suit some titles and
    /// make nonsense of others.
    enum Lettering: String, Codable, CaseIterable, Sendable { case tagged, caps, lower, acronym }
    enum Separator: String, Codable, CaseIterable, Sendable { case none, dot, slash, rule }
    /// A record label's mark. Its shape, face and style come from the
    /// label's name, so every album on a label carries the same mark, like
    /// a logo; which end of the spine it sits at is rolled per album.
    struct Mark: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case badge, band }
        enum Shape: CaseIterable, Sendable { case circle, square, rounded, pill, diamond }
        enum Face: CaseIterable, Sendable { case heavy, rounded, serif, mono, bungee, cinzel }
        enum Style: CaseIterable, Sendable {
            /// The label's colour, type in black or white.
            case filled
            /// A ring and type in the label's colour, on black.
            case ringed
            /// White, type in the label's colour.
            case inverted
        }

        var kind: Kind
        var monogram: String
        var hue: Double
        var shape: Shape
        var face: Face
        var style: Style
        /// `.top` or `.bottom`.
        var end: Position
    }

    struct Options: Hashable, Sendable {
        var variety: SpineVariety = .varied
        var theme: ShelfTheme = .off
        var labelMark: LabelMarkStyle = .badge
        var ageWithYear = true
        var currentYear = Calendar.current.component(.year, from: Date())
        var groups = GenreGroups()
        /// Faces switched off in Genre Groups.
        var disabledFaces: Set<SpineFont> = []
        /// Logo image files the person added, by lower-cased artist or label name.
        var artistLogos: [String: String] = [:]
        var labelLogos: [String: String] = [:]
        /// How each logo is coloured, by the same keys; missing means Auto.
        var artistLogoTints: [String: LogoTint] = [:]
        var labelLogoTints: [String: LogoTint] = [:]
        /// Per label logo: whether its badge or band shows behind it (missing
        /// means it does), and which way it faces (missing means Right).
        var labelLogoBackings: [String: Bool] = [:]
        var labelLogoRotations: [String: LogoRotation] = [:]
    }

    /// Both sizes are fitted to the text: a short band closely, a long
    /// insert with more paper around it (never past most of the spine).
    var isLong: Bool
    var position: Position
    var fill: Fill
    var edge: Edge
    /// Nil for no matching genre: the title stays in the app's own face.
    var font: SpineFont?
    var lettering: Lettering
    var separator: Separator
    /// The artist printed on the art at the free end instead of on the card.
    var artistOnArt: Bool
    var artistEnd: Position
    /// Where across the cover the spine's slice of art is cut, 0…1.
    var slice: Double
    /// Degrees the insert sits off true (Wild only).
    var askew: Double
    /// 0 for a new release, rising to 1 over about forty years.
    var age: Double
    /// Nil when the album has no label (or the setting is off).
    var mark: Mark?
    var discCount: Int
    /// Places the torn ends and the lid's scuffs.
    var detailSeed: UInt32

    /// The person's own logo image file for the artist and label, if any.
    /// The album's artists, one entry each, in credit order. A spine sets
    /// them apart with its own separator, never commas.
    var artists: [String] = []
    /// Each artist's logo file and its colouring, aligned with `artists`.
    var artistLogos: [String?] = []
    var artistLogoTints: [LogoTint] = []
    var labelLogo: String?
    var labelLogoTint: LogoTint = .auto
    var labelLogoBacking = true
    var labelLogoRotation: LogoRotation = .right
    /// Where an Auto logo starts among white, black and the cover's colour.
    var logoTintRoll: Double = 0
    /// Parts the person hid in Edit Spine.
    var hidden: Set<SpineElement> = []
    /// What the spine prints for the title: the album's, or the person's own
    /// text, as initials when the lettering is Acronym.
    var title = ""

    static func roll(
        artist: String, title: String, genres: [String], label: String?, year: Int?, discCount: Int,
        shuffles: Int, options: Options, overrides: SpineOverrides = SpineOverrides(), artists: [String] = []
    ) -> SpineDesign {
        let artists = artists.isEmpty ? [artist] : artists
        let label = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var key = artist + "\u{0}" + title
        if options.theme == .artistSeries { key = "artist\u{0}" + artist }
        if options.theme == .labelHouse, let label { key = "label\u{0}" + label }
        var r = SpineRandom(key: key, shuffles: shuffles)
        let uniform = options.variety == .uniform, wild = options.variety == .wild

        // Fixed draw order: a new attribute goes on the end, so it never
        // reshuffles the ones before it.
        var isLong = r.next() < (wild ? 0.5 : 0.45)
        var position: Position = [.top, .center, .bottom][min(2, Int(r.next() * 3))]
        let fillPick = r.pick(wild ? [30, 25, 45] : [40, 30, 30])
        var edge: Edge = [.straight, .torn, .ruled][r.pick(wild ? [34, 33, 33] : [50, 25, 25])]
        let fontRoll = r.next(), sliceRoll = r.next(), outRoll = r.next(), outEndRoll = r.next()
        var lettering: Lettering = [.tagged, .caps, .lower][r.pick(wild ? [40, 35, 25] : [60, 25, 15])]
        var separator: Separator = [.none, .dot, .slash, .rule][r.pick(wild ? [25, 25, 25, 25] : [40, 25, 20, 15])]
        let askewRoll = r.next(), strayRoll = r.next(), markEndRoll = r.next(), logoTintRoll = r.next()
        var artistOnArt = outRoll < (wild ? 0.5 : 0.35)

        let labelHue = label.map { Double(SpineRandom.hash("hue\u{0}" + $0) % 360) / 360 }
        var fill: Fill = [.paper, .black, .art][fillPick]
        if uniform {
            isLong = false; position = .center; fill = .paper; edge = .straight
            lettering = .tagged; separator = .none; artistOnArt = false
        }
        if options.theme == .artistSeries { fill = .art }
        if options.theme == .labelHouse, let labelHue { fill = [.paper, .black, .house(hue: labelHue)][fillPick] }
        // What the person locked in Edit Spine wins over the roll.
        if let v = overrides.isLong { isLong = v }
        if let v = overrides.position { position = v }
        if let v = overrides.fill { fill = v.fill }
        if let v = overrides.edge { edge = v }
        if let v = overrides.lettering { lettering = v }
        if let v = overrides.separator { separator = v }
        // A long insert leaves no free end for the artist; Edit Spine keeps
        // the two locks from both being set, and here the artist wins.
        if let v = overrides.artistOnArt { artistOnArt = v; if v { isLong = false } }
        let slice = overrides.slice ?? sliceRoll
        if isLong { artistOnArt = false }
        // The person's own title text, if any, then as initials for Acronym.
        let source = overrides.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? title
        let printed = lettering == .acronym ? Self.acronym(source) ?? source : source
        let artistEnd: Position = position == .top ? .bottom : position == .bottom ? .top : (outEndRoll < 0.5 ? .top : .bottom)

        var font: SpineFont?
        if let tier = options.groups.tier(for: genres) {
            var pool = tier.fonts
            if wild, strayRoll < 0.3 {
                pool = GenreTier.allCases[(tier.rawValue + (strayRoll < 0.15 ? 5 : 1)) % 6].fonts
            }
            pool.removeAll { options.disabledFaces.contains($0) }
            let shown = lettering == .caps ? printed.uppercased() : lettering == .lower ? printed.lowercased() : printed
            let start = uniform ? 0 : min(pool.count - 1, Int(fontRoll * Double(pool.count)))
            // The rolled face, or the next one in the group that can set this
            // title; none can (a non-Latin title, say), and it stays in SF.
            font = pool.isEmpty ? nil : (0..<pool.count).lazy.map { pool[(start + $0) % pool.count] }.first { SpineFonts.covers($0, shown) }
        }
        if let choice = overrides.font { font = choice.face }

        let age: Double = {
            guard options.ageWithYear, let year, year > 0 else { return 0 }
            return max(0, min(1, Double(options.currentYear - year - 2) / 42))
        }()

        var mark: Mark?
        // A label made only of symbols has no initials to show; it gets no mark.
        if options.labelMark != .off, let label, let labelHue, case let monogram = Self.monogram(label), !monogram.isEmpty {
            var lr = SpineRandom(key: "mark\u{0}" + label, shuffles: 0)
            let shape = Mark.Shape.allCases[min(4, Int(lr.next() * 5))]
            let face = Mark.Face.allCases[min(5, Int(lr.next() * 6))]
            let style = Mark.Style.allCases[lr.pick([50, 25, 25])]
            mark = Mark(
                kind: options.labelMark == .band ? .band : .badge, monogram: monogram, hue: labelHue,
                shape: shape, face: face, style: style,
                end: overrides.markEnd ?? (uniform || markEndRoll >= 0.4 ? .bottom : .top)
            )
        }

        return SpineDesign(
            isLong: isLong, position: position, fill: fill, edge: edge, font: font, lettering: lettering,
            separator: separator, artistOnArt: artistOnArt, artistEnd: artistEnd, slice: slice,
            askew: wild ? (askewRoll - 0.5) * 1.6 : 0, age: age, mark: mark, discCount: discCount,
            detailSeed: SpineRandom.hash(title) &+ UInt32(truncatingIfNeeded: shuffles),
            artists: artists,
            artistLogos: artists.map { options.artistLogos[$0.lowercased()] },
            artistLogoTints: artists.map { options.artistLogoTints[$0.lowercased()] ?? .auto },
            labelLogo: label.flatMap { options.labelLogos[$0.lowercased()] },
            labelLogoTint: label.flatMap { options.labelLogoTints[$0.lowercased()] } ?? .auto,
            labelLogoBacking: label.flatMap { options.labelLogoBackings[$0.lowercased()] } ?? true,
            labelLogoRotation: label.flatMap { options.labelLogoRotations[$0.lowercased()] } ?? .right,
            logoTintRoll: logoTintRoll,
            hidden: overrides.hiddenElements,
            title: printed
        ).applyingHidden()
    }

    /// Drops what's hidden from what the spine draws. Title, artist and
    /// insert are read by the spine itself; the rest simply aren't there.
    private func applyingHidden() -> SpineDesign {
        var d = self
        if hidden.contains(.labelMark) { d.mark = nil }
        if hidden.contains(.discCount) { d.discCount = 1 }
        if hidden.contains(.wear) { d.age = 0 }
        return d
    }

    /// "NLV Records" → "NL", "Sub Pop" → "SP": the first letters of up to two
    /// words, skipping the generic ones.
    /// A title as its initials with dots between ("Come Over When You're
    /// Sober" → "C.O.W.Y.S."), less any bracketed edition notes at its end.
    /// A number keeps all its digits. Nil for a title of one word, which
    /// prints as it is.
    static func acronym(_ title: String) -> String? {
        let trimmed = title.replacingOccurrences(of: #"(\s*[\(\[][^\)\]]*[\)\]])+\s*$"#, with: "", options: .regularExpression)
        let initials: [String] = (trimmed.isEmpty ? title : trimmed).split(whereSeparator: \.isWhitespace).compactMap { word in
            if word.allSatisfy(\.isNumber) { return String(word) }
            return word.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() }
        }
        return initials.count > 1 ? initials.joined(separator: ".") + "." : nil
    }

    static func monogram(_ label: String) -> String {
        let generic: Set<String> = ["records", "recordings", "music", "the", "label", "group", "entertainment", "ltd", "inc", "llc"]
        let words = label.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let picked = words.filter { !generic.contains($0.lowercased()) }
        let source = (picked.isEmpty ? words : picked)
        if source.count == 1, let word = source.first { return String(word.prefix(2)).uppercased() }
        return source.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

extension SpineDesign {
    /// The album's spine, rolled with the person's settings.
    static func roll(
        for album: Album, credit: String, shuffles: Int, options: Options, overrides: SpineOverrides = SpineOverrides(),
        artists: [String] = []
    ) -> SpineDesign {
        let discs = max(album.tracks.compactMap(\.discTotal).max() ?? 0, Set(album.tracks.map { $0.discNumber ?? 1 }).count)
        return roll(
            artist: logoArtist(album, credit: credit), title: album.name,
            genres: ([album.genre] + album.secondaryGenres.map(Optional.some)).compactMap { $0 },
            label: album.label, year: album.year, discCount: discs, shuffles: shuffles, options: options,
            overrides: overrides, artists: artists
        )
    }

    /// The name an album's seed and artist logo go by.
    static func logoArtist(_ album: Album, credit: String) -> String {
        album.albumArtist ?? album.artist ?? credit
    }
}

/// What the person has locked on one album's spine in Edit Spine. Each field
/// is nil until they pick it; the rest keeps rolling from the seed.
struct SpineOverrides: Codable, Hashable, Sendable {
    /// A strip colour choice that survives encoding.
    enum FillChoice: Codable, Hashable, Sendable {
        case paper, black, art
        case custom(hex: String)

        var fill: SpineDesign.Fill {
            switch self {
            case .paper: return .paper
            case .black: return .black
            case .art: return .art
            case .custom(let hex): return .custom(hex: hex)
            }
        }
    }

    /// A title face, or the app's own.
    enum FontChoice: Codable, Hashable, Sendable {
        case system
        case face(SpineFont)

        var face: SpineFont? {
            if case .face(let f) = self { return f }
            return nil
        }
    }

    var isLong: Bool?
    var position: SpineDesign.Position?
    var fill: FillChoice?
    var edge: SpineDesign.Edge?
    var font: FontChoice?
    var lettering: SpineDesign.Lettering?
    var separator: SpineDesign.Separator?
    var artistOnArt: Bool?
    var markEnd: SpineDesign.Position?
    /// Parts hidden on this album's spine. Optional so overrides saved before
    /// it existed still decode.
    var hidden: Set<SpineElement>?
    /// Where across the cover the spine's art is cut, 0…1.
    var slice: Double?
    /// The person's own text for the title, in place of the album's.
    var title: String?

    var hiddenElements: Set<SpineElement> { hidden ?? [] }

    var lockedCount: Int {
        [isLong as Any?, position, fill, edge, font, lettering, separator, artistOnArt, markEnd, slice].compactMap { $0 }.count
    }

    /// Anything to keep: a lock, or a hidden part.
    var isEmpty: Bool { lockedCount == 0 && hiddenElements.isEmpty && title == nil }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Every rolled spine, kept until something it depends on changes. The rack
/// redraws its visible spines on every scroll step and hover; rolling each
/// afresh (seeding, genre matching, the face coverage checks) cost a few
/// milliseconds of main-thread time a frame. With this, a redraw looks each
/// up instead.
@MainActor
final class SpineDesignCache {
    static let shared = SpineDesignCache()

    /// The settings the kept designs were rolled with; any change rolls
    /// everything again.
    private var options: SpineDesign.Options?
    private var designs: [Key: SpineDesign] = [:]

    private struct Key: Hashable {
        let id: String
        let credit: String
        let name: String
        let artist: String?
        let albumArtist: String?
        let genre: String?
        let secondaryGenres: [String]
        let label: String?
        let year: Int?
        /// The tracks' disc tags folded into one number: the disc mark
        /// changes when a disc break is added or removed.
        let discs: Int
        let shuffles: Int
        let overrides: SpineOverrides
        let artists: [String]
    }

    func design(
        for album: Album, credit: String, shuffles: Int, options: SpineDesign.Options,
        overrides: SpineOverrides = SpineOverrides(), artists: [String] = []
    ) -> SpineDesign {
        if options != self.options {
            designs.removeAll(keepingCapacity: true)
            self.options = options
        }
        let key = Key(
            id: album.id, credit: credit, name: album.name, artist: album.artist, albumArtist: album.albumArtist,
            genre: album.genre, secondaryGenres: album.secondaryGenres, label: album.label, year: album.year,
            discs: Self.discFingerprint(album),
            shuffles: shuffles, overrides: overrides, artists: artists
        )
        if let hit = designs[key] { return hit }
        // A long session of edits leaves stale entries behind; start over
        // rather than let them pile up.
        if designs.count > 5000 { designs.removeAll(keepingCapacity: true) }
        let design = SpineDesign.roll(for: album, credit: credit, shuffles: shuffles, options: options, overrides: overrides, artists: artists)
        designs[key] = design
        return design
    }

    private static func discFingerprint(_ album: Album) -> Int {
        var h = album.tracks.count
        for t in album.tracks {
            h = h &* 31 &+ (t.discNumber ?? 0)
            h = h &* 31 &+ (t.discTotal ?? 0)
        }
        return h
    }
}
