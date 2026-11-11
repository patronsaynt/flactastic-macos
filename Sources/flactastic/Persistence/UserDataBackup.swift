import CommonCrypto
import CryptoKit
import Foundation
import os

/// "Back Up User Data…" and "Restore from Backup…": everything the person has
/// set up or built up in FLACtastic, in one `.flactastic` file.
///
/// ### What's in a backup
///  - Preferences the person has set (`flactastic.*` keys), minus sign-ins,
///    this Mac's sync identity, debug switches and passing UI state.
///  - From Application Support: artist edits, spine logos, mix feedback and
///    saved mixes, the pinned Home highlight, and listening history.
///  - From the music folder's `.flactastic`: playlists, track IDs, credit
///    split answers and the library ID.
///
/// Not included: music files, caches (fetched again), tag backups (tied to
/// the files as they were), the Spotify sign-in and sync pairing keys
/// (secrets that stay on this Mac).
///
/// ### File format (version 1)
/// ```
/// magic "FLACTBAK"  8 bytes
/// version           1 byte   (1)
/// flags             1 byte   (bit 0: encrypted)
/// if encrypted:
///   iterations      4 bytes, big-endian (PBKDF2-SHA256)
///   salt            16 bytes
/// body              rest of file
/// ```
/// The body is an `Archive` as a binary property list, LZFSE-compressed, and,
/// when encrypted, sealed with AES-256-GCM (nonce + ciphertext + tag) under a
/// key derived from the password, with the header as authenticated data so
/// it can't be altered either.
enum UserDataBackup {
    private static let log = Logger(subsystem: "flactastic", category: "UserDataBackup")

    static let fileExtension = "flactastic"
    static let magic = Data("FLACTBAK".utf8)
    static let formatVersion: UInt8 = 1
    static let pbkdf2Iterations: UInt32 = 600_000

    // MARK: - What's backed up

    /// Paths under Application Support/flactastic. A trailing "/" means the
    /// whole folder.
    static let supportPaths = [
        "artists.json",
        "pinned_highlight.json",
        "mixes/feedback.json",
        "mixes/saved_mixes.json",
        "SpineLogos/",
        "libraries/",
    ]

    /// Files in `<library root>/.flactastic`. `listening.json` is only there
    /// for a library not yet opened since history moved to Application Support.
    static let libraryFiles = [
        "library.json",
        "playlists.json",
        "track-ids.json",
        "split-decisions.json",
        "listening.json",
    ]

    /// Preference keys left out: secrets, this Mac's identity, debug switches,
    /// and state that only means something on the day it was written.
    static func isBackedUpPreference(_ key: String) -> Bool {
        guard key.hasPrefix("flactastic.") else { return false }
        let excludedPrefixes = ["flactastic.spotify.", "flactastic.sync.", "flactastic.debug."]
        if excludedPrefixes.contains(where: key.hasPrefix) { return false }
        let excluded: Set<String> = Set(Settings.legacyCredentialKeys + [
            "flactastic.ui.lastThrowDay",
            "flactastic.home.todayRotation",
        ])
        return !excluded.contains(key)
    }

    // MARK: - Archive

    struct Archive: Codable {
        var formatVersion: Int
        var createdAt: Date
        var appVersion: String?
        var libraryRootPath: String?
        /// The preferences, as a binary property list of `[String: Any]`.
        var preferences: Data
        /// Relative to Application Support/flactastic.
        var supportFiles: [String: Data]
        /// Relative to `<library root>/.flactastic`.
        var libraryFiles: [String: Data]
    }

    /// Where a backup reads from and a restore writes to. Injectable for tests.
    struct Locations {
        var supportDirectory: URL
        var defaults: UserDefaults
        var preferenceDomain: String

        static var current: Locations {
            Locations(
                supportDirectory: FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("flactastic", isDirectory: true),
                defaults: .standard,
                preferenceDomain: Bundle.main.bundleIdentifier ?? "flactastic"
            )
        }
    }

    enum BackupError: LocalizedError {
        case notABackup, newerVersion, passwordRequired, wrongPassword, damaged, unsafePath(String)

        var errorDescription: String? {
            switch self {
            case .notABackup: return "This isn't a FLACtastic backup."
            case .newerVersion: return "This backup was made by a newer version of FLACtastic. Update the app to restore it."
            case .passwordRequired: return "This backup is protected with a password."
            case .wrongPassword: return "The password is wrong, or the backup is damaged."
            case .damaged: return "The backup is damaged and can't be read."
            case .unsafePath(let path): return "The backup contains an unexpected path (\(path)), so it wasn't restored."
            }
        }
    }

    // MARK: - Making a backup

    /// Gathers everything into an archive. `libraryRoot` is the open music
    /// folder, if there is one.
    static func makeArchive(libraryRoot: URL?, at locations: Locations = .current) throws -> Archive {
        let fm = FileManager.default

        let domain = locations.defaults.persistentDomain(forName: locations.preferenceDomain) ?? [:]
        var prefs = domain.filter { isBackedUpPreference($0.key) }
        // While a server account is open its customisation sits in these
        // keys; back up this Mac's own instead.
        if let local = LibraryScope.stashedLocalValues(in: locations.supportDirectory) {
            for key in LibraryScope.dataKeys + LibraryScope.switchKeys { prefs[key] = local[key].flatMap(PrefsSync.plist) }
        }
        let prefsData = try PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0)

        var support: [String: Data] = [:]
        for path in supportPaths {
            let url = locations.supportDirectory.appendingPathComponent(path)
            if path.hasSuffix("/") {
                for (relative, data) in try filesUnder(url) { support[path + relative] = data }
            } else if fm.fileExists(atPath: url.path) {
                support[path] = try Data(contentsOf: url)
            }
        }

        var library: [String: Data] = [:]
        if let libraryRoot {
            let dir = libraryRoot.appendingPathComponent(".flactastic", isDirectory: true)
            for name in libraryFiles {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { library[name] = try Data(contentsOf: url) }
            }
        }

        return Archive(
            formatVersion: Int(formatVersion),
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            libraryRootPath: libraryRoot?.path,
            preferences: prefsData,
            supportFiles: support,
            libraryFiles: library
        )
    }

    /// The archive as a `.flactastic` file. An empty or nil password writes
    /// it unencrypted.
    static func encode(_ archive: Archive, password: String?) throws -> Data {
        let plist = try PropertyListEncoder.binary.encode(archive)
        guard let compressed = try? (plist as NSData).compressed(using: .lzfse) as Data else {
            throw BackupError.damaged
        }

        var header = magic
        header.append(formatVersion)
        guard let password, !password.isEmpty else {
            header.append(0)
            return header + compressed
        }
        header.append(1)
        var iterations = pbkdf2Iterations.bigEndian
        header.append(Data(bytes: &iterations, count: 4))
        let salt = randomBytes(16)
        header.append(salt)

        let key = try deriveKey(password: password, salt: salt, iterations: pbkdf2Iterations)
        let sealed = try AES.GCM.seal(compressed, using: key, authenticating: header)
        guard let combined = sealed.combined else { throw BackupError.damaged }
        return header + combined
    }

    /// Writes the backup to `url`, readable by its owner only.
    static func write(libraryRoot: URL?, password: String?, to url: URL, at locations: Locations = .current) throws {
        let data = try encode(makeArchive(libraryRoot: libraryRoot, at: locations), password: password)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Reading a backup

    /// Whether the file needs a password, without decoding it.
    static func isEncrypted(_ data: Data) throws -> Bool {
        let header = try parseHeader(data)
        return header.encrypted
    }

    static func decode(_ data: Data, password: String?) throws -> Archive {
        let header = try parseHeader(data)
        var compressed = data.subdata(in: header.length..<data.count)
        if header.encrypted {
            guard let password, !password.isEmpty else { throw BackupError.passwordRequired }
            let key = try deriveKey(password: password, salt: header.salt, iterations: header.iterations)
            do {
                let box = try AES.GCM.SealedBox(combined: compressed)
                compressed = try AES.GCM.open(box, using: key, authenticating: data.prefix(header.length))
            } catch {
                throw BackupError.wrongPassword
            }
        }
        guard let plist = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
              let archive = try? PropertyListDecoder().decode(Archive.self, from: plist)
        else { throw BackupError.damaged }
        guard archive.formatVersion <= Int(formatVersion) else { throw BackupError.newerVersion }
        return archive
    }

    private struct Header {
        var encrypted: Bool
        var iterations: UInt32 = 0
        var salt = Data()
        var length: Int
    }

    private static func parseHeader(_ data: Data) throws -> Header {
        let base = magic.count + 2
        guard data.count >= base, data.prefix(magic.count) == magic else { throw BackupError.notABackup }
        let bytes = [UInt8](data.prefix(base + 20))
        guard bytes[magic.count] <= formatVersion else { throw BackupError.newerVersion }
        let encrypted = bytes[magic.count + 1] & 1 == 1
        guard encrypted else { return Header(encrypted: false, length: base) }
        guard bytes.count >= base + 20 else { throw BackupError.damaged }
        let iterations = bytes[base..<base + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard (10_000...10_000_000).contains(iterations) else { throw BackupError.damaged }
        return Header(encrypted: true, iterations: iterations,
                      salt: Data(bytes[base + 4..<base + 20]), length: base + 20)
    }

    // MARK: - Restoring

    /// Replaces this Mac's user data with the archive's: the backed-up
    /// preference keys, the backed-up Application Support files, and the
    /// library sidecars (written to the backup's music folder when it exists
    /// here). Caches, the Spotify sign-in and paired devices are left as they
    /// are. Returns notes for anything that couldn't be put back.
    @discardableResult
    static func restore(_ archive: Archive, at locations: Locations = .current) throws -> [String] {
        let fm = FileManager.default
        var notes: [String] = []

        // Check every path before touching anything.
        for path in archive.supportFiles.keys {
            guard isSafe(path), supportPaths.contains(where: { $0.hasSuffix("/") ? path.hasPrefix($0) : path == $0 })
            else { throw BackupError.unsafePath(path) }
        }
        for name in archive.libraryFiles.keys where !libraryFiles.contains(name) {
            throw BackupError.unsafePath(name)
        }
        guard let prefs = try PropertyListSerialization.propertyList(from: archive.preferences, format: nil)
            as? [String: Any] else { throw BackupError.damaged }

        // Preferences: clear the backed-up kind, then set the backup's.
        let defaults = locations.defaults
        let current = defaults.persistentDomain(forName: locations.preferenceDomain) ?? [:]
        for key in current.keys where isBackedUpPreference(key) { defaults.removeObject(forKey: key) }
        for (key, value) in prefs where isBackedUpPreference(key) { defaults.set(value, forKey: key) }

        // Application Support: remove what a backup covers, then write.
        let support = locations.supportDirectory
        for path in supportPaths {
            let url = support.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        for (path, data) in archive.supportFiles {
            let url = support.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            if path.hasPrefix("libraries/") {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }

        // Library sidecars go back to the music folder the backup came from.
        if !archive.libraryFiles.isEmpty {
            if let path = archive.libraryRootPath, fm.fileExists(atPath: path) {
                let dir = URL(fileURLWithPath: path).appendingPathComponent(".flactastic", isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for (name, data) in archive.libraryFiles {
                    try data.write(to: dir.appendingPathComponent(name), options: .atomic)
                }
            } else {
                notes.append("The music folder \(archive.libraryRootPath ?? "from the backup") wasn't found, so its playlists and track IDs weren't restored. Choose the folder again after restarting.")
            }
        }

        for note in notes { log.notice("\(note, privacy: .public)") }
        return notes
    }

    /// A relative path with no "..", ".", or empty components.
    static func isSafe(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.isEmpty else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }

    // MARK: - Helpers

    /// Every regular file under `directory`, by path relative to it.
    private static func filesUnder(_ directory: URL) throws -> [(String, Data)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        let base = directory.standardizedFileURL.path + "/"
        var files: [(String, Data)] = []
        for case let url as URL in enumerator
        where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            files.append((String(path.dropFirst(base.count)), try Data(contentsOf: url)))
        }
        return files
    }

    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        let saltBytes = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes.map { CChar(bitPattern: $0) }, passwordBytes.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
            &key, key.count
        )
        guard status == kCCSuccess else { throw BackupError.damaged }
        return SymmetricKey(data: key)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
