import Foundation
import Testing
@testable import flactastic

// Tests for the diff — the part that decides what moves and what the user gets
// warned about. The two failure modes it has to avoid are opposites: transfer
// something that's already there (slow, and pointless over Wi-Fi), or overwrite
// something without saying so (data loss).

private func entry(
    id: UUID = UUID(),
    path: String = "Artist/Album/01 Song.flac",
    size: Int64 = 1000,
    hash: String = "hash-a",
    format: AudioFileFormat = .flac,
    fingerprint: String = "fp-a",
    title: String = "Song",
    artist: String? = "Artist",
    album: String? = "Album"
) -> TrackManifestEntry {
    TrackManifestEntry(
        trackID: id, relativePath: path, fileSize: size, contentHash: hash,
        format: format, tagFingerprint: fingerprint,
        title: title, artist: artist, album: album
    )
}

private func manifest(tracks: [TrackManifestEntry] = [], playlists: [PlaylistManifestEntry] = []) -> LibraryManifest {
    LibraryManifest(deviceID: UUID(), tracks: tracks, playlists: playlists)
}

// MARK: - New material

@Test("A track the receiver lacks is queued for transfer")
func newTrackIsQueued() {
    let incoming = entry()
    let plan = SyncDiff.plan(incoming: manifest(tracks: [incoming]), local: manifest(), direction: .push)
    #expect(plan.newTracks.count == 1)
    #expect(plan.trackConflicts.isEmpty)
    #expect(plan.totalTransferBytes == 1000)
    #expect(!plan.isEmpty)
}

@Test("Two identical libraries produce an empty plan")
func identicalLibrariesAreNoOp() {
    // The single most important case for a bi-directional workflow: syncing
    // back the other way immediately afterwards must do nothing at all.
    let shared = entry()
    let plan = SyncDiff.plan(incoming: manifest(tracks: [shared]),
                             local: manifest(tracks: [shared]), direction: .pull)
    #expect(plan.isEmpty)
    #expect(plan.totalTransferBytes == 0)
}

// MARK: - Identity matching

@Test("A stripped xattr falls back to matching on content hash")
func stripedXattrMatchesByHash() {
    // Crossing a FAT volume, a zip, or some cloud providers loses the xattr, so
    // the same bytes come back with a different UUID. Without the hash
    // fallback, every such file would transfer again on every single sync.
    let incoming = entry(id: UUID(), hash: "same-bytes")
    let local = entry(id: UUID(), path: "Elsewhere/song.flac", hash: "same-bytes")
    let plan = SyncDiff.plan(incoming: manifest(tracks: [incoming]),
                             local: manifest(tracks: [local]), direction: .push)
    #expect(plan.isEmpty)
}

@Test("Identity wins over path — a moved file is not re-sent")
func movedFileIsNotResent() {
    let id = UUID()
    let incoming = entry(id: id, path: "New/Location/song.flac")
    let local = entry(id: id, path: "Old/Location/song.flac")
    let plan = SyncDiff.plan(incoming: manifest(tracks: [incoming]),
                             local: manifest(tracks: [local]), direction: .push)
    // Same track, same bytes, same tags — the Organizer moved it on one side.
    #expect(plan.isEmpty)
}

// MARK: - Conflicts

@Test("Differing tags on the same track are a conflict, not a silent overwrite")
func tagDifferenceIsConflict() {
    let id = UUID()
    let incoming = entry(id: id, fingerprint: "fp-new", title: "Corrected Title")
    let local = entry(id: id, fingerprint: "fp-old", title: "Old Title")
    let plan = SyncDiff.plan(incoming: manifest(tracks: [incoming]),
                             local: manifest(tracks: [local]), direction: .push)

    #expect(plan.newTracks.isEmpty)
    #expect(plan.trackConflicts.count == 1)
    #expect(plan.overwriteCount == 1)
    #expect(plan.trackConflicts[0].differingFields.contains("Title"))
    // The file still has to move — a conflict is a transfer plus a warning.
    #expect(plan.allIncomingTracks.count == 1)
    #expect(plan.totalTransferBytes == 1000)
}

@Test("A re-encoded file with identical tags is still a conflict")
func differentAudioIsConflict() {
    // Same ID, same tags, different bytes: someone re-ripped or transcoded it.
    // Overwriting the user's copy silently would be data loss.
    let id = UUID()
    let plan = SyncDiff.plan(
        incoming: manifest(tracks: [entry(id: id, hash: "new-bytes")]),
        local: manifest(tracks: [entry(id: id, hash: "old-bytes")]),
        direction: .push
    )
    #expect(plan.trackConflicts.count == 1)
    #expect(plan.trackConflicts[0].differingFields.contains("Audio file"))
}

@Test("A tag change with no visible field difference is still explained")
func opaqueTagChangeIsLabelled() {
    // Year or genre changed: the fingerprint differs but title/artist/album
    // don't, so the row would otherwise appear in the list with no reason
    // given.
    let id = UUID()
    let plan = SyncDiff.plan(
        incoming: manifest(tracks: [entry(id: id, fingerprint: "fp-new")]),
        local: manifest(tracks: [entry(id: id, fingerprint: "fp-old")]),
        direction: .push
    )
    #expect(plan.trackConflicts[0].differingFields == ["Other tags"])
}

@Test("Cosmetic title differences don't invent a conflict")
func cosmeticDifferencesIgnored() {
    let id = UUID()
    let plan = SyncDiff.plan(
        incoming: manifest(tracks: [entry(id: id, fingerprint: "fp", title: "Song  ")]),
        local: manifest(tracks: [entry(id: id, fingerprint: "fp", title: "Song")]),
        direction: .push
    )
    #expect(plan.isEmpty)
}

// MARK: - Filters on receipt

@Test("The receiver re-applies the filter to what a peer offers")
func receiverReappliesFilter() {
    // A peer that ignores the agreed filter — buggy or hostile — must not be
    // able to push files the user excluded.
    let plan = SyncDiff.plan(
        incoming: manifest(tracks: [entry(format: .mp3), entry(id: UUID(), path: "b.flac", hash: "h2")]),
        local: manifest(),
        direction: .push,
        filter: SyncFilter(excludedFormats: [.mp3])
    )
    #expect(plan.newTracks.count == 1)
    #expect(plan.newTracks[0].format == .flac)
}

@Test("An oversized file offered by a peer is refused")
func oversizedFileRefused() {
    let plan = SyncDiff.plan(
        incoming: manifest(tracks: [entry(size: 50_000_000)]),
        local: manifest(),
        direction: .push,
        filter: SyncFilter(maxFileSizeBytes: 10_000_000)
    )
    #expect(plan.isEmpty)
}

@Test("Playlists are excluded when the filter says so")
func playlistFilterRespected() {
    let playlist = ManifestBuilder.manifestEntry(for: Playlist(name: "Late Night"))
    let plan = SyncDiff.plan(
        incoming: manifest(playlists: [playlist]),
        local: manifest(),
        direction: .push,
        filter: SyncFilter(includePlaylists: false)
    )
    #expect(plan.newPlaylists.isEmpty)
}

// MARK: - Playlists

@Test("A new playlist transfers; an unchanged one doesn't")
func playlistDiffing() {
    let playlist = Playlist(name: "Late Night")
    let entry = ManifestBuilder.manifestEntry(for: playlist)

    let fresh = SyncDiff.plan(incoming: manifest(playlists: [entry]), local: manifest(), direction: .push)
    #expect(fresh.newPlaylists.count == 1)

    let same = SyncDiff.plan(incoming: manifest(playlists: [entry]),
                             local: manifest(playlists: [entry]), direction: .push)
    #expect(same.isEmpty)
}

@Test("A reordered playlist is a conflict")
func reorderedPlaylistConflicts() {
    // Order is meaning in a playlist, so a reorder on one device is a real
    // change the other device's owner should be told about.
    let a = PlaylistEntry(trackID: UUID(), relativePath: "a.flac")
    let b = PlaylistEntry(trackID: UUID(), relativePath: "b.flac")
    let id = UUID()
    let forward = Playlist(id: id, name: "Set", entries: [a, b])
    let reversed = Playlist(id: id, name: "Set", entries: [b, a])

    let plan = SyncDiff.plan(
        incoming: manifest(playlists: [ManifestBuilder.manifestEntry(for: forward)]),
        local: manifest(playlists: [ManifestBuilder.manifestEntry(for: reversed)]),
        direction: .push
    )
    #expect(plan.playlistConflicts.count == 1)
    #expect(plan.overwriteCount == 1)
}

@Test("A renamed playlist is a conflict")
func renamedPlaylistConflicts() {
    let id = UUID()
    let plan = SyncDiff.plan(
        incoming: manifest(playlists: [ManifestBuilder.manifestEntry(for: Playlist(id: id, name: "New Name"))]),
        local: manifest(playlists: [ManifestBuilder.manifestEntry(for: Playlist(id: id, name: "Old Name"))]),
        direction: .push
    )
    #expect(plan.playlistConflicts.count == 1)
}

@Test("A playlist entry's local UUID doesn't affect its content hash")
func playlistEntryIDsAreLocal() {
    // PlaylistEntry.id is SwiftUI bookkeeping and differs between two devices
    // holding the same playlist. Including it would make every playlist a
    // permanent conflict.
    let trackID = UUID()
    let one = Playlist(name: "Set", entries: [PlaylistEntry(id: UUID(), trackID: trackID, relativePath: "a.flac")])
    let two = Playlist(name: "Set", entries: [PlaylistEntry(id: UUID(), trackID: trackID, relativePath: "a.flac")])
    #expect(ManifestBuilder.contentHash(for: one) == ManifestBuilder.contentHash(for: two))
}

// MARK: - Plan integrity

@Test("The plan hash covers what the plan would change")
func planHashIsMeaningful() {
    // The user approves a specific plan; the receiver re-checks this hash
    // before executing so an approval can't be applied to different work.
    let base = SyncDiff.plan(incoming: manifest(tracks: [entry()]), local: manifest(), direction: .push)
    let same = SyncDiff.plan(incoming: manifest(tracks: [entry(id: base.newTracks[0].trackID)]),
                             local: manifest(), direction: .push)
    #expect(base.planHash == same.planHash)

    let different = SyncDiff.plan(incoming: manifest(tracks: [entry(hash: "other")]),
                                  local: manifest(), direction: .push)
    #expect(base.planHash != different.planHash)
}

@Test("Direction is part of the plan hash")
func directionAffectsPlanHash() {
    let track = entry()
    let push = SyncDiff.plan(incoming: manifest(tracks: [track]), local: manifest(), direction: .push)
    let pull = SyncDiff.plan(incoming: manifest(tracks: [track]), local: manifest(), direction: .pull)
    #expect(push.planHash != pull.planHash)
}

@Test("Plans are ordered deterministically")
func planIsOrdered() {
    // Two devices computing the same plan must produce the same hash, and the
    // user should see a stable list rather than one that reshuffles per run.
    let tracks = [
        entry(path: "c.flac", hash: "c"),
        entry(path: "a.flac", hash: "a"),
        entry(path: "b.flac", hash: "b"),
    ]
    let plan = SyncDiff.plan(incoming: manifest(tracks: tracks), local: manifest(), direction: .push)
    #expect(plan.newTracks.map(\.relativePath) == ["a.flac", "b.flac", "c.flac"])
}
