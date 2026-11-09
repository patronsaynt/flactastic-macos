import Foundation
import Testing
@testable import flactastic

// "Clear User Data" against a fake home folder. Only scratch folders and a
// throwaway preferences domain are touched; never the real Keychain or caches.

@Test func eraseRemovesAppDataAndKeepsTheMusicFolder() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("flactastic-erase-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: home) }

    let locations = UserDataEraser.Locations(
        applicationSupport: home.appendingPathComponent("Application Support/flactastic", isDirectory: true),
        caches: home.appendingPathComponent("Caches", isDirectory: true),
        library: home,
        temporary: home.appendingPathComponent("tmp", isDirectory: true)
    )
    func make(_ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
    let support = locations.applicationSupport
    try make(support.appendingPathComponent("artists.json"))
    try make(support.appendingPathComponent("libraries/ABC/listening.json"))
    try make(support.appendingPathComponent("TagBackups/tag-backup-1.json"))
    let song = support.appendingPathComponent("Music/Album/song.flac")
    try make(song)
    try make(locations.caches.appendingPathComponent("FLACtastic/ArtworkThumbnails/a.jpg"))
    try make(locations.caches.appendingPathComponent("com.flactastic.app/Cache.db"))
    try make(home.appendingPathComponent("WebKit/flactastic/data"))
    try make(locations.temporary.appendingPathComponent("flactastic-dl-1.flac"))
    let unrelated = locations.caches.appendingPathComponent("SomeOtherApp/keep.db")
    try make(unrelated)

    let domain = "flactastic.tests.erase.\(UUID().uuidString)"
    let prefs = try #require(UserDefaults(suiteName: domain))
    prefs.set("secret", forKey: "flactastic.spotify.refreshToken")

    let failures = UserDataEraser.erase(at: locations, preferenceDomains: [domain], includeSystemStores: false)

    #expect(failures.isEmpty)
    #expect(try fm.contentsOfDirectory(atPath: support.path) == ["Music"])
    #expect(fm.fileExists(atPath: song.path))
    #expect(!fm.fileExists(atPath: locations.caches.appendingPathComponent("FLACtastic").path))
    #expect(!fm.fileExists(atPath: locations.caches.appendingPathComponent("com.flactastic.app").path))
    #expect(!fm.fileExists(atPath: home.appendingPathComponent("WebKit/flactastic").path))
    #expect(!fm.fileExists(atPath: locations.temporary.appendingPathComponent("flactastic-dl-1.flac").path))
    #expect(fm.fileExists(atPath: unrelated.path))
    #expect(UserDefaults.standard.persistentDomain(forName: domain)?["flactastic.spotify.refreshToken"] == nil)
}
