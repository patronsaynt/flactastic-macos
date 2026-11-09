import Foundation
import Testing
@testable import flactastic

// Cover for the cleanup sweeps: tag backups, crash-leftover temp files and the
// thumbnail size cap. Each test runs in its own scratch folder.

private func scratchFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flactastic-housekeeping-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func makeFile(_ name: String, in dir: URL, daysOld: Double, bytes: Int = 1, now: Date) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data(repeating: 0, count: bytes).write(to: url)
    try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path
    )
    return url
}

private func names(in dir: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
}

// MARK: - Tag backups

@Test func tagBackupsKeepNewestTwentyAndAnythingUnderNinetyDays() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()

    // 25 old backups (100+ days): only the newest 20 of them survive.
    for i in 0..<25 { try makeFile("tag-backup-old-\(i).json", in: dir, daysOld: 100 + Double(i), now: now) }
    let removed = Housekeeping.pruneTagBackups(in: dir, now: now)

    #expect(removed.count == 5)
    let left = names(in: dir)
    #expect(left.count == 20)
    #expect(left.contains("tag-backup-old-0.json"))
    #expect(!left.contains("tag-backup-old-24.json"))
}

@Test func recentTagBackupsAreKeptEvenPastTwenty() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()

    for i in 0..<30 { try makeFile("tag-backup-\(i).json", in: dir, daysOld: Double(i), now: now) }
    try makeFile("notes.json", in: dir, daysOld: 400, now: now)

    #expect(Housekeeping.pruneTagBackups(in: dir, now: now).isEmpty)
    #expect(names(in: dir).count == 31)
}

// MARK: - Temp files

@Test func staleTempFilesAreSweptAndFreshOnesKept() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    let cast = dir.appendingPathComponent(Housekeeping.castFolderName, isDirectory: true)
    try FileManager.default.createDirectory(at: cast, withIntermediateDirectories: true)

    try makeFile("flactastic-dl-old.flac", in: dir, daysOld: 3, now: now)
    try makeFile("flac-lucida-old.m4a", in: dir, daysOld: 2, now: now)
    try makeFile("flactastic-dl-fresh.flac", in: dir, daysOld: 0.01, now: now)
    try makeFile("someone-elses-file.tmp", in: dir, daysOld: 30, now: now)
    try makeFile("123-44100-16.wav", in: cast, daysOld: 5, now: now)
    try makeFile("456-44100-16.wav", in: cast, daysOld: 0.01, now: now)

    let removed = Housekeeping.sweepTemporaryFiles(in: dir, now: now)

    #expect(removed.count == 3)
    #expect(names(in: dir).contains("flactastic-dl-fresh.flac"))
    #expect(names(in: dir).contains("someone-elses-file.tmp"))
    #expect(names(in: cast) == ["456-44100-16.wav"])
}

// MARK: - Size cap

@Test func trimDeletesLeastRecentlyUsedUntilUnderTarget() throws {
    let dir = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()

    // Five 100-byte files, oldest first: a.jpg … e.jpg.
    for (i, name) in ["e", "d", "c", "b", "a"].enumerated() {
        try makeFile("\(name).jpg", in: dir, daysOld: Double(i), bytes: 100, now: now)
    }

    #expect(Housekeeping.trimDirectory(dir, toBytes: 250, ifOver: 600).isEmpty)

    let removed = Housekeeping.trimDirectory(dir, toBytes: 250, ifOver: 400)
    #expect(Set(removed.map(\.lastPathComponent)) == ["a.jpg", "b.jpg", "c.jpg"])
    #expect(names(in: dir) == ["d.jpg", "e.jpg"])
}
