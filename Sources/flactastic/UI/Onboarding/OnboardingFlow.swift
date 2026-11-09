import SwiftUI

/// Where onboarding is: which side of the fork, which track is playing, the
/// answers given so far (shown under each finished track), and the state the
/// stage's motion reads: the case's pose, the skip's cut and the title's
/// reveal. Shared by the tracklist, the stage and the steps.
@MainActor @Observable
final class OnboardingFlow {
    enum Branch { case new, back }

    /// One step, listed on the left like a track on a CD's back insert.
    enum Track: String, Identifiable {
        case hello, look, library, restore, spotify, play
        var id: String { rawValue }

        var title: String {
            switch self {
            case .hello: "Hello"
            case .look: "Look"
            case .library: "Library"
            case .restore: "Restore"
            case .spotify: "Spotify"
            case .play: "Play"
            }
        }
    }

    var branch: Branch = .new
    /// Index of the playing track in `tracks`.
    var at = 0
    /// What was chosen on each finished track, shown under its name.
    var answers: [Track: String] = [:]
    /// How far the playing track's scrubber has run, 0…1.
    var progress: Double = 0.08
    /// The track whose scrubber is running off its row during a skip.
    var skipping: Track?

    // MARK: Restore (Coming back)

    /// The decoded backup, applied when "Enter FLACtastic" is pressed.
    var backup: UserDataBackup.Archive?
    /// The music folder chosen on this Mac when the backup's isn't here.
    var backupFolder: String?
    /// Set when applying the backup fails at the end.
    var restoreError: String?
    /// A backup that needs its password before it can be read.
    var lockedBackup: Data?
    var passwordError: String?
    /// The backup summary's rows have come in.
    var receiptIn = false
    /// The look before a backup's was previewed, put back if the backup is set aside.
    var themeBeforeBackup: AppTheme?
    /// The backup is being written over this Mac's data.
    var isRestoring = false

    /// The theme the backup brings back, if it has one.
    var backupTheme: AppTheme? {
        backupPreferences["flactastic.theme"].flatMap { $0 as? String }.flatMap(AppTheme.init(rawValue:))
    }

    private var backupPreferences: [String: Any] {
        guard let data = backup?.preferences,
              let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return prefs
    }

    /// Whether the music folder the backup will open is on this Mac.
    var backupFolderIsHere: Bool {
        if backupFolder != nil { return true }
        guard let path = backup?.libraryRootPath else { return true }
        return FileManager.default.fileExists(atPath: path)
    }

    /// What the backup brings back, for the summary on the Restore track.
    var backupContents: [(label: String, value: String, warns: Bool)] {
        guard let backup else { return [] }
        var items: [(String, String, Bool)] = []
        if let theme = backupTheme { items.append(("Look", theme == .system ? "Follow System" : theme.label, false)) }
        if let chosen = backupFolder {
            items.append(("Music folder", (chosen as NSString).abbreviatingWithTildeInPath, false))
        } else if let path = backup.libraryRootPath {
            let shown = (path as NSString).abbreviatingWithTildeInPath
            items.append(("Music folder", backupFolderIsHere ? shown : "\(shown) isn't on this Mac", !backupFolderIsHere))
        }
        let support = backup.supportFiles.keys
        if support.contains(where: { $0.hasPrefix("libraries/") }) || backup.libraryFiles["listening.json"] != nil {
            items.append(("Listening history", "Included", false))
        }
        if backup.libraryFiles["playlists.json"] != nil { items.append(("Playlists", "Included, with track IDs", false)) }
        let logos = support.filter { $0.hasPrefix("SpineLogos/") }.count
        if support.contains("artists.json") || logos > 0 {
            items.append(("Artist edits", logos > 0 ? "Included, with \(logos) spine logo\(logos == 1 ? "" : "s")" : "Included", false))
        }
        if support.contains(where: { $0.hasPrefix("mixes/") }) { items.append(("Mixes", "Included, with your ratings", false)) }
        return items
    }

    // MARK: Library (New here)

    /// Set once the chosen folder has been read through.
    var libraryScanned = false

    // MARK: Motion

    var pose: CasePose = .offstage
    /// Turns added to every pose, one per skip, so each skip spins the case
    /// a full turn on its way to the next mark.
    var spins = 0
    /// The album the case holds once the library has covers.
    var caseAlbum: Album?
    /// Degrees a second the disc turns.
    var discSpin: Double = 0
    /// Bumped to jolt the case, as a throw is caught.
    var jolts = 0
    /// The stage's content during a skip: shaken, then torn off sideways.
    var cut = StageCut()
    /// Words of the title shown so far, and where hidden ones wait.
    var revealedWords = 0
    var wordsFrom: CGSize = CGSize(width: 0, height: 34)
    /// Subtitle and step body shown.
    var detailsIn = false
    /// The read laser's sweep across the stage, 0…1, and its strength.
    var laser: Double = 0
    var laserOpacity: Double = 0
    var pop: Double = 0
    /// Intro and finale.
    var phase: Phase = .intro
    /// Hidden until the intro throws it in.
    var caseShown = false
    var markIn = false
    var markLifted = false
    var dealt = false
    var leaving = false

    enum Phase { case intro, steps, finale }

    var tracks: [Track] {
        branch == .new ? [.hello, .look, .library, .spotify, .play] : [.hello, .restore, .spotify, .play]
    }

    var current: Track { tracks[min(at, tracks.count - 1)] }

    /// The case's pose for a track, with the turns the skips have added.
    func pose(for track: Track) -> CasePose {
        var pose = CasePose.mark(for: track, branch: branch)
        pose.turn += Double(spins) * 360
        return pose
    }
}

/// The stage's content mid-skip.
struct StageCut: Equatable {
    var x: CGFloat = 0
    var skew: Double = 0
    var blur: CGFloat = 0
    var opacity: Double = 1
    var stretch: CGFloat = 1
}
