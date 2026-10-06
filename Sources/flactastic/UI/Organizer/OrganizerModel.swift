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

    private let executor = OrganizerExecutor()
    private var previewTask: Task<Void, Never>?

    var moveCount: Int { operations.lazy.filter { if case .move = $0.status { return true } else { return false } }.count }
    var unchangedCount: Int { operations.lazy.filter { if case .unchanged = $0.status { return true } else { return false } }.count }
    var conflictCount: Int { operations.lazy.filter { if case .conflict = $0.status { return true } else { return false } }.count }

    /// Re-plans after a short quiet period. Called on every edit in the builder
    /// so the preview tracks the rules live; the debounce keeps a burst of
    /// keystrokes from replanning the whole library once per character, and the
    /// plan itself runs off the main actor so typing stays smooth.
    func schedulePreview(profile: OrganizerProfile, tracks: [Track], rootURL: URL?, debounceMilliseconds: Int = 300) {
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
                OrganizerPlanner.plan(tracks: tracks, profile: profile, rootURL: rootURL)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.operations = ops
            self.isPreviewStale = false
            self.isRecomputing = false
        }
    }

    func apply(library: LibraryStore, profile: OrganizerProfile) async {
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
