import Foundation
import Observation

@Observable
@MainActor
final class Settings {
    var lastRootPath: String? {
        didSet { UserDefaults.standard.set(lastRootPath, forKey: "flactastic.lastRootPath") }
    }

    var volume: Float {
        didSet { UserDefaults.standard.set(volume, forKey: "flactastic.volume") }
    }

    var useLightMode: Bool {
        didSet { UserDefaults.standard.set(useLightMode, forKey: "flactastic.useLightMode") }
    }

    /// UI scale factor. 1.0 = default. Clamped to 0.9...1.35 in the view layer.
    var uiScale: Double {
        didSet { UserDefaults.standard.set(uiScale, forKey: "flactastic.uiScale") }
    }

    /// Whether the menu bar mini-player is shown. When false, the status item
    /// is removed, so no icon appears in the system menu bar.
    var showMenuBarPlayer: Bool {
        didSet { UserDefaults.standard.set(showMenuBarPlayer, forKey: "flactastic.showMenuBarPlayer") }
    }

    /// Hides the menu bar icon whenever nothing is playing. Off by default:
    /// the icon stays for as long as the app is open.
    var menuBarPlayerOnlyWhilePlaying: Bool {
        didSet { UserDefaults.standard.set(menuBarPlayerOnlyWhilePlaying, forKey: "flactastic.menuBarPlayerOnlyWhilePlaying") }
    }

    var roundedArtwork: Bool {
        didSet { UserDefaults.standard.set(roundedArtwork, forKey: "flactastic.roundedArtwork") }
    }

    var showArtworkShadow: Bool {
        didSet { UserDefaults.standard.set(showArtworkShadow, forKey: "flactastic.showArtworkShadow") }
    }

    var fadeAnimationsEnabled: Bool {
        didSet { UserDefaults.standard.set(fadeAnimationsEnabled, forKey: "flactastic.fadeAnimationsEnabled") }
    }

    var fadeAnimationDirection: FadeAnimationDirection {
        didSet { UserDefaults.standard.set(fadeAnimationDirection.rawValue, forKey: "flactastic.fadeAnimationDirection") }
    }

    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "flactastic.hasCompletedOnboarding") }
    }

    /// Tabs whose one-time tutorial card has been dismissed (`AppTab` raw
    /// values). A tab in here never shows its tutorial again, unless
    /// Settings → Debug → "Show tutorials on every visit" is on.
    var seenTutorials: Set<String> {
        didSet { UserDefaults.standard.set(Array(seenTutorials).sorted(), forKey: "flactastic.seenTutorials") }
    }

    /// When false (the default), the Artists grid leaves out artists whose
    /// only entries are appearances on other artists' releases.
    var showAllArtists: Bool {
        didSet { UserDefaults.standard.set(showAllArtists, forKey: "flactastic.showAllArtists") }
    }

    /// When true (the default), the Collection's Albums view leaves out
    /// singles (releases under three tracks; mixes stay). Search still finds them.
    var hideSinglesInAlbums: Bool {
        didSet { UserDefaults.standard.set(hideSinglesInAlbums, forKey: "flactastic.hideSinglesInAlbums") }
    }

    /// When true (the default), the Albums CD rack draws each case as clear
    /// plastic: a rim and hinge highlight on every spine, a sheen that follows
    /// the pointer down the hovered one, and a sheen across the case as it
    /// turns. Off, the spines are plain printed cards.
    var clearCaseLook: Bool {
        didSet { UserDefaults.standard.set(clearCaseLook, forKey: "flactastic.clearCaseLook") }
    }

    /// Blurs the album art behind each rack spine's insert (off by default:
    /// the art shows as printed).
    var blurSpineArt: Bool {
        didSet { UserDefaults.standard.set(blurSpineArt, forKey: "flactastic.blurSpineArt") }
    }

    var spineVariety: SpineVariety {
        didSet { UserDefaults.standard.set(spineVariety.rawValue, forKey: "flactastic.spineVariety") }
    }

    var shelfTheme: ShelfTheme {
        didSet { UserDefaults.standard.set(shelfTheme.rawValue, forKey: "flactastic.shelfTheme") }
    }

    var spineLabelMark: LabelMarkStyle {
        didSet { UserDefaults.standard.set(spineLabelMark.rawValue, forKey: "flactastic.spineLabelMark") }
    }

    /// Older albums' spines yellow and scuff with their release year.
    var ageSpinesWithYear: Bool {
        didSet { UserDefaults.standard.set(ageSpinesWithYear, forKey: "flactastic.ageSpinesWithYear") }
    }

    /// How many times each album's spine has been shuffled, by album ID. The
    /// rest of a spine's design comes from its seed, so this is all that's
    /// stored.
    var spineShuffles: [String: Int] {
        didSet { UserDefaults.standard.set(spineShuffles, forKey: "flactastic.spineShuffles") }
    }

    /// Designed inserts, or the art with or without a plain title.
    var spineStyle: SpineStyle {
        didSet { UserDefaults.standard.set(spineStyle.rawValue, forKey: "flactastic.spineStyle") }
    }

    /// When an album's folder has a spine image (spine.jpg and the like),
    /// the rack shows that real printed spine instead of drawing one.
    var useSpineScans: Bool {
        didSet { UserDefaults.standard.set(useSpineScans, forKey: "flactastic.useSpineScans") }
    }

    /// What's locked in Edit Spine, by album ID.
    var spineOverrides: [String: SpineOverrides] {
        didSet { Self.saveJSON(spineOverrides, key: "flactastic.spineOverrides") }
    }

    /// Genre Groups: keywords moved between groups or added.
    var genreGroups: GenreGroups {
        didSet { Self.saveJSON(genreGroups, key: "flactastic.genreGroups") }
    }

    /// Home in its designed order (on), or in `homeSectionOrder` with
    /// `homeHiddenSections` left out (off). Empty sections hide either way.
    var homeArrangesAutomatically: Bool {
        didSet { UserDefaults.standard.set(homeArrangesAutomatically, forKey: "flactastic.home.arrangesAutomatically") }
    }

    var homeSectionOrder: [HomeSection] {
        didSet { UserDefaults.standard.set(homeSectionOrder.map(\.rawValue), forKey: "flactastic.home.sectionOrder") }
    }

    var homeHiddenSections: Set<HomeSection> {
        didSet { UserDefaults.standard.set(homeHiddenSections.map(\.rawValue).sorted(), forKey: "flactastic.home.hiddenSections") }
    }

    /// The sections Home shows, in order.
    var homeSections: [HomeSection] {
        guard !homeArrangesAutomatically else { return HomeSection.allCases }
        // Sections added in a later version join at their designed place.
        var order = homeSectionOrder.filter { HomeSection.allCases.contains($0) }
        for (index, section) in HomeSection.allCases.enumerated() where !order.contains(section) {
            order.insert(section, at: min(index, order.count))
        }
        return order.filter { !homeHiddenSections.contains($0) }
    }

    /// Title faces switched off in Genre Groups.
    var disabledSpineFaces: Set<SpineFont> {
        didSet { UserDefaults.standard.set(disabledSpineFaces.map(\.rawValue).sorted(), forKey: "flactastic.disabledSpineFaces") }
    }

    /// The person's own logos for spines: lower-cased artist or label name →
    /// image file name in `SpineLogoStore`'s folder.
    var artistLogos: [String: String] {
        didSet { UserDefaults.standard.set(artistLogos, forKey: "flactastic.artistLogos") }
    }

    var labelLogos: [String: String] {
        didSet { UserDefaults.standard.set(labelLogos, forKey: "flactastic.labelLogos") }
    }

    /// How each logo is coloured on spines, by the same keys as the logos.
    var artistLogoTints: [String: LogoTint] {
        didSet { Self.saveJSON(artistLogoTints, key: "flactastic.artistLogoTints") }
    }

    var labelLogoTints: [String: LogoTint] {
        didSet { Self.saveJSON(labelLogoTints, key: "flactastic.labelLogoTints") }
    }

    /// Per label logo: its badge or band shown behind it, and which way it faces.
    var labelLogoBackings: [String: Bool] {
        didSet { Self.saveJSON(labelLogoBackings, key: "flactastic.labelLogoBackings") }
    }

    var labelLogoRotations: [String: LogoRotation] {
        didSet { Self.saveJSON(labelLogoRotations, key: "flactastic.labelLogoRotations") }
    }

    var spineOptions: SpineDesign.Options {
        SpineDesign.Options(
            variety: spineVariety, theme: shelfTheme, labelMark: spineLabelMark, ageWithYear: ageSpinesWithYear,
            groups: genreGroups, disabledFaces: disabledSpineFaces, artistLogos: artistLogos, labelLogos: labelLogos,
            artistLogoTints: artistLogoTints, labelLogoTints: labelLogoTints,
            labelLogoBackings: labelLogoBackings, labelLogoRotations: labelLogoRotations
        )
    }

    private static func saveJSON<T: Encodable>(_ value: T, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    var customGenres: [String] {
        didSet { UserDefaults.standard.set(customGenres, forKey: "flactastic.customGenres") }
    }

    /// When true, missing artist profile images are fetched from Deezer.
    /// User-supplied images always take priority regardless of this setting.
    var autoFetchArtistImages: Bool {
        didSet { UserDefaults.standard.set(autoFetchArtistImages, forKey: "flactastic.autoFetchArtistImages") }
    }

    var discordRichPresenceEnabled: Bool {
        didSet { UserDefaults.standard.set(discordRichPresenceEnabled, forKey: "flactastic.discordRichPresenceEnabled") }
    }

    /// Last-selected visualizer mode. Restored when the user opens the Visualizer tab.
    var visualizerMode: VisualizerMode {
        didSet { UserDefaults.standard.set(visualizerMode.rawValue, forKey: "flactastic.visualizerMode") }
    }

    /// When true, the Lyrics visualizer mode fetches lyrics from lrclib.net.
    /// Disable for offline / privacy-conscious use; cached entries still display.
    var lyricsLookupEnabled: Bool {
        didSet { UserDefaults.standard.set(lyricsLookupEnabled, forKey: "flactastic.lyricsLookupEnabled") }
    }

    /// When true, successfully-fetched lyrics are written into the LYRICS tag
    /// on the source audio file (cross-format: Xiph LYRICS / ID3v2 USLT /
    /// MP4 ©lyr). Off keeps user files untouched.
    var saveLyricsToFiles: Bool {
        didSet { UserDefaults.standard.set(saveLyricsToFiles, forKey: "flactastic.saveLyricsToFiles") }
    }

    var showVpnNotice: Bool {
        didSet { UserDefaults.standard.set(showVpnNotice, forKey: "flactastic.showVpnNotice") }
    }

    /// Whether the Download tab appears in the top navigation bar. Defaults
    /// to hidden — most users import via the Home/Playlists flows and don't
    /// need direct access to the streaming-download tooling.
    var showDownloadTab: Bool {
        didSet { UserDefaults.standard.set(showDownloadTab, forKey: "flactastic.showDownloadTab") }
    }

    /// Whether the synthetic "Liked Songs" entry appears at the top of the
    /// Spotify Playlists screen. Defaults to shown.
    var showSpotifyLikedSongs: Bool {
        didSet { UserDefaults.standard.set(showSpotifyLikedSongs, forKey: "flactastic.showSpotifyLikedSongs") }
    }

    /// Fraction of a track (0.0–1.0) that must be genuinely played straight
    /// through for the listen to count as a single play, mirroring streaming
    /// services. Default 0.90 (90%). Clamped to 0…1 on write.
    var countedPlayFraction: Double {
        didSet {
            let clamped = min(max(countedPlayFraction, 0), 1)
            if clamped != countedPlayFraction { countedPlayFraction = clamped; return }
            UserDefaults.standard.set(countedPlayFraction, forKey: "flactastic.countedPlayFraction")
        }
    }

    /// UID of the pinned output device (stable across reboots and re-plugs).
    /// nil follows the system default output device.
    var outputDeviceUID: String? {
        didSet { UserDefaults.standard.set(outputDeviceUID, forKey: "flactastic.outputDeviceUID") }
    }

    /// Output sample rate applied to the device. Every track is resampled to
    /// this one rate, which keeps playback gapless. nil leaves the device as is.
    var outputSampleRate: Double? {
        didSet { UserDefaults.standard.set(outputSampleRate, forKey: "flactastic.outputSampleRate") }
    }

    /// Physical bit depth applied to the device's output stream. nil leaves
    /// the device's current format alone.
    var outputBitDepth: Int? {
        didSet { UserDefaults.standard.set(outputBitDepth, forKey: "flactastic.outputBitDepth") }
    }

    /// Cap on what's streamed to network (DLNA) speakers. `.original` sends
    /// the untouched file.
    var networkStreamQuality: NetworkStreamQuality {
        didSet { UserDefaults.standard.set(networkStreamQuality.rawValue, forKey: "flactastic.networkStreamQuality") }
    }

    init() {
        lastRootPath = UserDefaults.standard.string(forKey: "flactastic.lastRootPath")
        let stored = UserDefaults.standard.object(forKey: "flactastic.volume")
        volume = (stored as? Float) ?? 0.75
        useLightMode = UserDefaults.standard.bool(forKey: "flactastic.useLightMode")
        let storedScale = UserDefaults.standard.object(forKey: "flactastic.uiScale")
        uiScale = (storedScale as? Double) ?? 1.0
        let storedMBP = UserDefaults.standard.object(forKey: "flactastic.showMenuBarPlayer")
        showMenuBarPlayer = (storedMBP as? Bool) ?? true
        menuBarPlayerOnlyWhilePlaying = UserDefaults.standard.bool(forKey: "flactastic.menuBarPlayerOnlyWhilePlaying")
        let storedRA = UserDefaults.standard.object(forKey: "flactastic.roundedArtwork")
        roundedArtwork = (storedRA as? Bool) ?? true
        let storedShadow = UserDefaults.standard.object(forKey: "flactastic.showArtworkShadow")
        showArtworkShadow = (storedShadow as? Bool) ?? true
        let storedFade = UserDefaults.standard.object(forKey: "flactastic.fadeAnimationsEnabled")
        fadeAnimationsEnabled = (storedFade as? Bool) ?? true
        let storedDir = UserDefaults.standard.string(forKey: "flactastic.fadeAnimationDirection")
        fadeAnimationDirection = storedDir.flatMap(FadeAnimationDirection.init(rawValue:)) ?? .up
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "flactastic.hasCompletedOnboarding")
        seenTutorials = Set(UserDefaults.standard.stringArray(forKey: "flactastic.seenTutorials") ?? [])
        showAllArtists = UserDefaults.standard.bool(forKey: "flactastic.showAllArtists")
        hideSinglesInAlbums = (UserDefaults.standard.object(forKey: "flactastic.hideSinglesInAlbums") as? Bool) ?? true
        clearCaseLook = (UserDefaults.standard.object(forKey: "flactastic.clearCaseLook") as? Bool) ?? true
        blurSpineArt = UserDefaults.standard.bool(forKey: "flactastic.blurSpineArt")
        spineVariety = UserDefaults.standard.string(forKey: "flactastic.spineVariety").flatMap(SpineVariety.init(rawValue:)) ?? .varied
        shelfTheme = UserDefaults.standard.string(forKey: "flactastic.shelfTheme").flatMap(ShelfTheme.init(rawValue:)) ?? .off
        spineLabelMark = UserDefaults.standard.string(forKey: "flactastic.spineLabelMark").flatMap(LabelMarkStyle.init(rawValue:)) ?? .badge
        ageSpinesWithYear = (UserDefaults.standard.object(forKey: "flactastic.ageSpinesWithYear") as? Bool) ?? true
        spineShuffles = (UserDefaults.standard.dictionary(forKey: "flactastic.spineShuffles") as? [String: Int]) ?? [:]
        spineStyle = UserDefaults.standard.string(forKey: "flactastic.spineStyle").flatMap(SpineStyle.init(rawValue:)) ?? .designed
        useSpineScans = (UserDefaults.standard.object(forKey: "flactastic.useSpineScans") as? Bool) ?? true
        spineOverrides = Self.loadJSON([String: SpineOverrides].self, key: "flactastic.spineOverrides") ?? [:]
        genreGroups = Self.loadJSON(GenreGroups.self, key: "flactastic.genreGroups") ?? GenreGroups()
        homeArrangesAutomatically = (UserDefaults.standard.object(forKey: "flactastic.home.arrangesAutomatically") as? Bool) ?? true
        homeSectionOrder = (UserDefaults.standard.stringArray(forKey: "flactastic.home.sectionOrder") ?? [])
            .compactMap(HomeSection.init(rawValue:))
        homeHiddenSections = Set((UserDefaults.standard.stringArray(forKey: "flactastic.home.hiddenSections") ?? [])
            .compactMap(HomeSection.init(rawValue:)))
        disabledSpineFaces = Set((UserDefaults.standard.stringArray(forKey: "flactastic.disabledSpineFaces") ?? []).compactMap(SpineFont.init(rawValue:)))
        artistLogos = (UserDefaults.standard.dictionary(forKey: "flactastic.artistLogos") as? [String: String]) ?? [:]
        labelLogos = (UserDefaults.standard.dictionary(forKey: "flactastic.labelLogos") as? [String: String]) ?? [:]
        artistLogoTints = Self.loadJSON([String: LogoTint].self, key: "flactastic.artistLogoTints") ?? [:]
        labelLogoTints = Self.loadJSON([String: LogoTint].self, key: "flactastic.labelLogoTints") ?? [:]
        labelLogoBackings = Self.loadJSON([String: Bool].self, key: "flactastic.labelLogoBackings") ?? [:]
        labelLogoRotations = Self.loadJSON([String: LogoRotation].self, key: "flactastic.labelLogoRotations") ?? [:]
        customGenres = UserDefaults.standard.stringArray(forKey: "flactastic.customGenres") ?? []
        let storedAutoFetch = UserDefaults.standard.object(forKey: "flactastic.autoFetchArtistImages")
        autoFetchArtistImages = (storedAutoFetch as? Bool) ?? true
        let storedDRP = UserDefaults.standard.object(forKey: "flactastic.discordRichPresenceEnabled")
        discordRichPresenceEnabled = (storedDRP as? Bool) ?? true
        // A stored mode that has since been removed ("bigPicture", the Large
        // Art and Art + Details modes) no longer parses, so this fallback
        // doubles as the migration for existing users. Write the resolved
        // value straight back — `didSet` doesn't fire during init, so without
        // this the dead value would be re-read every launch.
        let storedVis = UserDefaults.standard.string(forKey: "flactastic.visualizerMode")
        let resolvedVis = storedVis.flatMap(VisualizerMode.init(rawValue:))
        let effectiveVis = resolvedVis ?? .albumArtWheel
        visualizerMode = effectiveVis
        if storedVis != nil, resolvedVis == nil {
            UserDefaults.standard.set(effectiveVis.rawValue, forKey: "flactastic.visualizerMode")
            UserDefaults.standard.removeObject(forKey: "flactastic.showBigPictureFullScreenToggle")
        }
        let storedLyricsLookup = UserDefaults.standard.object(forKey: "flactastic.lyricsLookupEnabled")
        lyricsLookupEnabled = (storedLyricsLookup as? Bool) ?? true
        let storedSaveLyrics = UserDefaults.standard.object(forKey: "flactastic.saveLyricsToFiles")
        saveLyricsToFiles = (storedSaveLyrics as? Bool) ?? true
        let storedVpn = UserDefaults.standard.object(forKey: "flactastic.showVpnNotice")
        showVpnNotice = (storedVpn as? Bool) ?? true
        let storedShowDownloadTab = UserDefaults.standard.object(forKey: "flactastic.showDownloadTab")
        showDownloadTab = (storedShowDownloadTab as? Bool) ?? false
        let storedLikedSongs = UserDefaults.standard.object(forKey: "flactastic.showSpotifyLikedSongs")
        showSpotifyLikedSongs = (storedLikedSongs as? Bool) ?? true
        let storedCPF = UserDefaults.standard.object(forKey: "flactastic.countedPlayFraction")
        countedPlayFraction = (storedCPF as? Double) ?? 0.90
        outputDeviceUID = UserDefaults.standard.string(forKey: "flactastic.outputDeviceUID")
        outputSampleRate = UserDefaults.standard.object(forKey: "flactastic.outputSampleRate") as? Double
        outputBitDepth = UserDefaults.standard.object(forKey: "flactastic.outputBitDepth") as? Int
        networkStreamQuality = UserDefaults.standard.string(forKey: "flactastic.networkStreamQuality")
            .flatMap(NetworkStreamQuality.init(rawValue:)) ?? .original
    }
}

enum FadeAnimationDirection: String, CaseIterable, Identifiable {
    case up
    case leftToRight
    case rightToLeft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .up: return "Upward"
        case .leftToRight: return "Left to Right"
        case .rightToLeft: return "Right to Left"
        }
    }
}
