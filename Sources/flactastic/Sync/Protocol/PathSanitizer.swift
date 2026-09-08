import Foundation

/// Turns a relative path supplied by a *remote peer* into a path that is
/// guaranteed to land inside our own library root.
///
/// This is the single most security-sensitive type in the sync feature. Every
/// byte a peer sends us is untrusted, and the relative path is the one field
/// that directly controls where we write. A peer that can smuggle `../` past
/// this type can overwrite anything the app can reach — which, because
/// FLACtastic is unsandboxed on macOS, is the user's entire home directory.
///
/// The defence is layered rather than clever:
///
/// 1. **Reject, don't repair, structural attacks.** `..`, absolute paths, `~`
///    and null bytes fail outright. Silently stripping them invites the classic
///    `....//` bypass, where removing one `../` leaves another behind.
/// 2. **Normalise Unicode first.** `..` can be written with combining marks or
///    in NFD; comparing raw scalars misses those. Everything is folded to NFC
///    before any comparison.
/// 3. **Sanitise each surviving component** through the same
///    `ImportCopy.sanitize` the local import path already uses, so separators
///    that are legal on other platforms (`\` from a future Windows port) cannot
///    reintroduce structure.
/// 4. **Re-check the result against the root after symlink resolution.** A
///    path built only from safe components still escapes if an existing
///    intermediate directory is a symlink pointing elsewhere.
///
/// Pure Foundation and fully synchronous so it can be exhaustively unit-tested
/// without a filesystem for steps 1–3.
enum PathSanitizer {

    // MARK: - Limits

    /// APFS/HFS+ allow 255 UTF-8 bytes per component. Matching that exactly
    /// means a name we accept is a name we can actually create.
    static let maxComponentBytes = 255

    /// Depth cap. Real libraries are `Artist/Album/Track` — three levels. 32
    /// leaves enormous headroom for exotic Organizer profiles while bounding
    /// how many directories one message can make us create.
    static let maxDepth = 32

    /// Cap on the whole path, so a peer cannot approach the OS `PATH_MAX`
    /// and cause failures deep inside a transfer rather than up front.
    static let maxTotalBytes = 3072

    // MARK: - Errors

    enum Rejection: Error, Equatable, CustomStringConvertible {
        case empty
        case nullByte
        case absolutePath
        case parentTraversal
        case homeReference
        case currentDirectoryComponent
        case emptyComponent
        case componentTooLong(String)
        case tooDeep(Int)
        case tooLong(Int)
        case unsupportedFormat(String)
        case escapesRoot(String)

        var description: String {
            switch self {
            case .empty:                       return "Path is empty."
            case .nullByte:                    return "Path contains a null byte."
            case .absolutePath:                return "Path is absolute."
            case .parentTraversal:             return "Path contains a parent-directory reference."
            case .homeReference:               return "Path references a home directory."
            case .currentDirectoryComponent:   return "Path contains a current-directory reference."
            case .emptyComponent:              return "Path contains an empty component."
            case .componentTooLong(let c):     return "Path component is too long: \(c)"
            case .tooDeep(let d):              return "Path is \(d) levels deep."
            case .tooLong(let b):              return "Path is \(b) bytes long."
            case .unsupportedFormat(let e):    return "Unsupported file type: .\(e)"
            case .escapesRoot(let p):          return "Path resolves outside the library: \(p)"
            }
        }
    }

    // MARK: - Structural sanitising

    /// Validates and normalises an untrusted relative path.
    ///
    /// Returns a path built only from sanitised components, joined with `/`,
    /// with no leading or trailing separator. Throws `Rejection` rather than
    /// returning a "best effort" path — a malformed path from a peer is a
    /// protocol violation worth surfacing, not something to guess at.
    static func sanitizeRelativePath(_ raw: String) throws -> String {
        guard !raw.isEmpty else { throw Rejection.empty }
        guard !raw.utf8.contains(0) else { throw Rejection.nullByte }
        guard raw.utf8.count <= maxTotalBytes else { throw Rejection.tooLong(raw.utf8.count) }

        // Normalise before any comparison. `..` and `~` have decomposed and
        // fullwidth spellings; folding to NFC makes the checks below total.
        let normalised = raw.precomposedStringWithCanonicalMapping

        guard !normalised.hasPrefix("/") else { throw Rejection.absolutePath }
        guard !normalised.hasPrefix("~") else { throw Rejection.homeReference }
        // A drive-letter or UNC prefix from a Windows peer is also absolute.
        guard !normalised.hasPrefix("\\") else { throw Rejection.absolutePath }
        if normalised.count >= 2 {
            let chars = Array(normalised)
            if chars[1] == ":" && chars[0].isLetter { throw Rejection.absolutePath }
        }

        // Split on both separators. A backslash is a legal filename character
        // on APFS, but treating it as a separator here is strictly safer: the
        // worst case is that we reject a path a peer could have sent, and the
        // best case is that we don't let a Windows-shaped path smuggle a
        // component boundary past the per-component checks below.
        let rawComponents = normalised.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "/" || $0 == "\\" }
        ).map(String.init)

        var safeComponents: [String] = []
        for (index, component) in rawComponents.enumerated() {
            // A trailing separator is tolerated (directory-style path); any
            // other empty component means `//`, which is malformed input.
            if component.isEmpty {
                if index == rawComponents.count - 1 { continue }
                throw Rejection.emptyComponent
            }
            if component == "." { throw Rejection.currentDirectoryComponent }
            if component == ".." { throw Rejection.parentTraversal }
            if component.hasPrefix("~") { throw Rejection.homeReference }
            // Reject dot-only components *before* sanitising. `sanitize`
            // defuses a leading dot by prefixing "_", which would turn "..."
            // into the innocuous-looking "_..." and hide the fact that the
            // peer sent a traversal primitive in the first place.
            guard component.contains(where: { $0 != "." }) else {
                throw Rejection.parentTraversal
            }
            guard component.utf8.count <= maxComponentBytes else {
                throw Rejection.componentTooLong(component)
            }

            // Reuse the local import sanitiser so remote-authored names get
            // exactly the same treatment as a locally imported file: illegal
            // characters removed, hidden-file prefix defused.
            let cleaned = ImportCopy.sanitize(component)

            // `sanitize` can empty a component out entirely (a name made
            // only of illegal characters), in which case it returns its
            // "Unknown" fallback. Guard anyway: an empty component here would
            // silently collapse a path level.
            guard !cleaned.isEmpty else { throw Rejection.emptyComponent }
            safeComponents.append(cleaned)
        }

        guard !safeComponents.isEmpty else { throw Rejection.empty }
        guard safeComponents.count <= maxDepth else { throw Rejection.tooDeep(safeComponents.count) }

        return safeComponents.joined(separator: "/")
    }

    /// As `sanitizeRelativePath`, but additionally requires the file extension
    /// to be one FLACtastic recognises. Applied to every incoming *track* so a
    /// peer cannot write a `.dylib`, `.plist`, or shell script into the
    /// library folder — which, given the app is unsandboxed, would otherwise be
    /// a code-execution primitive against anything that scans that folder.
    static func sanitizeAudioRelativePath(_ raw: String) throws -> String {
        let path = try sanitizeRelativePath(raw)
        let ext = (path as NSString).pathExtension
        guard AudioFileFormat.classify(pathExtension: ext) != nil else {
            throw Rejection.unsupportedFormat(ext)
        }
        return path
    }

    // MARK: - Filesystem resolution

    /// Resolves a sanitised relative path to an absolute URL underneath `root`,
    /// then proves the result is still inside `root` after symlinks are taken
    /// into account.
    ///
    /// The second half matters even though `sanitizeRelativePath` has already
    /// removed every `..`: if `<root>/Music` is a symlink to `/tmp`, then the
    /// entirely innocent-looking `Music/x.flac` writes outside the library. We
    /// therefore resolve each *existing* ancestor and re-assert the prefix.
    /// Non-existent ancestors are safe by construction — we are the ones who
    /// will create them, as real directories.
    static func resolvedDestination(
        forSanitizedPath path: String,
        under root: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var current = canonicalRoot

        for component in path.split(separator: "/").map(String.init) {
            current = current.appendingPathComponent(component)
            // Only an existing entry can be a symlink; anything we create
            // ourselves is a plain directory or file.
            if fileManager.fileExists(atPath: current.path) {
                let resolved = current.resolvingSymlinksInPath().standardizedFileURL
                guard isContained(resolved, in: canonicalRoot) else {
                    throw Rejection.escapesRoot(current.path)
                }
                current = resolved
            }
        }

        guard isContained(current.standardizedFileURL, in: canonicalRoot) else {
            throw Rejection.escapesRoot(current.path)
        }
        return current.standardizedFileURL
    }

    /// Convenience: sanitise an untrusted audio path and resolve it in one go.
    static func destinationForIncomingTrack(
        remoteRelativePath: String,
        under root: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let safe = try sanitizeAudioRelativePath(remoteRelativePath)
        return try resolvedDestination(forSanitizedPath: safe, under: root, fileManager: fileManager)
    }

    /// True when `url` is `root` itself or lives beneath it.
    ///
    /// Compares path *components* rather than string prefixes: a plain
    /// `hasPrefix` check reports `/Library Backup` as being inside `/Library`.
    static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents  = url.standardizedFileURL.pathComponents
        guard urlComponents.count >= rootComponents.count else { return false }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }
}
