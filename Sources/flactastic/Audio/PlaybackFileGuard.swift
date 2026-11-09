import Foundation

/// Holds background tag writes (found genres, fetched lyrics) away from files
/// playback is using: the playing track, and any track whose audio is already
/// being read ahead for a gapless transition. Writing tags rewrites a file in
/// place; doing that under the decoder hands it shifted bytes mid-song (the
/// 'bada' read error). The file itself is never at risk, but the playback is.
///
/// A held write runs once its file is free: the track finished or was
/// skipped. Scrubbing and pausing don't free it (the track is still playing),
/// so they never set a write off. User edits in the metadata editors don't
/// go through here: they're deliberate, and the player reopens around them.
@MainActor
final class PlaybackFileGuard {
    static let shared = PlaybackFileGuard()

    /// Supplies the files in use; set once at launch.
    var filesInUse: () -> Set<String> = { [] }

    private var held: [(path: String, work: @MainActor () async -> Void)] = []
    private var watcher: Task<Void, Never>?

    private init() {}

    func isInUse(_ url: URL) -> Bool {
        filesInUse().contains(url.standardizedFileURL.path)
    }

    /// Runs `work` now if `url` is free, or as soon as it is.
    func whenFree(_ url: URL, _ work: @escaping @MainActor () async -> Void) {
        guard isInUse(url) else {
            Task { await work() }
            return
        }
        held.append((url.standardizedFileURL.path, work))
        watch()
    }

    /// Checks once a second while anything is held; idle otherwise.
    private func watch() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while let self, !self.held.isEmpty, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.release()
            }
            self?.watcher = nil
        }
    }

    /// Runs every held write whose file is no longer in use.
    func release() {
        let busy = filesInUse()
        let ready = held.filter { !busy.contains($0.path) }
        guard !ready.isEmpty else { return }
        held.removeAll { !busy.contains($0.path) }
        for item in ready { Task { await item.work() } }
    }
}
