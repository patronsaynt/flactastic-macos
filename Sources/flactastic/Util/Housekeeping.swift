import Foundation

/// Clears up files the app creates and would otherwise keep forever: old tag
/// backups, leftover download and cast temp files, and thumbnails over the
/// disk budget. Every function here only touches files whose names the app
/// itself chose, and leaves anything recent alone so it never races work that
/// is still in progress.
enum Housekeeping {

    // MARK: - Launch

    /// Thumbnail disk budget. Over it, the least recently used are deleted
    /// until the folder is back under `thumbnailTrimTarget`, so a cache
    /// sitting right at the limit isn't trimmed on every launch.
    static let thumbnailBudget = 500 * 1024 * 1024
    static let thumbnailTrimTarget = 400 * 1024 * 1024

    /// Temp files younger than this are left alone: they may belong to a
    /// download or cast that started moments after launch.
    static let temporaryFileMinimumAge: TimeInterval = 24 * 3600

    /// Runs the launch-time sweeps on a low-priority background task.
    static func runAtLaunch() {
        Task.detached(priority: .background) {
            sweepTemporaryFiles(in: FileManager.default.temporaryDirectory)
            ArtworkImageCache.shared.trimDisk(toBytes: thumbnailTrimTarget, ifOver: thumbnailBudget)
        }
    }

    // MARK: - Tag backups

    /// Keeps the `keep` newest tag backups plus any younger than `maxAge`;
    /// deletes the rest. Only `tag-backup-*.json` files are considered.
    @discardableResult
    static func pruneTagBackups(
        in directory: URL,
        keep: Int = 20,
        maxAge: TimeInterval = 90 * 24 * 3600,
        now: Date = Date()
    ) -> [URL] {
        let files = filesWithDates(in: directory).filter {
            $0.url.lastPathComponent.hasPrefix("tag-backup-") && $0.url.pathExtension == "json"
        }
        let cutoff = now.addingTimeInterval(-maxAge)
        let newestFirst = files.sorted { $0.modified > $1.modified }
        var removed: [URL] = []
        for (index, file) in newestFirst.enumerated() where index >= keep && file.modified < cutoff {
            if (try? FileManager.default.removeItem(at: file.url)) != nil { removed.append(file.url) }
        }
        return removed
    }

    // MARK: - Temp files

    /// Names the app gives its temp files: streamed downloads
    /// (`DownloadCoordinator`) and Lucida downloads (`LucidaDownloadWriter`).
    static let temporaryFilePrefixes = ["flactastic-dl-", "flac-lucida-"]
    /// Folder of transcoded cast files (`StreamPreparer`).
    static let castFolderName = "FLACtastic-Cast"

    /// Deletes download and cast temp files older than `minimumAge` that a
    /// crash or force-quit left in `directory`.
    @discardableResult
    static func sweepTemporaryFiles(
        in directory: URL,
        minimumAge: TimeInterval = temporaryFileMinimumAge,
        now: Date = Date()
    ) -> [URL] {
        let cutoff = now.addingTimeInterval(-minimumAge)
        var stale = filesWithDates(in: directory).filter { file in
            let name = file.url.lastPathComponent
            return temporaryFilePrefixes.contains { name.hasPrefix($0) } && file.modified < cutoff
        }
        let castFolder = directory.appendingPathComponent(castFolderName, isDirectory: true)
        stale += filesWithDates(in: castFolder).filter { $0.modified < cutoff }

        var removed: [URL] = []
        for file in stale where (try? FileManager.default.removeItem(at: file.url)) != nil {
            removed.append(file.url)
        }
        return removed
    }

    // MARK: - Size cap

    /// When the files in `directory` total more than `limit` bytes, deletes
    /// the least recently modified until they total `target` or less.
    @discardableResult
    static func trimDirectory(_ directory: URL, toBytes target: Int, ifOver limit: Int) -> [URL] {
        let files = filesWithDates(in: directory, includeSize: true)
        var total = files.reduce(0) { $0 + $1.size }
        guard total > limit else { return [] }
        var removed: [URL] = []
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > target else { break }
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                total -= file.size
                removed.append(file.url)
            }
        }
        return removed
    }

    // MARK: - Helpers

    private struct FileInfo {
        let url: URL
        let modified: Date
        let size: Int
    }

    /// Regular files directly inside `directory` (not recursive).
    private static func filesWithDates(in directory: URL, includeSize: Bool = false) -> [FileInfo] {
        var keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        if includeSize { keys.append(.fileSizeKey) }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return [] }
        return contents.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return nil }
            return FileInfo(url: url, modified: modified, size: values.fileSize ?? 0)
        }
    }
}
