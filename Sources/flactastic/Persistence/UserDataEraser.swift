import Foundation
import os

/// Erases everything FLACtastic keeps about the person on this Mac, for the
/// "Clear User Data" button in Settings. Afterwards the app quits, and opens
/// next time as if newly installed.
///
/// Erased:
///  - Application Support/flactastic: listening history, artist edits, mixes
///    and mix feedback, spine logos, tag backups, sync devices, lookup caches.
///    The `Music` folder inside it is kept, because it may be a library.
///  - Preferences: every setting, the library location, spine and logo
///    customisation, the Spotify sign-in, the sync device ID. All three
///    preference domains the app has used are removed.
///  - Keychain: every sync pairing key.
///  - Caches: artwork thumbnails, web caches, the downloader's site data.
///  - Temp files from downloads and casting.
///
/// Never touched: music files and their tags, and the music folder's own
/// `.flactastic` folder (playlists, track IDs), which belong to the library
/// and travel with it.
enum UserDataEraser {
    private static let log = Logger(subsystem: "flactastic", category: "UserDataEraser")

    /// Debug builds (`flactastic`), packaged builds (`com.flactastic.app`)
    /// and an early build (`com.local.flactastic`).
    static let bundleIdentifiers = ["flactastic", "com.flactastic.app", "com.local.flactastic"]

    /// The domains above plus the running app's own, whatever it's called.
    static var defaultPreferenceDomains: [String] {
        var domains = bundleIdentifiers
        if let id = Bundle.main.bundleIdentifier, !domains.contains(id) { domains.append(id) }
        return domains
    }

    /// Folders inside Application Support/flactastic that are left in place.
    static let keptSupportItems: Set<String> = ["Music"]

    struct Locations {
        var applicationSupport: URL
        var caches: URL
        var library: URL
        var temporary: URL

        static var current: Locations {
            let fm = FileManager.default
            let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            return Locations(
                applicationSupport: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("flactastic", isDirectory: true),
                caches: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                library: library,
                temporary: fm.temporaryDirectory
            )
        }

        /// Every file or folder the erase removes outright.
        func itemsToRemove() -> [URL] {
            let fm = FileManager.default
            var items = ((try? fm.contentsOfDirectory(at: applicationSupport, includingPropertiesForKeys: nil)) ?? [])
                .filter { !UserDataEraser.keptSupportItems.contains($0.lastPathComponent) }
            // ArtworkImageCache's folder.
            items.append(caches.appendingPathComponent("FLACtastic", isDirectory: true))
            for id in UserDataEraser.bundleIdentifiers {
                items.append(caches.appendingPathComponent(id, isDirectory: true))
                items.append(library.appendingPathComponent("WebKit/\(id)", isDirectory: true))
                items.append(library.appendingPathComponent("HTTPStorages/\(id)", isDirectory: true))
                items.append(library.appendingPathComponent("HTTPStorages/\(id).binarycookies"))
            }
            items.append(temporary.appendingPathComponent(Housekeeping.castFolderName, isDirectory: true))
            return items
        }
    }

    /// Deletes the files, preferences and Keychain items. Returns a line for
    /// each thing that couldn't be removed; empty when everything went.
    @discardableResult
    static func erase(
        at locations: Locations = .current,
        preferenceDomains: [String] = defaultPreferenceDomains,
        includeSystemStores: Bool = true
    ) -> [String] {
        var failures: [String] = []
        let fm = FileManager.default

        for url in locations.itemsToRemove() where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        Housekeeping.sweepTemporaryFiles(in: locations.temporary, minimumAge: 0)

        for domain in preferenceDomains {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        if includeSystemStores {
            // Process-wide stores tests can't point anywhere else.
            URLCache.shared.removeAllCachedResponses()
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            do {
                try PeerKeyStore.deleteAll()
            } catch {
                failures.append("Sync pairing keys: \(error)")
            }
        }

        for failure in failures {
            log.error("Erase left something behind: \(failure, privacy: .public)")
        }
        return failures
    }

    /// Quits without the usual shutdown. `exit` rather than
    /// `NSApp.terminate`: terminating posts willTerminate, and the stores
    /// still in memory (listening history, for one) save themselves on it,
    /// which would write some of the erased data straight back.
    static func quitWithoutSaving() -> Never {
        exit(0)
    }
}
