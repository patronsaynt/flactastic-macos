import Foundation

/// Gives every audio file a stable UUID that survives moves, renames, and
/// reorganisations — whether performed inside the app or externally in Finder.
///
/// ### Storage strategy
/// The UUID is written as a macOS extended attribute (`com.flactastic.trackID`)
/// directly on the audio file. Because xattrs travel with the file on any
/// APFS or HFS+ volume, the identity is preserved no matter where the file ends up.
///
/// A JSON sidecar (`<root>/.flactastic/track-ids.json`) acts as a **read-ahead
/// cache**: on startup it pre-populates the in-memory map so the hot scan loop
/// can skip most xattr reads. The sidecar is always a *subset* of truth; the
/// xattr on the file is the authoritative source.
///
/// ### Xattr stripping
/// Xattrs can be lost when files cross certain boundaries (FAT/exFAT volumes,
/// some cloud-sync providers, zip archives). If the xattr is absent on a file
/// that the sidecar knows about (by path), the sidecar UUID is written back to
/// the file automatically. If neither source has a UUID, a fresh one is
/// generated and written to both.
///
/// Not `@Observable` and not `@MainActor` — synchronous helper owned by the
/// already-`@MainActor` `LibraryStore`.
final class TrackIDStore {

    // MARK: - Constants

    private static let xattrName = "com.flactastic.trackID"

    // MARK: - State

    /// In-memory cache populated from the sidecar on `load()`.
    /// Key: relative path (no leading slash). Value: stable UUID.
    private var cache: [String: UUID] = [:]

    private var sidecarURL: URL?

    // MARK: - Lifecycle

    /// Loads the sidecar cache from `<rootURL>/.flactastic/track-ids.json`.
    /// Call once in `openFolder` before scanning.
    func load(from rootURL: URL) {
        let dir = rootURL.appendingPathComponent(".flactastic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("track-ids.json")
        sidecarURL = url
        cache = [:]

        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            cache = try JSONDecoder().decode([String: UUID].self, from: data)
        } catch {
            print("[TrackIDStore] Failed to load sidecar: \(error). Starting fresh.")
        }
    }

    /// Writes the current in-memory cache to the sidecar. Call once after a
    /// full scan batch — not per-file.
    func save() {
        guard let url = sidecarURL else { return }
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[TrackIDStore] Failed to save sidecar: \(error)")
        }
    }

    // MARK: - ID assignment

    /// Returns the stable UUID for `fileURL`, using this priority:
    ///
    /// 1. **Xattr on file** — the file carries its own identity; use it and
    ///    update the cache if the path key changed (file was moved).
    /// 2. **Sidecar cache** — xattr was stripped; restore it to the file and
    ///    keep the cached UUID.
    /// 3. **Generate fresh** — first time this file has been seen; write UUID
    ///    to both xattr and cache.
    ///
    /// Does **not** call `save()` — callers batch the sidecar write after the
    /// full scan loop.
    func assign(fileURL: URL, relativePath: String) -> UUID {
        // 1. Try the xattr on the file itself — move-proof.
        if let fromXattr = readXattr(from: fileURL) {
            // Update cache if the path key has changed (manual move).
            cache[relativePath] = fromXattr
            return fromXattr
        }

        // 2. Xattr missing — check the sidecar cache and restore to file.
        if let fromCache = cache[relativePath] {
            writeXattr(fromCache, to: fileURL)
            return fromCache
        }

        // 3. Completely new file — generate, persist everywhere.
        let fresh = UUID()
        writeXattr(fresh, to: fileURL)
        cache[relativePath] = fresh
        return fresh
    }

    // MARK: - Adoption (sync)

    /// Forces `fileURL` to carry an identity chosen elsewhere.
    ///
    /// Used when a file arrives from a paired device: the sender already has a
    /// stable UUID for it, and both libraries should agree on that UUID so the
    /// next sync recognises the file by identity instead of re-hashing it and
    /// matching on content.
    ///
    /// Deliberately distinct from `assign`, which never overwrites an existing
    /// xattr — that non-destructive rule is what makes local scanning safe, and
    /// this is the one caller entitled to break it. It is only ever applied to
    /// a file this device just received and wrote, never to a pre-existing
    /// library file, so no local identity is ever clobbered.
    ///
    /// Does not call `save()`; the sync session batches the sidecar write once
    /// at the end of a run, matching the scan loop's contract.
    func adopt(_ id: UUID, for fileURL: URL, relativePath: String) {
        writeXattr(id, to: fileURL)
        cache[relativePath] = id
    }

    // MARK: - Path rename (post-Organizer, optional optimisation)

    /// Updates sidecar cache keys after the Organizer moves files.
    /// Not strictly necessary (the xattr on the file is the truth), but
    /// keeps the cache tidy and avoids a redundant xattr read on next launch.
    func renamePaths(_ pathMap: [String: String]) {
        guard !pathMap.isEmpty else { return }
        var changed = false
        for (old, new) in pathMap where old != new {
            guard let uuid = cache.removeValue(forKey: old) else { continue }
            cache[new] = uuid
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Xattr helpers

    private func readXattr(from url: URL) -> UUID? {
        let path = url.path
        // Query the size first.
        let size = getxattr(path, Self.xattrName, nil, 0, 0, 0)
        guard size == 36 else { return nil }   // UUID string is exactly 36 bytes
        var buffer = [UInt8](repeating: 0, count: 36)
        guard getxattr(path, Self.xattrName, &buffer, 36, 0, 0) == 36 else { return nil }
        let string = String(bytes: buffer, encoding: .utf8) ?? ""
        return UUID(uuidString: string)
    }

    private func writeXattr(_ uuid: UUID, to url: URL) {
        let string = uuid.uuidString        // always 36 ASCII chars
        _ = string.withCString { ptr in
            setxattr(url.path, Self.xattrName, ptr, strlen(ptr), 0, 0)
        }
    }
}
