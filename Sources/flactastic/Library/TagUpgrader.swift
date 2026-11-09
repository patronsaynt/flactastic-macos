import Foundation
import Observation
import os
import CTagLib

/// The optional "Upgrade Tags" tool (Settings → Library → Artist Credits):
/// for files that hold several artists or album artists in one string
/// ("A ; B", "A / B"), adds ARTISTS / ALBUMARTISTS lists and the
/// FLACTASTIC_TAGVERSION=2 marker. Append only: the user's own ARTIST,
/// ALBUMARTIST and GENRE strings are never rewritten, so files look exactly as
/// they were kept. What the library shows doesn't change either.
///
/// Safety, in order:
/// 1. Before any file changes, the original values of every key it may touch
///    go to a timestamped JSON backup, which `restore(from:)` puts back.
/// 2. Each file is copied to a temporary file on the same volume, tagged
///    there, re-read and checked, and only then swapped in for the original
///    with `FileManager.replaceItemAt`. The original's creation date and date
///    added are carried over, so nothing jumps into Recently Added.
/// 3. A file that fails is logged and left as it was; the run continues.
///
/// Reads and writes go through TagLib's property map only, never the basic
/// tag API, whose returned strings share one global list with the scanner.
@MainActor
@Observable
final class TagUpgrader {
    static let shared = TagUpgrader()

    struct Progress: Equatable {
        var done = 0
        var total = 0
        var isRestore = false
    }

    struct Summary: Identifiable {
        let id = UUID()
        var isRestore: Bool
        var changed = 0
        var skipped = 0
        var failures: [String] = []
        var stopped = false
        var backupURL: URL?
    }

    private(set) var progress: Progress?
    var pendingSummary: Summary?
    @ObservationIgnored private var task: Task<Void, Never>?
    var isRunning: Bool { progress != nil }

    nonisolated private static let log = Logger(subsystem: "flactastic", category: "TagUpgrader")

    /// The keys an upgrade can change: everything a restore puts back.
    nonisolated static let touchedKeys = ["ARTIST", "ARTISTS", "ALBUMARTIST", "ALBUMARTISTS", "GENRE", "FLACTASTIC_TAGVERSION"]

    /// Tracks an upgrade would look at: not yet at the current tag version,
    /// with two or more artists or album artists. (Genres have no standard
    /// plural tag to add, and their strings are left alone.)
    static func candidates(in tracks: [Track]) -> [Track] {
        tracks.filter { t in
            guard t.tagVersion != MetadataWriter.currentTagVersion else { return false }
            return MultiValueParser.values(ofStored: t.artist).count > 1
                || MultiValueParser.values(ofStored: t.albumArtist).count > 1
        }
    }

    // MARK: - Running

    func upgrade(library: LibraryStore) {
        guard !isRunning, let root = library.rootURL else { return }
        let tracks = Self.candidates(in: library.tracks)
        guard !tracks.isEmpty else { return }
        progress = Progress(total: tracks.count)
        task = Task { [weak self] in
            var summary = Summary(isRestore: false)
            let urls = tracks.map(\.url)
            do {
                summary.backupURL = try await Task.detached(priority: .utility) {
                    try Self.writeBackup(of: urls, root: root)
                }.value
            } catch {
                Self.log.error("Backup failed, nothing changed: \(error.localizedDescription, privacy: .public)")
                summary.failures.append("Couldn't write the backup, so no files were changed: \(error.localizedDescription)")
                await self?.finish(summary, library: library, changed: [])
                return
            }
            var changed: [Track] = []
            for track in tracks {
                if Task.isCancelled { summary.stopped = true; break }
                let url = track.url
                let outcome = await Task.detached(priority: .utility) { Result { try Self.upgradeFile(at: url) } }.value
                switch outcome {
                case .success(true): summary.changed += 1; changed.append(track)
                case .success(false): summary.skipped += 1
                case .failure(let error):
                    Self.log.error("Upgrade failed for \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                    summary.failures.append("\(Self.relativePath(url, root: root)): \(error.localizedDescription)")
                }
                self?.progress?.done += 1
            }
            await self?.finish(summary, library: library, changed: changed)
        }
    }

    func restore(from backupURL: URL, library: LibraryStore) {
        guard !isRunning, let root = library.rootURL else { return }
        progress = Progress(isRestore: true)
        task = Task { [weak self] in
            var summary = Summary(isRestore: true, backupURL: backupURL)
            let backup: TagBackup
            do {
                backup = try await Task.detached { try TagBackup.read(from: backupURL) }.value
            } catch {
                summary.failures.append("Couldn't read the backup: \(error.localizedDescription)")
                await self?.finish(summary, library: library, changed: [])
                return
            }
            self?.progress?.total = backup.entries.count
            let byURL = Dictionary(library.tracks.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { a, _ in a })
            var changed: [Track] = []
            for entry in backup.entries {
                if Task.isCancelled { summary.stopped = true; break }
                let outcome = await Task.detached(priority: .utility) { Result { try Self.restoreFile(entry, root: root) } }.value
                switch outcome {
                case .success(let url?):
                    summary.changed += 1
                    if let t = byURL[url.standardizedFileURL] { changed.append(t) }
                case .success(nil): summary.skipped += 1
                case .failure(let error):
                    Self.log.error("Restore failed for an entry: \(error.localizedDescription, privacy: .public)")
                    summary.failures.append("\(entry.path): \(error.localizedDescription)")
                }
                self?.progress?.done += 1
            }
            await self?.finish(summary, library: library, changed: changed)
        }
    }

    func cancel() { task?.cancel() }

    /// Re-reads the changed files into the library in one batch, then shows
    /// the summary.
    private func finish(_ summary: Summary, library: LibraryStore, changed: [Track]) async {
        if !changed.isEmpty {
            let scanner = LibraryScanner()
            var reread: [Track] = []
            for track in changed { reread.append(await scanner.loadMetadata(for: track)) }
            library.replaceTracks(reread)
            library.normaliseArtistTags()
        }
        progress = nil
        task = nil
        pendingSummary = summary
    }

    // MARK: - Backups

    nonisolated static var backupDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("flactastic/TagBackups", isDirectory: true)
    }

    /// Reads the touched keys of every file and writes them to a new backup.
    /// The file name is a timestamp only; no tag text reaches the path.
    nonisolated static func writeBackup(of urls: [URL], root: URL, directory: URL = backupDirectory) throws -> URL {
        var entries: [TagBackup.Entry] = []
        for url in urls {
            guard let props = readKeys(touchedKeys, at: url) else { continue }
            entries.append(.init(path: relativePath(url, root: root), properties: props))
        }
        let backup = TagBackup(version: TagBackup.currentVersion, createdAt: Date(), entries: entries)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        var url = directory.appendingPathComponent("tag-backup-\(stamp.string(from: backup.createdAt)).json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("tag-backup-\(stamp.string(from: backup.createdAt))-\(n).json")
            n += 1
        }
        try backup.encoded().write(to: url, options: .atomic)
        return url
    }

    nonisolated static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    // MARK: - One file

    enum FileError: LocalizedError {
        case unreadable, saveFailed, verifyFailed, outsideLibrary, implausibleBackup
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file couldn't be opened."
            case .saveFailed: return "TagLib couldn't save the tags."
            case .verifyFailed: return "The rewritten tags didn't read back the same, so the original was kept."
            case .outsideLibrary: return "The path is outside the music folder."
            case .implausibleBackup: return "The backup's values for this file don't look like tags, so they weren't written."
            }
        }
    }

    /// Upgrades one file through a verified temporary copy. Returns false when
    /// there was nothing to do (already upgraded, or nothing multi-valued).
    nonisolated static func upgradeFile(at url: URL) throws -> Bool {
        guard let before = readFields(at: url) else { throw FileError.unreadable }
        guard before.tagVersion != MetadataWriter.currentTagVersion else { return false }
        // More values than the parser keeps: the backup and the rewrite would
        // both be capped, so a restore couldn't be exact. Leave the file be.
        guard let raw = readKeys(touchedKeys, at: url),
              raw.values.allSatisfy({ $0.count <= MultiValueParser.maxValues }) else { return false }
        let artist = MultiValueParser.values(ofStored: before.artist.value).count > 1 ? before.artist.value : nil
        let albumArtist = MultiValueParser.values(ofStored: before.albumArtist.value).count > 1 ? before.albumArtist.value : nil
        guard artist != nil || albumArtist != nil else { return false }

        return try replaceVerified(url) { file in
            let original = keyValues(file, touchedKeys.filter { $0 != "FLACTASTIC_TAGVERSION" })
            MetadataWriter.writeMultiValueFields(
                file, artist: artist.map { .some($0) }, albumArtist: albumArtist.map { .some($0) }, genres: nil,
                appendOnly: true)
            // The lists were already there (native values): don't rewrite the
            // file just to add the marker.
            return keyValues(file, touchedKeys.filter { $0 != "FLACTASTIC_TAGVERSION" }) != original
        } verify: { copy in
            guard let after = readFields(at: copy) else { return false }
            return after.tagVersion == MetadataWriter.currentTagVersion
                && after.artist.value == before.artist.value
                && after.albumArtist.value == before.albumArtist.value
                && after.genres.primary == before.genres.primary
                && after.genres.secondary == before.genres.secondary
        }
    }

    /// Puts one backup entry's values back. Returns the file's URL when it
    /// changed, nil when it already matched the backup.
    nonisolated static func restoreFile(_ entry: TagBackup.Entry, root: URL) throws -> URL? {
        let relative = try PathSanitizer.sanitizeAudioRelativePath(entry.path)
        let url = try PathSanitizer.resolvedDestination(forSanitizedPath: relative, under: root)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileError.unreadable }
        let wanted = touchedKeys.reduce(into: [String: [String]]()) { $0[$1] = entry.properties[$1] ?? [] }
        // A backup is read back as untrusted input: refuse values no tag of
        // ours would hold rather than write them into the file.
        guard wanted.values.allSatisfy({ $0.count <= 1_000 && $0.allSatisfy { $0.utf8.count <= 65_536 } }) else {
            throw FileError.implausibleBackup
        }
        guard let current = readKeys(touchedKeys, at: url) else { throw FileError.unreadable }
        guard current != wanted else { return nil }

        let changed = try replaceVerified(url) { file in
            for key in touchedKeys where keyValues(file, [key]) != [key: wanted[key] ?? []] {
                setList(file, key, wanted[key] ?? [])
            }
            return true
        } verify: { copy in
            readKeys(touchedKeys, at: copy) == wanted
        }
        return changed ? url : nil
    }

    /// Copies `url` to a temporary file on the same volume, lets `edit`
    /// change its tags (returning false means "nothing to save"), saves,
    /// checks the copy with `verify`, and swaps it in for the original.
    nonisolated private static func replaceVerified(
        _ url: URL,
        edit: (UnsafeMutablePointer<TagLib_File>) -> Bool,
        verify: (URL) -> Bool
    ) throws -> Bool {
        let fm = FileManager.default
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        try fm.copyItem(at: url, to: copy)

        let saved: Bool? = copy.path.withCString { path in
            guard let file = taglib_file_new(path) else { return nil }
            defer { taglib_file_free(file) }
            guard taglib_file_is_valid(file) != 0 else { return nil }
            guard edit(file) else { return false }
            return taglib_file_save(file) != 0 ? true : nil
        }
        switch saved {
        case nil: throw FileError.saveFailed
        case false?: return false
        case true?: break
        }
        guard verify(copy) else { throw FileError.verifyFailed }

        // A fresh URL, so the dates aren't ones an earlier read cached.
        let dates = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.creationDateKey, .addedToDirectoryDateKey])
        let result = try fm.replaceItemAt(url, withItemAt: copy) ?? url
        if let created = dates?.creationDate {
            try? fm.setAttributes([.creationDate: created], ofItemAtPath: result.path)
        }
        if let added = dates?.addedToDirectoryDate {
            setDateAdded(added, at: result)
        }
        return true
    }

    /// Sets the APFS "date added" that the library sorts Recently Added by.
    /// Foundation can read it but not write it, so this goes through
    /// `setattrlist(ATTR_CMN_ADDEDTIME)`.
    @discardableResult
    nonisolated static func setDateAdded(_ date: Date, at url: URL) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        let seconds = date.timeIntervalSince1970
        var time = timespec(tv_sec: Int(seconds.rounded(.down)),
                            tv_nsec: Int((seconds - seconds.rounded(.down)) * 1_000_000_000))
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return setattrlist(path, &list, &time, MemoryLayout<timespec>.size, 0) == 0
        }
    }

    // MARK: - TagLib

    nonisolated private static func readFields(at url: URL) -> LibraryScanner.MultiValueFields? {
        url.path.withCString { path in
            guard let file = taglib_file_new(path) else { return nil }
            defer { taglib_file_free(file) }
            guard taglib_file_is_valid(file) != 0 else { return nil }
            return LibraryScanner.multiValueFields(file, tag: nil)
        }
    }

    nonisolated static func readKeys(_ keys: [String], at url: URL) -> [String: [String]]? {
        url.path.withCString { path in
            guard let file = taglib_file_new(path) else { return nil }
            defer { taglib_file_free(file) }
            guard taglib_file_is_valid(file) != 0 else { return nil }
            return keyValues(file, keys)
        }
    }

    nonisolated private static func keyValues(_ file: UnsafeMutablePointer<TagLib_File>, _ keys: [String]) -> [String: [String]] {
        keys.reduce(into: [:]) { $0[$1] = LibraryScanner.propertyList(file, $1) }
    }

    nonisolated private static func setList(_ file: UnsafeMutablePointer<TagLib_File>, _ key: String, _ values: [String]) {
        key.withCString { k in
            guard let first = values.first else { taglib_property_set(file, k, nil); return }
            first.withCString { taglib_property_set(file, k, $0) }
            for v in values.dropFirst() { v.withCString { taglib_property_set_append(file, k, $0) } }
        }
    }
}

/// The JSON written before an upgrade: each file's path relative to the music
/// folder, and every value of each key the upgrade may touch.
struct TagBackup: Codable, Equatable {
    static let currentVersion = 1
    /// A backup larger than this isn't one we wrote; refuse it.
    static let maxBytes = 512 * 1024 * 1024

    struct Entry: Codable, Equatable, Sendable {
        var path: String
        var properties: [String: [String]]
    }

    var version: Int
    var createdAt: Date
    var entries: [Entry]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func read(from url: URL) throws -> TagBackup {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(TagBackup.self, from: Data(contentsOf: url))
        guard backup.version == currentVersion else { throw CocoaError(.fileReadCorruptFile) }
        return backup
    }
}
