import Foundation
import Testing
@testable import flactastic

// Listening history lives in Application Support under the library's ID, not
// inside the (possibly shared) music folder, and is readable by its owner only.

private func scratchFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flactastic-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func permissions(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

@Test func libraryIDIsCreatedOnceAndReused() throws {
    let root = try scratchFolder("library")
    defer { try? FileManager.default.removeItem(at: root) }

    let first = LibraryIdentity.id(for: root)
    #expect(FileManager.default.fileExists(atPath: LibraryIdentity.fileURL(for: root).path))
    #expect(LibraryIdentity.id(for: root) == first)
}

@Test func pathDerivedIDIsStable() {
    let url = URL(fileURLWithPath: "/Volumes/NAS/Music")
    #expect(LibraryIdentity.pathDerivedID(for: url) == LibraryIdentity.pathDerivedID(for: url))
    #expect(LibraryIdentity.pathDerivedID(for: url) != LibraryIdentity.pathDerivedID(for: URL(fileURLWithPath: "/Music")))
}

@Test @MainActor func oldInLibraryHistoryMovesToSupportFolder() throws {
    let root = try scratchFolder("library")
    let support = try scratchFolder("support")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: support)
    }

    // An old-style history file in the library folder, holding one play.
    let legacy = ListeningStore.legacyHistoryURL(for: root)
    try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = ListeningStore(librariesDirectory: try scratchFolder("unused"))
    writer.record(track: Track(url: root.appendingPathComponent("a.flac"), title: "Moved", fileFormat: .flac),
                  startedAt: Date(), secondsListened: 200, counted: true)
    let event = try #require(writer.events.first)
    let legacyJSON = "{\"events\":[\(String(decoding: try JSONEncoder().encode(event), as: UTF8.self))],\"contexts\":[]}"
    try Data(legacyJSON.utf8).write(to: legacy)

    let store = ListeningStore(librariesDirectory: support)
    store.load(from: root)

    #expect(store.events.map(\.title) == ["Moved"])
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    let moved = ListeningStore.historyURL(for: root, librariesDirectory: support)
    #expect(moved.path.hasPrefix(support.path))
    #expect(permissions(moved) == 0o600)
    #expect(permissions(moved.deletingLastPathComponent()) == 0o700)
}
