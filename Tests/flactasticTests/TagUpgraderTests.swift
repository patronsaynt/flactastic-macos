import Foundation
import Testing
import CTagLib
@testable import flactastic

// Upgrade Tags over every committed fixture: the display baseline must still
// match afterwards, the files must hold the list fields, dates and the
// track-ID xattr must survive the file swap, and Restore must put every
// original tag back exactly.

/// Every property of a file, all keys.
private func fullPropertyMap(_ url: URL) -> [String: [String]] {
    url.path.withCString { path in
        guard let file = taglib_file_new(path) else { return [:] }
        defer { taglib_file_free(file) }
        guard let keys = taglib_property_keys(file) else { return [:] }
        defer { taglib_property_free(keys) }
        var map: [String: [String]] = [:]
        var i = 0
        while let k = keys[i] {
            let key = String(cString: k)
            map[key] = LibraryScanner.propertyList(file, key)
            i += 1
        }
        return map
    }
}

private func audioFiles(_ dir: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { Track.makeFromURL($0) != nil }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private let xattrName = "com.flactastic.trackID"

private func xattr(_ url: URL) -> String? {
    var buffer = [UInt8](repeating: 0, count: 64)
    let n = getxattr(url.path, xattrName, &buffer, buffer.count, 0, 0)
    return n > 0 ? String(decoding: buffer.prefix(n), as: UTF8.self) : nil
}

@MainActor
struct TagUpgraderTests {
    @Test func upgradeKeepsDisplayAndRestoreIsExact() async throws {
        let dir = try FixtureSupport.copyFixtures()
        let backups = try FixtureSupport.makeTempDir("backups")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: backups)
        }
        let files = try audioFiles(dir)
        let originals = Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, fullPropertyMap($0)) })

        // Dates and the track-ID xattr, to check they survive the swap.
        let past = Date(timeIntervalSince1970: 1_500_000_000)
        for url in files {
            try FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: url.path)
            #expect(TagUpgrader.setDateAdded(past, at: url))
            _ = setxattr(url.path, xattrName, Array(url.lastPathComponent.utf8), url.lastPathComponent.utf8.count, 0, 0)
        }

        let scanned = try await FixtureSupport.scan(dir)
        let candidates = TagUpgrader.candidates(in: scanned).map(\.url)
        #expect(!candidates.isEmpty)
        let backupURL = try TagUpgrader.writeBackup(of: candidates, root: dir, directory: backups)
        #expect(backupURL.lastPathComponent.hasPrefix("tag-backup-"))

        var upgraded = Set<String>()
        for url in candidates where try TagUpgrader.upgradeFile(at: url) {
            upgraded.insert(url.lastPathComponent)
        }
        #expect(upgraded.contains("cur-multi.flac"))
        #expect(upgraded.contains("cur-dl.flac"))
        #expect(upgraded.contains("cur-aa-diff.mp3"))
        // Native multi-values are already lists: untouched.
        #expect(!upgraded.contains("ext-native.flac"))
        #expect(upgraded.contains("ext-mbid.flac"))

        // Append only: every file's own ARTIST, ALBUMARTIST and GENRE strings
        // are exactly as they were; only the plural tags and marker are new.
        for url in files {
            let now = fullPropertyMap(url), before = originals[url.lastPathComponent] ?? [:]
            for key in ["ARTIST", "ALBUMARTIST", "GENRE"] {
                #expect(now[key] == before[key], "\(url.lastPathComponent) \(key) changed")
            }
            let added = Set(now.keys).subtracting(before.keys)
            #expect(added.isSubset(of: ["ARTISTS", "ALBUMARTISTS", "FLACTASTIC_TAGVERSION"]), "\(url.lastPathComponent) gained \(added)")
        }

        // The display is exactly the baseline.
        DisplayBaseline.expectMatches(DisplayBaseline.capture(try await FixtureSupport.scan(dir)), try DisplayBaseline.load())

        // The list fields are on disk, and a second run has nothing to do.
        let multi = dir.appendingPathComponent("cur-multi.flac")
        #expect(readPropertyList(multi, "ARTISTS") == ["Deadmau5", "Rob Swire"])
        #expect(readPropertyList(multi, "ARTIST") == ["Deadmau5 ; Rob Swire"])
        #expect(readPropertyList(multi, "GENRE") == ["Electronic ; House ; Progressive House"])
        let mbid = dir.appendingPathComponent("ext-mbid.flac")
        #expect(readPropertyList(mbid, "ARTIST") == ["Calvin Harris & Dua Lipa"])
        #expect(readPropertyList(mbid, "ARTISTS") == ["Calvin Harris", "Dua Lipa"])
        #expect(readPropertyList(multi, "FLACTASTIC_TAGVERSION") == ["2"])
        let download = dir.appendingPathComponent("cur-dl.flac")
        #expect(readPropertyList(download, "ARTIST") == ["Deadmau5; Kaskade"])
        #expect(readPropertyList(download, "ARTISTS") == ["Deadmau5", "Kaskade"])
        for url in candidates { #expect(try TagUpgrader.upgradeFile(at: url) == false) }

        // The swap kept dates and xattrs.
        for url in files where upgraded.contains(url.lastPathComponent) {
            // A fresh URL: URL caches resource values it has already read.
            let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.creationDateKey, .addedToDirectoryDateKey])
            #expect(values.creationDate == past, "\(url.lastPathComponent) creation date: \(String(describing: values.creationDate))")
            #expect(values.addedToDirectoryDate == past, "\(url.lastPathComponent) date added: \(String(describing: values.addedToDirectoryDate))")
            #expect(xattr(url) == url.lastPathComponent, "\(url.lastPathComponent) xattr")
        }

        // Restore puts back every original tag, exactly.
        let backup = try TagBackup.read(from: backupURL)
        for entry in backup.entries { _ = try TagUpgrader.restoreFile(entry, root: dir) }
        for url in files {
            #expect(fullPropertyMap(url) == originals[url.lastPathComponent], "\(url.lastPathComponent) not restored")
        }
        DisplayBaseline.expectMatches(DisplayBaseline.capture(try await FixtureSupport.scan(dir)), try DisplayBaseline.load())
    }

    @Test func restoreRejectsPathsOutsideTheLibrary() throws {
        let root = try FixtureSupport.makeTempDir("restore-root")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../outside.flac", "/etc/passwd.flac", "a/../../b.flac", "x.dylib"] {
            #expect(throws: (any Error).self) {
                try TagUpgrader.restoreFile(.init(path: path, properties: ["ARTIST": ["x"]]), root: root)
            }
        }
    }
}
