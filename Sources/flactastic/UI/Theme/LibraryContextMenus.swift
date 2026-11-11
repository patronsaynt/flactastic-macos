import SwiftUI

/// The standard right-click menus for albums and tracks, shared by every
/// page that shows them (artist, album, playlist), so the same item offers
/// the same actions wherever it appears. Pages pass in the actions that need
/// their own sheets: editing and removing from the library.
@MainActor
struct LibraryMenus {
    let player: PlayerState
    let library: LibraryStore
    let playlistStore: PlaylistStore
    let playlistAdd: PlaylistAddCoordinator
    let router: NavigationRouter

    /// Play Next, Add to Queue, Add to Playlist, then Open and Edit where the
    /// page offers them, the album's artists, and Remove last.
    func album(
        _ album: Album,
        open: (() -> Void)? = nil,
        edit: (() -> Void)? = nil,
        remove: (() -> Void)? = nil,
        showArtists: Bool = true
    ) -> [FLContextMenuItem] {
        var items = playbackContextMenuItems(for: album.tracks, player: player)
        items.append(addToPlaylist(album.tracks))
        var manage: [FLContextMenuItem] = []
        if let open { manage.append(.button("Open Album", systemImage: "square.grid.2x2", action: open)) }
        if let edit { manage.append(.button("Edit...", systemImage: "pencil", action: edit)) }
        if let offline = ServerSession.current.flatMap({ $0.isActive ? $0.offline : nil }) {
            let kept = offline.isKept(album: album.id)
            manage.append(.button(kept ? "Remove Offline Copy" : "Keep Offline",
                                  systemImage: kept ? "icloud.slash" : "arrow.down.circle") {
                offline.setAlbum(album.id, kept: !kept)
            })
        }
        if !manage.isEmpty {
            items.append(.divider)
            items.append(contentsOf: manage)
        }
        if showArtists && !album.isCompilation {
            let artists = artistContextMenuItems(credit: album.albumArtist ?? album.artist, library: library, router: router)
            if !artists.isEmpty {
                items.append(.divider)
                items.append(contentsOf: artists)
            }
        }
        appendRemove(remove, to: &items)
        return items
    }

    /// Play Next, Add to Queue, Add to Playlist, View Album, anything the page
    /// adds (Remove from Playlist), Edit, the track's artists, and Remove last.
    func track(
        _ track: Track,
        viewAlbum: Bool = true,
        extra: [FLContextMenuItem] = [],
        edit: (() -> Void)? = nil,
        remove: (() -> Void)? = nil
    ) -> [FLContextMenuItem] {
        var items = playbackContextMenuItems(for: [track], player: player)
        items.append(addToPlaylist([track]))
        if viewAlbum, let albumID = library.album(for: track)?.id {
            items.append(.button("View Album", systemImage: "square.grid.2x2") {
                router.navigateToAlbum(id: albumID)
            })
        }
        var manage = extra
        if let edit { manage.append(.button("Edit...", systemImage: "pencil", action: edit)) }
        if !manage.isEmpty {
            items.append(.divider)
            items.append(contentsOf: manage)
        }
        let artists = artistContextMenuItems(credit: track.artist ?? track.albumArtist, library: library, router: router)
        if !artists.isEmpty {
            items.append(.divider)
            items.append(contentsOf: artists)
        }
        appendRemove(remove, to: &items)
        return items
    }

    /// "Remove from Library" goes last, in red, on its own.
    private func appendRemove(_ remove: (() -> Void)?, to items: inout [FLContextMenuItem]) {
        guard let remove else { return }
        items.append(.divider)
        items.append(.button("Remove from Library", systemImage: "trash", destructive: true, action: remove))
    }

    /// "Add to Playlist" with every playlist, then a field for a new one.
    func addToPlaylist(_ tracks: [Track]) -> FLContextMenuItem {
        var children: [FLContextMenuItem] = []
        for playlist in playlistStore.playlists {
            children.append(.button(playlist.name) {
                playlistAdd.request(
                    tracks: tracks,
                    playlistID: playlist.id,
                    playlistName: playlist.name,
                    rootURL: library.rootURL,
                    store: playlistStore
                )
            })
        }
        if !children.isEmpty { children.append(.divider) }
        children.append(.textField("New playlist name…", systemImage: "plus") { name in
            playlistAdd.createPlaylistAndAdd(
                name: name,
                tracks: tracks,
                rootURL: library.rootURL,
                store: playlistStore
            )
        })
        return .submenu("Add to Playlist", systemImage: "plus.square.on.square", items: children)
    }
}
