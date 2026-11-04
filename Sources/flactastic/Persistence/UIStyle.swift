import AppKit
import Observation
import SwiftUI

/// Everything "UI for nerds" can tune: how each page looks, beyond the
/// light/dark theme in Settings. One shared, observable store, read straight
/// from the views it shapes (`UIStyle.shared`), so a change lands live in the
/// app and in the nerd window's preview at once. Each value saves as it's set.
///
/// A fresh `UIStyle(loadingSaved: false)` holds every default; `pristine` is
/// that instance, for resetting a value and for counting what's been changed.
@Observable
@MainActor
final class UIStyle {
    static let shared = UIStyle()
    static let pristine = UIStyle(loadingSaved: false)

    // MARK: Everywhere

    /// Where Home's accent colour comes from.
    var accentMode: AccentMode = .artist { didSet { save(accentMode.rawValue, "accentMode") } }
    /// The fixed accent, as six hex digits, used when `accentMode` is `.custom`.
    var accentHex: String = "4AA3FF" { didSet { save(accentHex, "accentHex") } }
    /// Turquoise, green, amber and red for Hi-Res, CD, Mid and Low; off, every
    /// tier reads in the grey ladder.
    var tierColours = true { didSet { save(tierColours, "tierColours") } }
    var sectionTitleSize: Double = 22 { didSet { save(sectionTitleSize, "sectionTitleSize") } }
    /// Album art corners, in points (0 is square).
    var artworkRadius: Double = Double(Theme.Radius.lg) { didSet { save(artworkRadius, "artworkRadius") } }
    /// Speeds up (above 1) or slows down every animation in the app.
    var animationSpeed: Double = 1 { didSet { save(animationSpeed, "animationSpeed") } }
    /// Frosted glass, the cover wash and the glow behind Home's case.
    var glass = true { didSet { save(glass, "glass") } }
    /// How the F mark animates on the loading screen (and other waits); nil
    /// picks one at random each launch.
    var loadingAnimation: LoadingAnimation? = nil { didSet { save(loadingAnimation?.rawValue ?? "random", "loadingAnimation") } }

    /// This launch's random pick, held for the whole launch so a wait never
    /// switches animation partway through.
    private static let launchPick = LoadingAnimation.allCases.randomElement() ?? .spectrum

    /// The animation to show: the one picked, or this launch's random one.
    var resolvedLoadingAnimation: LoadingAnimation { loadingAnimation ?? Self.launchPick }
    /// The window's chrome waits behind the loading screen and fades in with it.
    var launchFade = true { didSet { save(launchFade, "launchFade") } }

    // MARK: Home

    /// Space between covers on Home; sections get about 2.4× it.
    var homeDensity: Double = 18 { didSet { save(homeDensity, "homeDensity") } }
    var homeShowCase = true { didSet { save(homeShowCase, "homeShowCase") } }
    var caseThrow: CaseThrow = .everyLaunch { didSet { save(caseThrow.rawValue, "caseThrow") } }
    var caseScale: Double = 1 { didSet { save(caseScale, "caseScale") } }
    /// How the thrown case moves: the built-in throw (a fast flight caught
    /// with a jolt) or one smooth curve into place.
    var throwCurve: MotionCurve = .standard { didSet { save(throwCurve.rawValue, "throwCurve") } }
    var throwDuration: Double = 1.5 { didSet { save(throwDuration, "throwDuration") } }
    /// Bumped by "Throw it again"; not saved.
    var throwReplay = 0
    var lyricSize: Double = 50 { didSet { save(lyricSize, "lyricSize") } }
    var homeShowDate = true { didSet { save(homeShowDate, "homeShowDate") } }
    var homeShowStory = true { didSet { save(homeShowStory, "homeShowStory") } }
    var homeCoverSize: Double = 170 { didSet { save(homeCoverSize, "homeCoverSize") } }
    var homeCaptions = true { didSet { save(homeCaptions, "homeCaptions") } }
    var homeBadges = true { didSet { save(homeBadges, "homeBadges") } }
    var homeSubtitles = true { didSet { save(homeSubtitles, "homeSubtitles") } }
    /// Rows of covers beside today's pick (1 or 2).
    var todayRows: Int = 2 { didSet { save(todayRows, "todayRows") } }
    /// The largest a mix tile grows to fill its row.
    var mixTileSize: Double = 300 { didSet { save(mixTileSize, "mixTileSize") } }
    /// How much of the lead artist's photo shows under a mix's colour.
    var mixPhotoStrength: Double = 1 { didSet { save(mixPhotoStrength, "mixPhotoStrength") } }
    var repeatRows: Int = 8 { didSet { save(repeatRows, "repeatRows") } }
    var repeatShowPlays = true { didSet { save(repeatShowPlays, "repeatShowPlays") } }

    // MARK: Collection

    var rackLiftOnHover = true { didSet { save(rackLiftOnHover, "rackLiftOnHover") } }
    /// How a case taken off the rack turns to its front and lets its disc out.
    var rackOpenCurve: MotionCurve = .standard { didSet { save(rackOpenCurve.rawValue, "rackOpenCurve") } }
    var rackOpenDuration: Double = 0.9 { didSet { save(rackOpenDuration, "rackOpenDuration") } }
    /// The smallest a cover gets in the album grid; they grow to fill a row.
    var gridCoverSize: Double = 180 { didSet { save(gridCoverSize, "gridCoverSize") } }

    // MARK: Playlists

    var playlistRowSpacing: Double = 2 { didSet { save(playlistRowSpacing, "playlistRowSpacing") } }

    // MARK: Player

    /// Which bottom corner the player sits in.
    var playerSide: PlayerSide = .right { didSet { save(playerSide.rawValue, "playerSide") } }
    /// Widest the corner puck opens into the full player bar.
    var playerBarWidth: Double = 700 { didSet { save(playerBarWidth, "playerBarWidth") } }
    var playerCoverWash = true { didSet { save(playerCoverWash, "playerCoverWash") } }
    var playerQualityBadge = true { didSet { save(playerQualityBadge, "playerQualityBadge") } }
    var puckProgressLine = true { didSet { save(puckProgressLine, "puckProgressLine") } }

    // MARK: Derived

    /// Home's palette after the accent choice: the artist's, none (mono), or
    /// one built from the fixed colour.
    func palette(from artist: HomePalette?) -> HomePalette? {
        switch accentMode {
        case .artist: return artist
        case .mono: return nil
        case .custom: return Self.palette(hex: accentHex)
        }
    }

    static func color(hex: String) -> Color? { nsColor(hex: hex).map { Color(nsColor: $0) } }

    /// "4AA3FF", "#4aa3ff" or "4af" as a colour; nil if it isn't hex.
    static func nsColor(hex: String) -> NSColor? {
        var digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func hex(of color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "4AA3FF" }
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    private static func palette(hex: String) -> HomePalette? {
        guard let c = nsColor(hex: hex)?.usingColorSpace(.deviceRGB) else { return nil }
        return HomePalette(swatches: [.init(hue: Double(c.hueComponent), saturation: Double(c.saturationComponent), brightness: Double(c.brightnessComponent))])
    }

    // MARK: Saving

    private init(loadingSaved: Bool = true) {
        guard loadingSaved else { return }
        let d = UserDefaults.standard
        func load<T>(_ key: String, _ apply: (T) -> Void) { if let v = d.object(forKey: Self.key(key)) as? T { apply(v) } }
        load("accentMode") { (v: String) in accentMode = AccentMode(rawValue: v) ?? .artist }
        load("accentHex") { (v: String) in accentHex = v }
        load("tierColours") { (v: Bool) in tierColours = v }
        load("sectionTitleSize") { (v: Double) in sectionTitleSize = v }
        // Before the radius, artwork was rounded or not.
        if d.object(forKey: Self.key("artworkRadius")) == nil, let rounded = d.object(forKey: "flactastic.roundedArtwork") as? Bool {
            artworkRadius = rounded ? Double(Theme.Radius.lg) : 0
        }
        load("artworkRadius") { (v: Double) in artworkRadius = v }
        load("animationSpeed") { (v: Double) in animationSpeed = v }
        load("glass") { (v: Bool) in glass = v }
        load("launchFade") { (v: Bool) in launchFade = v }
        load("loadingAnimation") { (v: String) in loadingAnimation = LoadingAnimation(rawValue: v) }
        load("homeDensity") { (v: Double) in homeDensity = v }
        load("homeShowCase") { (v: Bool) in homeShowCase = v }
        load("caseThrow") { (v: String) in caseThrow = CaseThrow(rawValue: v) ?? .everyLaunch }
        load("caseScale") { (v: Double) in caseScale = v }
        load("throwCurve") { (v: String) in throwCurve = MotionCurve(rawValue: v) ?? .standard }
        load("throwDuration") { (v: Double) in throwDuration = v }
        load("lyricSize") { (v: Double) in lyricSize = v }
        load("homeShowDate") { (v: Bool) in homeShowDate = v }
        load("homeShowStory") { (v: Bool) in homeShowStory = v }
        load("homeCoverSize") { (v: Double) in homeCoverSize = v }
        load("homeCaptions") { (v: Bool) in homeCaptions = v }
        load("homeBadges") { (v: Bool) in homeBadges = v }
        load("homeSubtitles") { (v: Bool) in homeSubtitles = v }
        load("todayRows") { (v: Int) in todayRows = v }
        load("mixTileSize") { (v: Double) in mixTileSize = v }
        load("mixPhotoStrength") { (v: Double) in mixPhotoStrength = v }
        load("repeatRows") { (v: Int) in repeatRows = v }
        load("repeatShowPlays") { (v: Bool) in repeatShowPlays = v }
        load("rackLiftOnHover") { (v: Bool) in rackLiftOnHover = v }
        load("rackOpenCurve") { (v: String) in rackOpenCurve = MotionCurve(rawValue: v) ?? .standard }
        load("rackOpenDuration") { (v: Double) in rackOpenDuration = v }
        load("gridCoverSize") { (v: Double) in gridCoverSize = v }
        load("playlistRowSpacing") { (v: Double) in playlistRowSpacing = v }
        load("playerSide") { (v: String) in playerSide = PlayerSide(rawValue: v) ?? .right }
        load("playerBarWidth") { (v: Double) in playerBarWidth = v }
        load("playerCoverWash") { (v: Bool) in playerCoverWash = v }
        load("playerQualityBadge") { (v: Bool) in playerQualityBadge = v }
        load("puckProgressLine") { (v: Bool) in puckProgressLine = v }
        persistsAfterLoad = true
    }

    /// Off while the initial values load, so loading doesn't write them back.
    private var persistsAfterLoad = false

    private func save(_ value: Any, _ name: String) {
        guard persistsAfterLoad else { return }
        UserDefaults.standard.set(value, forKey: Self.key(name))
    }

    private static func key(_ name: String) -> String { "flactastic.ui.\(name)" }
}

enum AccentMode: String, CaseIterable, Identifiable {
    case artist, mono, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .artist: "Artist"
        case .mono: "Mono"
        case .custom: "Custom"
        }
    }
}

/// The shape of a move over its time. `standard` is the move as designed
/// (each animation has its own); the rest are the usual named curves.
enum MotionCurve: String, CaseIterable, Identifiable {
    case standard, easeIn, easeOut, easeInOut, linear
    var id: String { rawValue }

    func label(standard name: String) -> String {
        switch self {
        case .standard: name
        case .easeIn: "Ease in"
        case .easeOut: "Ease out"
        case .easeInOut: "Ease in & out"
        case .linear: "Linear"
        }
    }

    /// The curve itself; for `standard`, the one given.
    func unitCurve(standard: UnitCurve) -> UnitCurve {
        switch self {
        case .standard: standard
        case .easeIn: .bezier(startControlPoint: UnitPoint(x: 0.42, y: 0), endControlPoint: UnitPoint(x: 1, y: 1))
        case .easeOut: .bezier(startControlPoint: UnitPoint(x: 0, y: 0), endControlPoint: UnitPoint(x: 0.58, y: 1))
        case .easeInOut: .bezier(startControlPoint: UnitPoint(x: 0.42, y: 0), endControlPoint: UnitPoint(x: 0.58, y: 1))
        case .linear: .linear
        }
    }

    /// The app's own ease-out: fast away, long soft landing.
    static let flactastic = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.16, y: 1), endControlPoint: UnitPoint(x: 0.3, y: 1))
}

/// The bottom corner the player sits in; it opens toward the middle.
enum PlayerSide: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { self == .left ? "Left" : "Right" }
    /// The corner it's pinned to, at the bottom of the window.
    var bottomCorner: Alignment { self == .left ? .bottomLeading : .bottomTrailing }
    /// The corner of the glass the content stays pinned to as it opens.
    var topCorner: Alignment { self == .left ? .topLeading : .topTrailing }
    var unitBottomCorner: UnitPoint { self == .left ? .bottomLeading : .bottomTrailing }
}

/// When Home throws the jewel case in.
enum CaseThrow: String, CaseIterable, Identifiable {
    case everyLaunch, onceADay, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .everyLaunch: "Each launch"
        case .onceADay: "Once a day"
        case .never: "Never"
        }
    }
}
