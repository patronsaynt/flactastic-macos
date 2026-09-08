import Foundation

/// Drives one complete sync run from handshake to summary.
///
/// ### Shape of a run
/// ```
/// initiator → hello                 responder → helloAck        (version check)
/// initiator → syncRequest(direction, filter, its manifest)
/// responder → syncRequest(inverted, filter, its manifest)
/// ── both sides now hold both manifests and both filters ──
/// each computes the plan independently; the initiator shows it to the user
/// initiator → planDecision(planHash, approved)
/// responder → checks the hash against its own computation
/// ── files flow in the agreed direction, then playlists ──
/// sender    → syncComplete
/// ```
///
/// ### Why both sides compute the plan
/// The receiver is the one whose files are at risk, so it must never act on a
/// plan the sender handed it. But the *initiator* is where the user is sitting,
/// so the plan has to be shown there. Rather than shipping a plan and hoping,
/// both sides derive it from the same two manifests with the same filters —
/// `SyncDiff.plan` is a pure function, so they must agree — and the exchanged
/// `planHash` is what proves they did. A mismatch means a library changed while
/// the confirmation sheet was open, and the run is abandoned rather than
/// applying an approval the user never actually gave.
actor SyncSession {

    // MARK: - Types

    struct Summary: Sendable, Equatable {
        var tracksTransferred = 0
        var playlistsTransferred = 0
        var bytesTransferred: Int64 = 0
        var skipped = 0
        /// Files that failed individually. A single bad file aborts that file,
        /// not the whole run — a library with one unreadable track should still
        /// sync the other nine thousand.
        var failures: [String] = []
    }

    /// What the caller must provide about this device.
    struct LocalContext: Sendable {
        let deviceID: UUID
        let displayName: String
        let kind: SyncDeviceKind
        let libraryRoot: URL
        let manifest: LibraryManifest
        let filter: SyncFilter
        /// Full playlist bodies, for when this side is the sender.
        let playlists: [Playlist]
    }

    enum SessionError: Error, CustomStringConvertible {
        case incompatibleVersion(SyncProtocol.Version)
        case unexpectedMessage(String)
        case declined
        case planChanged
        case noLibraryRoot
        case insufficientStorage(needed: Int64, available: Int64)
        case transferCapExceeded(Int64)

        var description: String {
            switch self {
            case .incompatibleVersion(let version):
                return "The other device speaks sync version \(version); this one speaks "
                     + "\(SyncProtocol.version). Update both to the same release."
            case .unexpectedMessage(let what):
                return "The other device sent something unexpected (\(what))."
            case .declined:
                return "Sync was cancelled."
            case .planChanged:
                return "The library changed while you were reviewing — nothing was transferred. Try again."
            case .noLibraryRoot:
                return "No music folder is open."
            case .insufficientStorage(let needed, let available):
                return "This sync needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) "
                     + "but only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is free."
            case .transferCapExceeded(let bytes):
                return "This sync would transfer "
                     + "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)), "
                     + "which is over the limit set for this device."
            }
        }
    }

    /// Progress reported to the UI. Deliberately coarse — the Sync screen shows
    /// one bar per device, not a per-file breakdown.
    struct Progress: Sendable {
        var completedFiles = 0
        var totalFiles = 0
        var bytesTransferred: Int64 = 0
        var totalBytes: Int64 = 0
        var currentFileName: String?

        var fraction: Double {
            guard totalBytes > 0 else { return totalFiles == 0 ? 1 : 0 }
            return min(1, Double(bytesTransferred) / Double(totalBytes))
        }
    }

    // MARK: - Initiator

    /// Runs the side the user is sitting at.
    ///
    /// - Parameter approve: shown the plan; returns whether to proceed. This is
    ///   the confirmation the user asked for — nothing is written or sent
    ///   before it returns true.
    func runInitiator(
        connection: SyncConnection,
        direction: SyncDirection,
        local: LocalContext,
        approve: @Sendable (SyncPlan) async -> Bool,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Summary {
        try await connection.send(.hello(.init(
            version: SyncProtocol.version, deviceID: local.deviceID,
            displayName: local.displayName, deviceKind: local.kind, isPaired: true
        )))
        guard case .helloAck(let ack) = try await connection.receiveMessage() else {
            throw SessionError.unexpectedMessage("expected helloAck")
        }
        guard SyncProtocol.version.isCompatible(with: ack.version) else {
            try? await connection.send(.protocolError(.init(
                code: .incompatibleVersion, message: "Version \(SyncProtocol.version) required."
            )))
            throw SessionError.incompatibleVersion(ack.version)
        }

        try await connection.send(.syncRequest(.init(
            direction: direction, filter: local.filter, manifest: local.manifest
        )))
        guard case .syncRequest(let peer) = try await connection.receiveMessage() else {
            throw SessionError.unexpectedMessage("expected the peer's manifest")
        }

        let plan = Self.plan(
            direction: direction,
            localManifest: local.manifest, localFilter: local.filter,
            peerManifest: peer.manifest, peerFilter: peer.filter,
            localIsInitiator: true
        )

        // Guard the receiver's limits before asking the user to approve
        // something that cannot finish.
        if direction == .pull {
            try Self.checkCapacity(plan: plan, filter: local.filter, libraryRoot: local.libraryRoot)
        }

        guard await approve(plan) else {
            try? await connection.send(.planDecision(.init(planHash: plan.planHash, approved: false)))
            throw SessionError.declined
        }
        try await connection.send(.planDecision(.init(planHash: plan.planHash, approved: true)))

        switch direction {
        case .push:
            return try await sendPayload(plan: plan, connection: connection, local: local, progress: progress)
        case .pull:
            return try await receivePayload(plan: plan, connection: connection, local: local, progress: progress)
        }
    }

    // MARK: - Responder

    /// Runs the side that accepted an incoming connection. No user is present
    /// here, so it makes no decisions beyond enforcing its own limits.
    /// - Parameter replaying: a message the caller already read off the
    ///   connection. The listener has to peek at the first message to tell a
    ///   pairing attempt from a sync, so it hands that message back here rather
    ///   than leaving the session to read one that has already been consumed.
    func runResponder(
        connection: SyncConnection,
        local: LocalContext,
        replaying: WireMessage? = nil,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Summary {
        let opening: WireMessage
        if let replaying {
            opening = replaying
        } else {
            opening = try await connection.receiveMessage()
        }
        guard case .hello(let hello) = opening else {
            throw SessionError.unexpectedMessage("expected hello")
        }
        guard SyncProtocol.version.isCompatible(with: hello.version) else {
            try? await connection.send(.protocolError(.init(
                code: .incompatibleVersion, message: "Version \(SyncProtocol.version) required."
            )))
            throw SessionError.incompatibleVersion(hello.version)
        }
        try await connection.send(.helloAck(.init(
            version: SyncProtocol.version, deviceID: local.deviceID,
            displayName: local.displayName, deviceKind: local.kind, isPaired: true
        )))

        guard case .syncRequest(let request) = try await connection.receiveMessage() else {
            throw SessionError.unexpectedMessage("expected syncRequest")
        }
        // The direction the initiator named is from *its* point of view.
        let ourDirection = request.direction.inverted

        try await connection.send(.syncRequest(.init(
            direction: ourDirection, filter: local.filter, manifest: local.manifest
        )))

        let plan = Self.plan(
            direction: request.direction,
            localManifest: local.manifest, localFilter: local.filter,
            peerManifest: request.manifest, peerFilter: request.filter,
            localIsInitiator: false
        )

        guard case .planDecision(let decision) = try await connection.receiveMessage(timeout: .seconds(600)) else {
            throw SessionError.unexpectedMessage("expected planDecision")
        }
        guard decision.approved else { throw SessionError.declined }

        // The user approved a specific set of changes. If our own computation
        // no longer produces that hash, the library moved underneath us and the
        // approval no longer describes what would happen.
        guard decision.planHash == plan.planHash else {
            try? await connection.send(.protocolError(.init(
                code: .planStale, message: "The plan changed."
            )))
            throw SessionError.planChanged
        }

        if ourDirection == .pull {
            try Self.checkCapacity(plan: plan, filter: local.filter, libraryRoot: local.libraryRoot)
        }

        switch ourDirection {
        case .push:
            return try await sendPayload(plan: plan, connection: connection, local: local, progress: progress)
        case .pull:
            return try await receivePayload(plan: plan, connection: connection, local: local, progress: progress)
        }
    }

    // MARK: - Payload: sending

    private func sendPayload(
        plan: SyncPlan,
        connection: SyncConnection,
        local: LocalContext,
        progress: @Sendable (Progress) -> Void
    ) async throws -> Summary {
        var summary = Summary()
        let queue = plan.allIncomingTracks
        var state = Progress(completedFiles: 0, totalFiles: queue.count,
                             bytesTransferred: 0, totalBytes: plan.totalTransferBytes)
        let transfer = FileTransfer()

        for entry in queue {
            try Task.checkCancellation()
            state.currentFileName = (entry.relativePath as NSString).lastPathComponent
            progress(state)

            let source = local.libraryRoot.appendingPathComponent(entry.relativePath)
            do {
                let sent = try await transfer.send(entry: entry, from: source, over: connection)
                if sent == 0 { summary.skipped += 1 } else { summary.tracksTransferred += 1 }
                summary.bytesTransferred += sent
                state.bytesTransferred += entry.fileSize
                state.completedFiles += 1
                progress(state)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One unreadable file must not abandon the whole library.
                summary.failures.append("\(entry.title): \(error)")
                state.completedFiles += 1
                state.bytesTransferred += entry.fileSize
                progress(state)
            }
        }

        let wanted = Set(plan.newPlaylists.map(\.id)).union(plan.playlistConflicts.map(\.incoming.id))
        let playlists = local.playlists.filter { wanted.contains($0.id) }
        if !playlists.isEmpty {
            try await connection.send(.playlists(.init(playlists: playlists)))
            summary.playlistsTransferred = playlists.count
        }

        try await connection.send(.syncComplete(.init(
            tracksTransferred: summary.tracksTransferred,
            playlistsTransferred: summary.playlistsTransferred,
            bytesTransferred: summary.bytesTransferred
        )))
        return summary
    }

    // MARK: - Payload: receiving

    /// Files landed by a run, handed back so the caller can update
    /// `TrackIDStore` and `PlaylistStore` on the main actor.
    struct Landed: Sendable {
        var files: [FileTransfer.ReceivedFile] = []
        var playlists: [Playlist] = []
    }

    private(set) var landed = Landed()

    private func receivePayload(
        plan: SyncPlan,
        connection: SyncConnection,
        local: LocalContext,
        progress: @Sendable (Progress) -> Void
    ) async throws -> Summary {
        var summary = Summary()
        var state = Progress(completedFiles: 0, totalFiles: plan.allIncomingTracks.count,
                             bytesTransferred: 0, totalBytes: plan.totalTransferBytes)
        let transfer = FileTransfer()
        let root = local.libraryRoot
        let filter = local.filter

        // Only files the plan actually covers are accepted. A peer that offers
        // anything else — a file the user excluded, or one never proposed — is
        // sending something the user never approved.
        let approved = Set(plan.allIncomingTracks.map(\.trackID))
        landed = Landed()

        loop: while true {
            try Task.checkCancellation()
            let message = try await connection.receiveMessage()

            switch message {
            case .fileStart(let start):
                guard approved.contains(start.trackID),
                      filter.allows(format: AudioFileFormat.classify(pathExtension:
                          (start.relativePath as NSString).pathExtension) ?? .flac,
                          artistKey: nil, fileSize: start.fileSize) else {
                    try await connection.send(.fileAccept(.init(
                        trackID: start.trackID, resumeOffset: 0, skip: true
                    )))
                    summary.skipped += 1
                    continue
                }
                do {
                    if let received = try await transfer.receive(
                        start: start, over: connection, libraryRoot: root,
                        placement: { relativePath in
                            try PathSanitizer.destinationForIncomingTrack(
                                remoteRelativePath: relativePath, under: root
                            )
                        }
                    ) {
                        landed.files.append(received)
                        summary.tracksTransferred += 1
                        summary.bytesTransferred += received.bytesWritten
                    } else {
                        summary.skipped += 1
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    summary.failures.append("\((start.relativePath as NSString).lastPathComponent): \(error)")
                }
                state.completedFiles += 1
                state.bytesTransferred += start.fileSize
                state.currentFileName = (start.relativePath as NSString).lastPathComponent
                progress(state)

            case .playlists(let payload):
                let allowed = payload.playlists.filter { filter.allows(playlistID: $0.id) }
                landed.playlists = allowed
                summary.playlistsTransferred = allowed.count

            case .syncComplete:
                break loop

            case .cancel(let cancellation):
                throw SessionError.unexpectedMessage(cancellation.reason)

            case .protocolError(let failure):
                throw SessionError.unexpectedMessage(failure.message)

            default:
                throw SessionError.unexpectedMessage("during transfer")
            }
        }

        FileTransfer.sweepAbandonedPartFiles(libraryRoot: root)
        return summary
    }

    // MARK: - Shared logic

    /// Computes the plan from the point of view of whichever side receives.
    ///
    /// Both peers run this with the same inputs, so both get the same
    /// `planHash` — which is what makes the approval verifiable rather than
    /// merely asserted.
    nonisolated static func plan(
        direction: SyncDirection,
        localManifest: LibraryManifest,
        localFilter: SyncFilter,
        peerManifest: LibraryManifest,
        peerFilter: SyncFilter,
        localIsInitiator: Bool
    ) -> SyncPlan {
        // `direction` is always expressed from the initiator's side.
        let initiatorIsReceiver = direction == .pull
        let weAreReceiver = localIsInitiator == initiatorIsReceiver

        let incoming = weAreReceiver ? peerManifest : localManifest
        let localSide = weAreReceiver ? localManifest : peerManifest
        // The receiver's own filter governs, and both sides know it because
        // filters are exchanged alongside manifests.
        let receiverFilter = weAreReceiver ? localFilter : peerFilter

        return SyncDiff.plan(
            incoming: incoming, local: localSide,
            direction: direction, filter: receiverFilter
        )
    }

    /// Refuses a run that cannot finish, before anything is transferred.
    ///
    /// Matters most on iOS, where the library lives in the app container and
    /// running out of space part-way through leaves a half-synced library and
    /// a device with no room to fix it.
    nonisolated static func checkCapacity(
        plan: SyncPlan,
        filter: SyncFilter,
        libraryRoot: URL
    ) throws {
        let needed = plan.totalTransferBytes
        if filter.exceedsTotalCap(needed) {
            throw SessionError.transferCapExceeded(needed)
        }
        guard let values = try? libraryRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage else { return }

        // Leave headroom: filling a volume completely is its own failure mode,
        // separate from the sync.
        let headroom: Int64 = 500 * 1024 * 1024
        guard needed + headroom <= available else {
            throw SessionError.insufficientStorage(needed: needed, available: available)
        }
    }
}
