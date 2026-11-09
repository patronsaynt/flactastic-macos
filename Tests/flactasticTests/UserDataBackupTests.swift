import Foundation
import Testing
@testable import flactastic

// Back Up / Restore round trips against scratch folders and a throwaway
// preferences domain. Never touches the real user data.

private struct Sandbox {
    let home: URL
    let support: URL
    let libraryRoot: URL
    let domain: String
    let defaults: UserDefaults

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("flactastic-backup-\(UUID().uuidString)", isDirectory: true)
        support = home.appendingPathComponent("support", isDirectory: true)
        libraryRoot = home.appendingPathComponent("Music Library", isDirectory: true)
        domain = "flactastic.tests.backup.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: domain))
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    var locations: UserDataBackup.Locations {
        .init(supportDirectory: support, defaults: defaults, preferenceDomain: domain)
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: home)
    }
}

@Test func backupRoundTripsUserDataAndLeavesSecretsAndCachesOut() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    let lib = box.libraryRoot.appendingPathComponent(".flactastic")

    box.defaults.set("dark", forKey: "flactastic.theme")
    box.defaults.set(["Shoegaze"], forKey: "flactastic.customGenres")
    box.defaults.set("token", forKey: "flactastic.spotify.refreshToken")
    box.defaults.set("device", forKey: "flactastic.sync.deviceID")
    try box.write("artists", to: box.support.appendingPathComponent("artists.json"))
    try box.write("history", to: box.support.appendingPathComponent("libraries/ABC/listening.json"))
    try box.write("logo", to: box.support.appendingPathComponent("SpineLogos/x.png"))
    try box.write("cache", to: box.support.appendingPathComponent("lyrics_cache.json"))
    try box.write("playlists", to: lib.appendingPathComponent("playlists.json"))
    try box.write("cache", to: lib.appendingPathComponent("metadata-cache.json"))

    let archive = try UserDataBackup.makeArchive(libraryRoot: box.libraryRoot, at: box.locations)
    #expect(Set(archive.supportFiles.keys) == ["artists.json", "libraries/ABC/listening.json", "SpineLogos/x.png"])
    #expect(Set(archive.libraryFiles.keys) == ["playlists.json"])

    let file = try UserDataBackup.encode(archive, password: nil)
    #expect(file.prefix(8) == UserDataBackup.magic)
    #expect(try !UserDataBackup.isEncrypted(file))

    // Change everything, then restore.
    box.defaults.set("light", forKey: "flactastic.theme")
    box.defaults.set(true, forKey: "flactastic.showDownloadTab")
    try box.write("edited", to: box.support.appendingPathComponent("artists.json"))
    try box.write("new", to: box.support.appendingPathComponent("SpineLogos/y.png"))
    try box.write("changed", to: lib.appendingPathComponent("playlists.json"))

    let notes = try UserDataBackup.restore(UserDataBackup.decode(file, password: nil), at: box.locations)

    #expect(notes.isEmpty)
    #expect(box.defaults.string(forKey: "flactastic.theme") == "dark")
    #expect(box.defaults.object(forKey: "flactastic.showDownloadTab") == nil)
    #expect(box.defaults.stringArray(forKey: "flactastic.customGenres") == ["Shoegaze"])
    #expect(box.defaults.string(forKey: "flactastic.spotify.refreshToken") == "token")
    #expect(box.read(box.support.appendingPathComponent("artists.json")) == "artists")
    #expect(!FileManager.default.fileExists(atPath: box.support.appendingPathComponent("SpineLogos/y.png").path))
    #expect(box.read(box.support.appendingPathComponent("lyrics_cache.json")) == "cache")
    #expect(box.read(lib.appendingPathComponent("playlists.json")) == "playlists")
    let history = box.support.appendingPathComponent("libraries/ABC/listening.json")
    let mode = try FileManager.default.attributesOfItem(atPath: history.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
}

@Test func passwordProtectedBackupNeedsTheRightPassword() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    box.defaults.set("dark", forKey: "flactastic.theme")
    try box.write("artists", to: box.support.appendingPathComponent("artists.json"))

    let file = try UserDataBackup.encode(
        UserDataBackup.makeArchive(libraryRoot: nil, at: box.locations), password: "correct horse"
    )

    #expect(try UserDataBackup.isEncrypted(file))
    #expect(!file.contains(Data("artists".utf8)))
    #expect(throws: UserDataBackup.BackupError.self) { try UserDataBackup.decode(file, password: nil) }
    #expect(throws: UserDataBackup.BackupError.self) { try UserDataBackup.decode(file, password: "wrong") }
    let archive = try UserDataBackup.decode(file, password: "correct horse")
    #expect(archive.supportFiles["artists.json"] == Data("artists".utf8))

    // Tampering with the header (here, the iteration count) is caught too.
    var tampered = file
    tampered[13] ^= 0x01
    #expect(throws: UserDataBackup.BackupError.self) { try UserDataBackup.decode(tampered, password: "correct horse") }
}

@Test func restoreRefusesPathsOutsideItsFolders() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    var archive = try UserDataBackup.makeArchive(libraryRoot: nil, at: box.locations)
    archive.supportFiles["SpineLogos/../../evil.json"] = Data("x".utf8)

    #expect(throws: UserDataBackup.BackupError.self) { try UserDataBackup.restore(archive, at: box.locations) }
    #expect(!FileManager.default.fileExists(atPath: box.home.appendingPathComponent("evil.json").path))
    #expect(throws: UserDataBackup.BackupError.self) { try UserDataBackup.decode(Data("nope".utf8), password: nil) }
}

@Test func missingMusicFolderIsReportedNotFatal() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try box.write("playlists", to: box.libraryRoot.appendingPathComponent(".flactastic/playlists.json"))
    var archive = try UserDataBackup.makeArchive(libraryRoot: box.libraryRoot, at: box.locations)
    archive.libraryRootPath = box.home.appendingPathComponent("Gone").path

    let notes = try UserDataBackup.restore(archive, at: box.locations)
    #expect(notes.count == 1)
}
