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

    /// Play Next, Add to Queue, Add to Playlist, then Open, Edit and Remove
    /// where the page offers them, and the album's artists.
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
        if let remove { manage.append(.button("Remove from Library", systemImage: "trash", action: remove)) }
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
        return items
    }

    /// Play Next, Add to Queue, Add to Playlist, View Album, anything the page
    /// adds (Remove from Playlist), Edit and Remove, and the track's artists.
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
        if let remove { manage.append(.button("Remove from Library", systemImage: "trash", action: remove)) }
        if !manage.isEmpty {
            items.append(.divider)
            items.append(contentsOf: manage)
        }
        let artists = artistContextMenuItems(credit: track.artist ?? track.albumArtist, library: library, router: router)
        if !artists.isEmpty {
            items.append(.divider)
            items.append(contentsOf: artists)
        }
        return items
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
