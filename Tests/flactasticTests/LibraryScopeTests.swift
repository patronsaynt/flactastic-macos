import Foundation
import Testing
@testable import flactastic

/// Points the library data folder at a temporary one for a test, so nothing
/// touches this Mac's real Application Support.
@MainActor
func withTemporaryLibraryData(_ body: (URL) async throws -> Void) async rethrows {
    let saved = LibraryDataFolder.local
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("flactastic-scope-\(UUID().uuidString)", isDirectory: true)
    LibraryDataFolder.local = temp
    let keys = LibraryScope.dataKeys + LibraryScope.switchKeys
    let before = LibraryScope.values(keys)
    defer {
        LibraryScope.restore(before, keys: keys, clearMissing: true)
        LibraryDataFolder.local = saved
        try? FileManager.default.removeItem(at: temp)
    }
    try await body(temp)
}

