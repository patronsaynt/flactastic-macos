import Foundation
import Testing
@testable import flactastic

// Upload staging: how many lanes run, files still being written wait, and a
// file changed after hashing is hashed again.

private func scratch(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flactastic-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let mb: Int64 = 1 << 20

@Test("A second lane opens after three clean single-lane uploads")
func lanesOpenAfterStreak() {
    var lanes = UploadLanes()
    lanes.succeeded(bytes: 40 * mb, seconds: 4, lanesInUse: 1)
    lanes.succeeded(bytes: 40 * mb, seconds: 4, lanesInUse: 1)
    #expect(lanes.lanes == 1)
    lanes.succeeded(bytes: 40 * mb, seconds: 4, lanesInUse: 1)
    #expect(lanes.lanes == 2)
}

@Test("Two lanes stay while they move clearly more than one")
func lanesStayWhenFaster() {
    var lanes = UploadLanes()
    for _ in 0..<3 { lanes.succeeded(bytes: 40 * mb, seconds: 4, lanesInUse: 1) }   // 10 MB/s alone
    lanes.succeeded(bytes: 40 * mb, seconds: 5, lanesInUse: 2)                      // 8 MB/s each, 16 together
    #expect(lanes.lanes == 2)
}

@Test("No gain from two lanes drops back to one, with a cooldown")
func lanesDropWithoutGain() {
    var lanes = UploadLanes()
    for _ in 0..<3 { lanes.succeeded(bytes: 40 * mb, seconds: 4, lanesInUse: 1) }   // 10 MB/s alone
    lanes.succeeded(bytes: 40 * mb, seconds: 8, lanesInUse: 2)                      // 5 MB/s each: no gain
    #expect(lanes.lanes == 1)
    // Ten clean uploads must pass before trying two again.
    for _ in 0..<12 { lanes.succeeded(bytes: 40 * mb, seconds: 4, lanesInUse: 1) }
    #expect(lanes.lanes == 2)
}

@Test("A failure drops to one lane")
func lanesDropOnFailure() {
    var lanes = UploadLanes()
    for _ in 0..<3 { lanes.succeeded(bytes: 40 * mb, seconds: 4, lanesInUse: 1) }
    #expect(lanes.lanes == 2)
    lanes.failed()
    #expect(lanes.lanes == 1)
    for _ in 0..<3 { lanes.succeeded(bytes: 40 * mb, seconds: 4, lanesInUse: 1) }
    #expect(lanes.lanes == 1)   // still cooling down
}

@Test("A file still being written waits for a later scan")
func newFilesWaitForWrites() throws {
    let root = try scratch("settle")
    let file = root.appendingPathComponent("A/01.flac")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: file)

    let now = ServerUploads.newFiles(in: root, known: [], serverPaths: [], queued: [])
    #expect(now.ready.isEmpty)
    #expect(now.stillWriting)

    let later = ServerUploads.newFiles(in: root, known: [], serverPaths: [], queued: [], now: Date().addingTimeInterval(60))
    #expect(later.ready.map(\.lastPathComponent) == ["01.flac"])
    #expect(!later.stillWriting)
}

@Test("A hash is stale once the file changes")
func hashGoesStaleOnEdit() throws {
    let root = try scratch("stamp")
    let file = root.appendingPathComponent("01.flac")
    try Data("first".utf8).write(to: file)
    let stamp = try #require(ServerUploads.stamp(file.path))
    var item = ServerUploads.Item(id: UUID(), file: file.path, name: "01.flac")
    item.contentHash = "abc"
    item.hashedSize = stamp.size
    item.hashedModified = stamp.modified
    #expect(ServerUploads.hashIsFresh(item))

    try Data("changed tags".utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
    #expect(!ServerUploads.hashIsFresh(item))

    item.contentHash = nil
    #expect(!ServerUploads.hashIsFresh(item))
}
