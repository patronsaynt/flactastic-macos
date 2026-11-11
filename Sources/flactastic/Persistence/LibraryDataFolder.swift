import Foundation
import os

/// Where the open library's customisation lives: artist profiles, spine
/// logos, the pinned Home highlight and mixes. The local library keeps
/// today's folder; each server account has its own, so nothing from one
/// library shows in another.
enum LibraryDataFolder {
    private static let state = OSAllocatedUnfairLock(initialState: (local: defaultLocal, current: defaultLocal))

    static var defaultLocal: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("flactastic", isDirectory: true)
    }

    /// The local library's folder (tests point it elsewhere).
    static var local: URL {
        get { state.withLock { $0.local } }
        set { state.withLock { $0 = (newValue, newValue) } }
    }

    /// The open library's folder.
    static var url: URL {
        let url = state.withLock { $0.current }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func use(_ url: URL) { state.withLock { $0.current = url } }

    /// A server account's folder: `servers/<server id>/<user id>/`.
    static func server(_ serverID: UUID, user: String) -> URL {
        local.appendingPathComponent("servers/\(serverID.uuidString)/\(user)", isDirectory: true)
    }

    /// Posted after a store saves customisation, so a server account syncs it.
    static let changed = Notification.Name("flactastic.libraryDataChanged")

    static func didChange() { NotificationCenter.default.post(name: changed, object: nil) }
}
