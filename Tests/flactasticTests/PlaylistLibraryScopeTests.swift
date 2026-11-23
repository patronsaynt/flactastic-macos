import Foundation
import Testing
@testable import flactastic

// A server library's playlists live with the account, never in the music
// folder, which can also be a local library holding its own.

private func scratch(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flactastic-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
@Test("A server library doesn't read or write the folder's playlists")
func serverPlaylistsStayApart() throws {
    let folder = try scratch("shared-folder")
    let support = try scratch("account")

    // The local library, in the folder.
    let local = PlaylistStore()
    local.load(from: folder)
    _ = local.createPlaylist(name: "Local only")
    let folderFile = folder.appendingPathComponent(".flactastic/playlists.json")
    let before = try Data(contentsOf: folderFile)

    // The server library, using the same folder for its offline copies.
    let server = PlaylistStore()
    server.load(storeAt: support.appendingPathComponent("playlists.json"))
    #expect(server.playlists.isEmpty)
    _ = server.createPlaylist(name: "Server only")

    #expect(try Data(contentsOf: folderFile) == before)
    let reopenedLocal = PlaylistStore()
    reopenedLocal.load(from: folder)
    #expect(reopenedLocal.playlists.map(\.name) == ["Local only"])
    let reopenedServer = PlaylistStore()
    reopenedServer.load(storeAt: support.appendingPathComponent("playlists.json"))
    #expect(reopenedServer.playlists.map(\.name) == ["Server only"])
}
