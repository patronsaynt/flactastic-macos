import Foundation
import Testing
@testable import flactastic

// Music only on this Mac, in a server library's offline folder: it uploads
// whenever it arrived, its plays move to the server track once it does, and
// changing the folder carries everything with it.

private func scratch(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flactastic-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func touch(_ url: URL, created: Date? = nil) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url)
    if let created {
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: created], ofItemAtPath: url.path)
    }
}

@Test("Files already in the folder before sign-in are queued; server tracks and copies aren't")
func newFilesIgnoresArrivalDate() throws {
    let root = try scratch("uploads")
    let old = root.appendingPathComponent("Kuru/Album/01 Old.flac")
    let fresh = root.appendingPathComponent("Kuru/Album/02 New.flac")
    let onServer = root.appendingPathComponent("Baby Keem/Album/01 Server.flac")
    let copy = root.appendingPathComponent("Steely Dan/Aja/01 Copy.flac")
    let notAudio = root.appendingPathComponent("Kuru/Album/cover.jpg")
    try touch(old, created: Date(timeIntervalSince1970: 0))
    try touch(fresh)
    try touch(onServer)
    try touch(copy)
    try touch(notAudio)

    let found = ServerUploads.newFiles(
        in: root,
        known: ["Steely Dan/Aja/01 Copy.flac"],
        serverPaths: [onServer.standardizedFileURL.path],
        queued: [],
        settle: 0
    )
    #expect(found.ready.map(\.lastPathComponent) == ["01 Old.flac", "02 New.flac"])
}

@Test("Queued or handled files aren't queued again")
func newFilesSkipsQueued() throws {
    let root = try scratch("uploads-queued")
    let file = root.appendingPathComponent("A/01.flac")
    try touch(file)
    let found = ServerUploads.newFiles(in: root, known: [], serverPaths: [], queued: [file.path], settle: 0)
    #expect(found.ready.isEmpty)
}

@MainActor
@Test("Staged plays move to the server track's ID")
func reassignMovesPlays() throws {
    let root = try scratch("plays")
    let store = ListeningStore(librariesDirectory: try scratch("plays-support"))
    store.load(from: root)
    let local = Track(url: root.appendingPathComponent("a.flac"), title: "Local", fileFormat: .flac)
    let other = Track(url: root.appendingPathComponent("b.flac"), title: "Other", fileFormat: .flac)
    store.record(track: local, startedAt: Date(), secondsListened: 200, counted: true)
    store.record(track: local, startedAt: Date(), secondsListened: 200, counted: true)
    store.record(track: other, startedAt: Date(), secondsListened: 200, counted: true)

    let serverID = UUID()
    let moved = store.reassign(trackID: local.id, to: serverID)

    #expect(moved.count == 2)
    #expect(store.allEvents.filter { $0.trackID == serverID }.count == 2)
    #expect(store.allEvents.filter { $0.trackID == local.id }.isEmpty)
    #expect(store.allEvents.filter { $0.trackID == other.id }.count == 1)
    #expect(store.reassign(trackID: local.id, to: serverID).isEmpty)
}

@Test("Moving the offline folder merges into the new one and keeps clashes behind")
func moveContentsMerges() throws {
    let old = try scratch("move-old")
    let new = try scratch("move-new")
    try touch(old.appendingPathComponent("Kuru/Album/01.flac"))
    try touch(old.appendingPathComponent(".flactastic/library.json"))
    try touch(old.appendingPathComponent("Shared/Album/01.flac"))
    try touch(new.appendingPathComponent("Shared/Album/01.flac"))   // a clash
    try touch(new.appendingPathComponent("Shared/Album/02.flac"))

    let left = ServerSession.moveContents(of: old, into: new)

    let fm = FileManager.default
    #expect(left == 1)
    #expect(fm.fileExists(atPath: new.appendingPathComponent("Kuru/Album/01.flac").path))
    #expect(fm.fileExists(atPath: new.appendingPathComponent(".flactastic/library.json").path))
    #expect(fm.fileExists(atPath: new.appendingPathComponent("Shared/Album/02.flac").path))
    #expect(fm.fileExists(atPath: old.appendingPathComponent("Shared/Album/01.flac").path))
    #expect(!fm.fileExists(atPath: old.appendingPathComponent("Kuru").path))
}

@Test("Queued uploads follow a moved folder")
func rebaseUploadPaths() throws {
    let support = try scratch("rebase")
    let old = URL(fileURLWithPath: "/tmp/old-root")
    let new = URL(fileURLWithPath: "/tmp/new-root")
    let item = ServerUploads.Item(id: UUID(), file: "/tmp/old-root/A/01.flac", name: "01.flac")
    try JSONEncoder().encode([item]).write(to: support.appendingPathComponent("uploads.json"))
    try JSONEncoder().encode(["/tmp/old-root/B/02.flac": "hash"]).write(to: support.appendingPathComponent("uploads-handled.json"))

    ServerUploads.rebasePaths(in: support, from: old, to: new)

    let items = try JSONDecoder().decode([ServerUploads.Item].self, from: Data(contentsOf: support.appendingPathComponent("uploads.json")))
    let handled = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: support.appendingPathComponent("uploads-handled.json")))
    #expect(items.map(\.file) == ["/tmp/new-root/A/01.flac"])
    #expect(handled == ["/tmp/new-root/B/02.flac": "hash"])
}
