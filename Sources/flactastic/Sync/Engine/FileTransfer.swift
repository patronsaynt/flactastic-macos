import Foundation

/// Moves one file's bytes across a `SyncConnection`, in both roles.
///
/// ### Landing a file safely
/// An incoming file is written to `<root>/.flactastic/incoming/<uuid>.part`,
/// verified against the sender's SHA-256, and only then moved into place with
/// `FileManager.replaceItemAt`. Nothing half-written is ever visible to the
/// scanner, and a transfer killed mid-flight leaves a `.part` file that either
/// resumes later or is swept up — never a truncated `.flac` that looks like a
/// real track and plays as silence.
///
/// ### Resume
/// The `.part` file *is* the resume record: its length is how many bytes are
/// already held. The receiver sends that as `resumeOffset` and the sender seeks
/// there. This is why the digest is only checked at the end — a partial file
/// cannot be verified, so resuming is a bet that the bytes on disk are sound,
/// settled by the whole-file hash before anything moves into the library.
///
/// An `actor` because it owns file handles and long-running I/O.
actor FileTransfer {

    enum TransferError: Error, CustomStringConvertible {
        case hashMismatch(expected: String, actual: String)
        case sizeMismatch(declared: Int64, received: Int64)
        case declaredSizeTooLarge(Int64)
        case sourceUnreadable(String)
        case cannotWrite(String)
        case rejectedByPeer(String)

        var description: String {
            switch self {
            case .hashMismatch:
                return "The transferred file didn't match its checksum and was discarded."
            case .sizeMismatch(let declared, let received):
                return "Expected \(declared) bytes but received \(received)."
            case .declaredSizeTooLarge(let size):
                return "The other device offered a \(size)-byte file, which is over the limit."
            case .sourceUnreadable(let name):
                return "Couldn't read \(name)."
            case .cannotWrite(let reason):
                return "Couldn't write the incoming file: \(reason)"
            case .rejectedByPeer(let reason):
                return "The other device refused the transfer: \(reason)"
            }
        }
    }

    // MARK: - Sending

    /// Offers one file and streams it if the receiver wants it.
    ///
    /// Returns the number of bytes actually sent — zero when the receiver
    /// already had the file, which is normal rather than a failure.
    @discardableResult
    func send(
        entry: TrackManifestEntry,
        from fileURL: URL,
        over connection: SyncConnection,
        progress: @Sendable (Int64) -> Void = { _ in }
    ) async throws -> Int64 {
        try await connection.send(.fileStart(.init(
            trackID: entry.trackID,
            relativePath: entry.relativePath,
            fileSize: entry.fileSize,
            contentHash: entry.contentHash,
            tagFingerprint: entry.tagFingerprint
        )))

        // The receiver gates every file. It may skip one it already has, or ask
        // to resume a partial one.
        let response = try await connection.receiveMessage()
        guard case .fileAccept(let accept) = response else {
            if case .protocolError(let failure) = response {
                throw TransferError.rejectedByPeer(failure.message)
            }
            throw SyncConnection.ConnectionError.protocolViolation("Expected fileAccept.")
        }
        guard accept.trackID == entry.trackID else {
            throw SyncConnection.ConnectionError.protocolViolation("fileAccept for the wrong file.")
        }
        if accept.skip { return 0 }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw TransferError.sourceUnreadable(fileURL.lastPathComponent)
        }
        defer { try? handle.close() }

        if accept.resumeOffset > 0 {
            try handle.seek(toOffset: UInt64(accept.resumeOffset))
        }

        var sent = accept.resumeOffset
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: SyncProtocol.fileChunkBytes) ?? Data()
            if chunk.isEmpty { break }
            try await connection.send(chunk: chunk)
            sent += Int64(chunk.count)
            progress(sent)
        }

        try await connection.send(.fileEnd(.init(trackID: entry.trackID)))
        return sent - accept.resumeOffset
    }

    // MARK: - Receiving

    struct ReceivedFile: Sendable {
        let trackID: UUID
        let destination: URL
        let relativePath: String
        let bytesWritten: Int64
    }

    /// Accepts one file, given the `fileStart` that announced it.
    ///
    /// - Parameter placement: maps the sender's relative path to a local
    ///   destination. Injected rather than hardcoded so the caller can route
    ///   the file through an Organizer profile instead of mirroring the
    ///   sender's layout — and so this type never has to know about either.
    func receive(
        start: WireMessage.FileStart,
        over connection: SyncConnection,
        libraryRoot: URL,
        placement: @Sendable (String) throws -> URL,
        alreadyHave: @Sendable (UUID, String) -> Bool = { _, _ in false },
        progress: @Sendable (Int64) -> Void = { _ in }
    ) async throws -> ReceivedFile? {
        // Refuse an absurd declared size before allocating anything for it.
        guard start.fileSize >= 0, start.fileSize <= SyncProtocol.maxFileBytes else {
            try await connection.send(.protocolError(.init(
                code: .sizeExceeded, message: "File too large."
            )))
            throw TransferError.declaredSizeTooLarge(start.fileSize)
        }

        // The sender's path is untrusted. Sanitising happens inside
        // `placement`, which the caller builds on `PathSanitizer` — a throw
        // here means the peer sent something malformed or hostile.
        let destination: URL
        do {
            destination = try placement(start.relativePath)
        } catch {
            try await connection.send(.protocolError(.init(
                code: .invalidPath, message: "Rejected path."
            )))
            throw error
        }

        if alreadyHave(start.trackID, start.relativePath) {
            try await connection.send(.fileAccept(.init(
                trackID: start.trackID, resumeOffset: 0, skip: true
            )))
            return nil
        }

        let partURL = try partFileURL(for: start.trackID, libraryRoot: libraryRoot)
        let resumeOffset = resumableByteCount(at: partURL, declaredSize: start.fileSize)

        try await connection.send(.fileAccept(.init(
            trackID: start.trackID, resumeOffset: resumeOffset, skip: false
        )))

        let written = try await writeChunks(
            from: connection,
            to: partURL,
            startingAt: resumeOffset,
            declaredSize: start.fileSize,
            trackID: start.trackID,
            progress: progress
        )

        guard written == start.fileSize else {
            try? FileManager.default.removeItem(at: partURL)
            throw TransferError.sizeMismatch(declared: start.fileSize, received: written)
        }

        // Verify before anything enters the library. A file that fails here is
        // deleted rather than kept for a later resume — a bad digest means the
        // bytes we hold are wrong, and resuming on top of them would only
        // reproduce the failure.
        let actual = try ContentHasher.hexDigest(ofFileAt: partURL)
        guard ContentHasher.digestsMatch(actual, start.contentHash) else {
            try? FileManager.default.removeItem(at: partURL)
            try await connection.send(.protocolError(.init(
                code: .hashMismatch, message: "Checksum mismatch."
            )))
            throw TransferError.hashMismatch(expected: start.contentHash, actual: actual)
        }

        try install(partURL, at: destination)
        return ReceivedFile(
            trackID: start.trackID,
            destination: destination,
            relativePath: start.relativePath,
            bytesWritten: written
        )
    }

    // MARK: - Internals

    private func writeChunks(
        from connection: SyncConnection,
        to partURL: URL,
        startingAt offset: Int64,
        declaredSize: Int64,
        trackID: UUID,
        progress: @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        guard let handle = FileHandle(forWritingAtPath: partURL.path) else {
            throw TransferError.cannotWrite(partURL.lastPathComponent)
        }
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seekToEnd()

        var written = offset
        while true {
            try Task.checkCancellation()
            let frame = try await connection.receiveFrame()

            switch frame.type {
            case .fileChunk:
                written += Int64(frame.payload.count)
                // Stop the moment a peer exceeds what it declared, rather than
                // letting it write until the disk fills.
                guard written <= declaredSize else {
                    throw TransferError.sizeMismatch(declared: declaredSize, received: written)
                }
                try handle.write(contentsOf: frame.payload)
                progress(written)

            case .control:
                let message = try WireMessage.decoded(from: frame.payload)
                switch message {
                case .fileEnd(let end):
                    guard end.trackID == trackID else {
                        throw SyncConnection.ConnectionError.protocolViolation("fileEnd for the wrong file.")
                    }
                    return written
                case .cancel(let cancellation):
                    throw TransferError.rejectedByPeer(cancellation.reason)
                case .protocolError(let failure):
                    throw TransferError.rejectedByPeer(failure.message)
                default:
                    throw SyncConnection.ConnectionError.protocolViolation("Unexpected message mid-transfer.")
                }
            }
        }
    }

    /// Bytes already held for this transfer, or 0 to start over.
    ///
    /// A `.part` longer than the declared size belongs to a different version
    /// of the file; resuming from it would splice two files together, so it is
    /// discarded.
    private func resumableByteCount(at partURL: URL, declaredSize: Int64) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: partURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return 0 }
        return size <= declaredSize ? size : 0
    }

    private func partFileURL(for trackID: UUID, libraryRoot: URL) throws -> URL {
        let directory = libraryRoot
            .appendingPathComponent(".flactastic", isDirectory: true)
            .appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(trackID.uuidString).part")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw TransferError.cannotWrite(url.lastPathComponent)
            }
        }
        return url
    }

    /// Moves a verified `.part` into the library.
    ///
    /// `replaceItemAt` rather than `moveItem`, so replacing an existing track
    /// during a conflict overwrite is atomic: readers see either the old file
    /// or the new one, never a gap.
    private func install(_ partURL: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partURL)
        } else {
            try fileManager.moveItem(at: partURL, to: destination)
        }
    }

    // MARK: - Housekeeping

    /// Deletes `.part` files left by transfers that will never resume.
    ///
    /// Called at the end of a run. Without it a library that saw a few failed
    /// syncs accumulates dead partial files in a hidden folder where nobody
    /// would ever think to look for the missing disk space.
    nonisolated static func sweepAbandonedPartFiles(libraryRoot: URL, olderThan age: TimeInterval = 7 * 24 * 3600) {
        let directory = libraryRoot
            .appendingPathComponent(".flactastic", isDirectory: true)
            .appendingPathComponent("incoming", isDirectory: true)
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-age)
        for url in contents where url.pathExtension == "part" {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}
