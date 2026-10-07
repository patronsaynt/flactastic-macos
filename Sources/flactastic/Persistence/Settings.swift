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

    /// Whether the menu bar mini-player is shown. When false, the `MenuBarExtra`
    /// scene is omitted entirely so no icon appears in the system menu bar.
    var showMenuBarPlayer: Bool {
        didSet { UserDefaults.standard.set(showMenuBarPlayer, forKey: "flactastic.showMenuBarPlayer") }
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

    /// When false (the default), the Artists grid leaves out artists whose
    /// only entries are appearances on other artists' releases.
    var showAllArtists: Bool {
        didSet { UserDefaults.standard.set(showAllArtists, forKey: "flactastic.showAllArtists") }
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
        let storedRA = UserDefaults.standard.object(forKey: "flactastic.roundedArtwork")
        roundedArtwork = (storedRA as? Bool) ?? true
        let storedShadow = UserDefaults.standard.object(forKey: "flactastic.showArtworkShadow")
        showArtworkShadow = (storedShadow as? Bool) ?? true
        let storedFade = UserDefaults.standard.object(forKey: "flactastic.fadeAnimationsEnabled")
        fadeAnimationsEnabled = (storedFade as? Bool) ?? true
        let storedDir = UserDefaults.standard.string(forKey: "flactastic.fadeAnimationDirection")
        fadeAnimationDirection = storedDir.flatMap(FadeAnimationDirection.init(rawValue:)) ?? .up
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "flactastic.hasCompletedOnboarding")
        showAllArtists = UserDefaults.standard.bool(forKey: "flactastic.showAllArtists")
        customGenres = UserDefaults.standard.stringArray(forKey: "flactastic.customGenres") ?? []
        let storedAutoFetch = UserDefaults.standard.object(forKey: "flactastic.autoFetchArtistImages")
        autoFetchArtistImages = (storedAutoFetch as? Bool) ?? true
        let storedDRP = UserDefaults.standard.object(forKey: "flactastic.discordRichPresenceEnabled")
        discordRichPresenceEnabled = (storedDRP as? Bool) ?? true
        // A stored "bigPicture" no longer parses now that the mode is gone,
        // so this fallback doubles as the migration for existing users. Write
        // the resolved value straight back — `didSet` doesn't fire during
        // init, so without this the dead value would be re-read every launch.
        let storedVis = UserDefaults.standard.string(forKey: "flactastic.visualizerMode")
        let resolvedVis = storedVis.flatMap(VisualizerMode.init(rawValue:))
        let effectiveVis = resolvedVis ?? .albumArtLargeDetails
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
