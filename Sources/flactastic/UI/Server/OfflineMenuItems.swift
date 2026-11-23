import SwiftUI

/// "Download", "Download 6 Remaining" and "Remove from This Mac" for any
/// tracks, album or playlist in a server library's menus. Nothing in a
/// folder library, and nothing for music that's only on this Mac (its file
/// is the only copy; Remove from Library deletes it).
@MainActor
enum OfflineMenu {
    enum Scope {
        /// Single tracks, a mix, or a selection: each track on its own.
        case tracks
        /// The album stays downloaded as it changes.
        case album(String)
        /// The playlist stays downloaded as it changes.
        case playlist(UUID)
    }

    static func items(for tracks: [Track], scope: Scope = .tracks) -> [FLContextMenuItem] {
        guard let session = ServerSession.current, session.isActive else { return [] }
        var seen = Set<UUID>()
        let ids = tracks.compactMap { track -> UUID? in
            guard !session.isLocalOnly(track), let id = session.serverID(for: track), seen.insert(id).inserted else { return nil }
            return id
        }
        guard !ids.isEmpty else { return [] }
        let offline = session.offline
        let here = offline.countHere(ids)
        var items: [FLContextMenuItem] = []
        if here < ids.count {
            let title = here == 0 ? "Download" : "Download \((ids.count - here).formatted()) Remaining"
            items.append(.button(title, systemImage: "arrow.down.circle") {
                switch scope {
                case .tracks: offline.download(tracks: ids)
                case .album(let id): offline.download(album: id, tracks: ids)
                case .playlist(let id): offline.download(playlist: id, tracks: ids)
                }
            })
        }
        if here > 0 {
            items.append(.button("Remove from This Mac", systemImage: "minus.circle") {
                switch scope {
                case .tracks: offline.removeFromThisMac(tracks: ids)
                case .album(let id): offline.removeFromThisMac(album: id, tracks: ids)
                case .playlist(let id): offline.removeFromThisMac(playlist: id, tracks: ids)
                }
            })
        }
        return items
    }

    /// The items after a divider, or nothing: for appending to a menu.
    static func section(for tracks: [Track], scope: Scope = .tracks) -> [FLContextMenuItem] {
        let items = items(for: tracks, scope: scope)
        return items.isEmpty ? [] : [.divider] + items
    }
}
