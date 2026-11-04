import SwiftUI

/// The two ratings for a track in one of Home's generated mixes, on the mix
/// page's track menus. Each edits today's list in place, leaving the rest
/// where it is, and is remembered for every future day's build of the mix.
///
/// - More like this (up): the three closest tracks not already in the mix
///   go in right after it, replacing the three that fit the mix least. If
///   the mix is playing, they play next.
/// - Doesn't fit (down): the track leaves the mix for good (undone by the
///   page's "Bring back" button), the best-fitting track not yet in the mix
///   joins at the end, and if the track is playing it skips ahead.
@MainActor
func mixFeedbackItems(for track: Track, in mix: HomeFeed.Mix, player: PlayerState,
                      library: LibraryStore, settings: Settings) -> [FLContextMenuItem] {
    [
        .button("More Like This", systemImage: "hand.thumbsup") {
            let edit = MixRating(mix: mix, library: library, settings: settings)
            let added = edit.closest(to: track, count: 3)
            let dropped = edit.weakest(count: added.count, keeping: [track.url.path, player.currentTrack?.url.path].compactMap { $0 })
            MixSignals.shared.steer(mix.id, toward: track, inserted: added, dropped: dropped)
            if player.playbackSourceID == "mix:\(mix.editionID)", !added.isEmpty { player.playNext(added) }
        },
        .button("Doesn't Fit This Mix", systemImage: "hand.thumbsdown") {
            let edit = MixRating(mix: mix, library: library, settings: settings, without: track)
            MixSignals.shared.reject(track, from: mix.id, replacement: edit.bestNewcomer())
            if player.currentTrack?.url.path == track.url.path, player.playbackSourceID == "mix:\(mix.editionID)" { player.next() }
        },
        .divider,
    ]
}

/// The curator's view of one mix as it stands today, for a rating's edit.
@MainActor
private struct MixRating {
    let mix: HomeFeed.Mix
    let curator: MixCurator
    let core: MixCurator.Core
    let inMix: Set<String>
    let rejected: Set<String>
    let pool: [Track]

    init(mix: HomeFeed.Mix, library: LibraryStore, settings: Settings, without gone: Track? = nil) {
        self.mix = mix
        let resolver = library.makeArtistResolver()
        let signals = MixSignals.shared.signals(resolver: resolver, groups: settings.genreGroups)
        curator = MixCurator(resolver: resolver, signals: signals, events: [], tracks: [], artistMinutes: [:])
        let kept = mix.tracks.filter { $0.url.path != gone?.url.path }
        core = curator.core(of: kept, seedPaths: signals.seeds[mix.id] ?? [])
        inMix = Set(mix.tracks.map(\.url.path))
        rejected = (signals.rejected[mix.id] ?? []).union(gone.map { [$0.url.path] } ?? [])
        pool = HomeFeed.mixPool(tracks: library.tracks, albums: library.albums)
    }

    private func isNew(_ t: Track) -> Bool { !inMix.contains(t.url.path) && !rejected.contains(t.url.path) }

    func closest(to track: Track, count: Int) -> [Track] {
        Array(curator.similar(to: track, in: pool.filter(isNew), count: count))
    }

    /// The tracks that fit least, never those in `keeping`.
    func weakest(count: Int, keeping: [String]) -> Set<String> {
        guard count > 0 else { return [] }
        let keep = Set(keeping)
        let scored = mix.tracks.filter { !keep.contains($0.url.path) }
            .map { ($0.url.path, curator.fit($0, to: core) ?? 0) }
            .sorted { $0.1 < $1.1 }
        return Set(scored.prefix(count).map(\.0))
    }

    func bestNewcomer() -> Track? {
        pool.filter(isNew)
            .compactMap { t in curator.fit(t, to: core).map { (t, $0) } }
            .max { $0.1 < $1.1 }?.0
    }
}
