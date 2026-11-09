import CryptoKit
import Foundation
import os

/// A stable ID for a library folder, kept in `<root>/.flactastic/library.json`
/// so it travels with the music. Machine-local data about a library (its
/// listening history) is filed under this ID in Application Support instead of
/// inside the folder, which may be a shared network drive.
///
/// The ID survives the folder moving or being remounted at a different path.
/// A copied folder keeps the same ID, so both copies share their local data.
enum LibraryIdentity {
    private static let log = Logger(subsystem: "flactastic", category: "LibraryIdentity")

    private struct File: Codable {
        var version: Int
        var id: UUID
    }

    static func fileURL(for root: URL) -> URL {
        root.appendingPathComponent(".flactastic", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    /// The library's ID, creating `library.json` the first time. When the
    /// folder can't be written to (a read-only share), returns an ID derived
    /// from the folder's path instead, so the library still gets consistent
    /// local data on this Mac.
    static func id(for root: URL) -> UUID {
        let url = fileURL(for: root)
        if let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            return file.id
        }
        let fresh = UUID()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(File(version: 1, id: fresh))
            // withoutOverwriting: if another process created it first, use theirs.
            try data.write(to: url, options: .withoutOverwriting)
            return fresh
        } catch {
            if let data = try? Data(contentsOf: url),
               let file = try? JSONDecoder().decode(File.self, from: data) {
                return file.id
            }
            log.error("Couldn't write library.json, using a path-based ID: \(error.localizedDescription, privacy: .public)")
            return pathDerivedID(for: root)
        }
    }

    /// A UUID built from the hash of the folder's path.
    static func pathDerivedID(for root: URL) -> UUID {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
