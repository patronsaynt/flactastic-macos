import Foundation
import Observation
import SwiftUI

/// View-model for the Organizer page. Owns the live preview state and drives
/// the executor. Reads tracks from `LibraryStore`; writes back via
/// `LibraryStore.replaceTracks` after a successful apply so the rest of the app
/// (Collection, queues, playlists) sees the new URLs without a rescan.
@Observable
@MainActor
final class OrganizerModel {
    var operations: [OrganizerOperation] = []
    var isPreviewStale: Bool = true
    var isApplying: Bool = false
    var lastError: String?
    var lastResultMessage: String?
    /// Phase + fractional progress (0...1) of an in-flight apply. nil when
    /// nothing is running. Drives the progress bar in the Organizer view.
    var applyPhaseLabel: String?
    var applyProgress: Double?
    /// True while a debounced re-plan is pending or running. The preview column
    /// keeps showing the previous plan (rather than flashing empty) and Apply is
    /// held until the numbers settle.
    var isRecomputing: Bool = false

    /// The server's hash of the plan on screen; applying sends it back (§12).
    private var planHash: String?

    private let executor = OrganizerExecutor()
    private var previewTask: Task<Void, Never>?

    var moveCount: Int { operations.lazy.filter { if case .move = $0.status { return true } else { return false } }.count }
    var unchangedCount: Int { operations.lazy.filter { if case .unchanged = $0.status { return true } else { return false } }.count }
    var conflictCount: Int { operations.lazy.filter { if case .conflict = $0.status { return true } else { return false } }.count }

    /// Re-plans after a short quiet period. Called on every edit in the builder
    /// so the preview tracks the rules live; the debounce keeps a burst of
    /// keystrokes from replanning the whole library once per character, and the
    /// plan itself runs off the main actor so typing stays smooth.
    func schedulePreview(profile: OrganizerProfile, tracks: [Track], rootURL: URL?, resolver: ArtistResolver? = nil,
                         debounceMilliseconds: Int = 300) {
        previewTask?.cancel()
        guard let rootURL else {
            previewTask = nil
            operations = []
            isRecomputing = false
            isPreviewStale = true
            lastError = "Choose a source folder in Settings before organizing."
            return
        }
        lastError = nil
        isRecomputing = true
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            guard !Task.isCancelled else { return }
            let ops = await Task.detached(priority: .userInitiated) {
                OrganizerPlanner.plan(tracks: tracks, profile: profile, rootURL: rootURL, resolver: resolver)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.operations = ops
            self.isPreviewStale = false
            self.isRecomputing = false
        }
    }

    /// A server library's preview: send the profiles, then ask the server for
    /// its plan. The server plans with its own split rules (§12).
    func scheduleServerPreview(session: ServerSession, store: OrganizerProfilesStore, library: LibraryStore) {
        previewTask?.cancel()
        lastError = nil
        isRecomputing = true
        let state = ServerSession.OrganizerState(profiles: store.profiles, selectedID: store.selectedID)
        let profileID = store.selectedID
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            do {
                try await session.putOrganizer(state)
                let plan = try await session.organizerPlan(profileID: profileID)
                guard !Task.isCancelled else { return }
                let root = library.rootURL ?? URL(fileURLWithPath: "/")
                let byID = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                self.operations = plan.operations.compactMap { op in
                    guard let track = byID[op.trackID] else { return nil }
                    let status: OrganizerOperation.Status = switch op.status {
                    case "move": .move
                    case "conflict": .conflict(reason: "Another track renders to the same path.")
                    default: .unchanged
                    }
                    return OrganizerOperation(id: op.trackID, track: track, sourceURL: root.appendingPathComponent(op.from),
                                              destinationURL: root.appendingPathComponent(op.to), status: status)
                }
                self.planHash = plan.planHash
                self.isPreviewStale = false
            } catch {
                self.lastError = error.localizedDescription
            }
            self.isRecomputing = false
        }
    }

    /// Applies the previewed plan on the server. If the library changed since
    /// the preview (`409 planStale`), nothing moves and the new plan is shown.
    func applyOnServer(session: ServerSession, store: OrganizerProfilesStore, library: LibraryStore) async {
        guard !isApplying, let planHash else { return }
        isApplying = true
        applyPhaseLabel = "Organizing on the server…"
        applyProgress = nil
        lastError = nil
        defer { isApplying = false; applyPhaseLabel = nil }
        do {
            let result = try await session.organizerApply(profileID: store.selectedID, planHash: planHash)
            lastResultMessage = "Organized \(result.moved) file\(result.moved == 1 ? "" : "s")."
            self.planHash = nil
            operations = []
            isPreviewStale = true
            await session.pullTracks()
        } catch ServerError.api(code: "planStale", _, _) {
            lastError = "The library changed since the preview. Here's the new plan."
            scheduleServerPreview(session: session, store: store, library: library)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func apply(library: LibraryStore, player: PlayerEngine? = nil, profile: OrganizerProfile) async {
        guard !isApplying else { return }
        guard let rootURL = library.rootURL else { return }
        isApplying = true
        applyPhaseLabel = "Preparing…"
        applyProgress = 0
        lastError = nil
        defer {
            isApplying = false
            applyPhaseLabel = nil
            applyProgress = nil
        }

        let ops = operations
        let result = await executor.run(
            operations: ops,
            rootURL: rootURL,
            deleteEmptyOriginals: profile.deleteEmptyOriginals,
            onProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateProgress(progress)
                }
            }
        )

        // Patch LibraryStore: replace each moved track with a copy at its new URL.
        let movedByID = Dictionary(uniqueKeysWithValues: result.moved.map { ($0.trackID, $0.newURL) })
        if !movedByID.isEmpty {
            let updated: [Track] = library.tracks.compactMap { t in
                movedByID[t.id].map { t.withURL($0) }
            }
            library.replaceTracks(updated)

            // Update TrackIDStore path keys so the sidecar reflects the new
            // folder layout. PlaylistEntry.trackID values are unaffected —
            // stable UUIDs survive the move without any playlist patching.
            let rootPath = rootURL.path
            let opByTrackID = Dictionary(
                uniqueKeysWithValues: ops.compactMap { op -> (UUID, OrganizerOperation)? in
                    guard case .move = op.status else { return nil }
                    return (op.track.id, op)
                }
            )
            var pathMap: [String: String] = [:]
            for moved in result.moved {
                guard let op = opByTrackID[moved.trackID] else { continue }
                let oldAbs = op.sourceURL.path
                let newAbs = moved.newURL.path
                guard oldAbs.hasPrefix(rootPath), newAbs.hasPrefix(rootPath) else { continue }
                let oldRel = String(oldAbs.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
                let newRel = String(newAbs.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
                pathMap[oldRel] = newRel
            }
            library.trackIDStore.renamePaths(pathMap)

            // The player's queue keeps its own copies of tracks — move those
            // too, or playback stops at the end of the current song.
            var newURLByOldPath: [String: URL] = [:]
            for moved in result.moved {
                guard let op = opByTrackID[moved.trackID] else { continue }
                newURLByOldPath[op.sourceURL.path] = moved.newURL
            }
            player?.relocate(newURLByOldPath)
        }

        let movedCount = result.moved.count
        let failedCount = result.failed.count
        let lostCount = result.lostFiles.count

        if lostCount > 0 {
            lastError = "Validation failed: \(lostCount) file\(lostCount == 1 ? " is" : "s are") missing from their destination after move. Check the source folder before re-running."
            lastResultMessage = nil
        } else if failedCount > 0 {
            lastError = "\(failedCount) file\(failedCount == 1 ? "" : "s") could not be moved. Organized \(movedCount)."
            lastResultMessage = nil
        } else {
            lastResultMessage = "Organized \(movedCount) file\(movedCount == 1 ? "" : "s")."
        }

        operations = []
        isPreviewStale = true

        // Rescan so the library matches the new folder layout even where the
        // in-memory patch above missed something (a track whose plan predates
        // a refresh, a failed or partial move). Tracks already patched to
        // their new URLs are kept as-is, so this is cheap when nothing's off.
        if !ops.isEmpty {
            library.refreshLibrary()
        }
    }

    private func updateProgress(_ progress: OrganizerExecutor.Progress) {
        let label: String
        switch progress.phase {
        case .moving: label = "Moving files"
        case .cleaningUp: label = "Cleaning up empty folders"
        case .validating: label = "Validating"
        }
        applyPhaseLabel = progress.total > 0
            ? "\(label) (\(progress.completed)/\(progress.total))"
            : label
        applyProgress = progress.total > 0
            ? Double(progress.completed) / Double(progress.total)
            : 0
    }
}
