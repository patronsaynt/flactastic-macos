import Foundation
import Testing
@testable import flactastic

// Tests for PathSanitizer — the boundary between a peer's untrusted relative
// path and our filesystem. Because FLACtastic is unsandboxed on macOS, a
// traversal that gets past this type can write anywhere the user can, so the
// attack table below is deliberately exhaustive rather than representative.

// MARK: - Traversal rejection

@Test("Parent-directory traversal is rejected in every position")
func rejectsParentTraversal() {
    let attacks = [
        "../secrets.flac",
        "Music/../../../.zshrc",
        "Artist/Album/../../../../etc/passwd",
        "..",
        "../",
        "a/../b.flac",
    ]
    for attack in attacks {
        #expect(throws: PathSanitizer.Rejection.self) {
            try PathSanitizer.sanitizeRelativePath(attack)
        }
    }
}

@Test("Dot-only components cannot survive sanitising into a traversal")
func rejectsDotOnlyComponents() {
    // The classic bypass: a sanitiser that *strips* rather than rejects turns
    // "....//" into "../". Components made only of dots are refused outright.
    for attack in ["....//x.flac", ".../x.flac", "a/..../b.flac", "./x.flac"] {
        #expect(throws: PathSanitizer.Rejection.self) {
            try PathSanitizer.sanitizeRelativePath(attack)
        }
    }
}

@Test("Absolute and home-relative paths are rejected")
func rejectsAbsolutePaths() {
    let attacks = [
        "/etc/passwd",
        "/Users/someone/Library/x.flac",
        "~/Library/LaunchAgents/evil.plist",
        "~root/x.flac",
        "\\\\server\\share\\x.flac",   // UNC
        "C:\\Windows\\System32\\x.flac",
        "a/~/b.flac",
    ]
    for attack in attacks {
        #expect(throws: PathSanitizer.Rejection.self) {
            try PathSanitizer.sanitizeRelativePath(attack)
        }
    }
}

@Test("Null bytes are rejected")
func rejectsNullBytes() {
    #expect(throws: PathSanitizer.Rejection.self) {
        try PathSanitizer.sanitizeRelativePath("Artist/song.flac\u{0}.txt")
    }
}

@Test("Empty and malformed paths are rejected")
func rejectsMalformed() {
    for attack in ["", "//x.flac", "a//b.flac"] {
        #expect(throws: PathSanitizer.Rejection.self) {
            try PathSanitizer.sanitizeRelativePath(attack)
        }
    }
}

@Test("Unicode-decomposed traversal is caught after normalisation")
func rejectsDecomposedTraversal() {
    // ".." written with a combining sequence that folds to the same string.
    let decomposed = "Arti\u{0301}st/..".precomposedStringWithCanonicalMapping
    #expect(throws: PathSanitizer.Rejection.self) {
        try PathSanitizer.sanitizeRelativePath(decomposed)
    }
}

// MARK: - Limits

@Test("Over-long components are rejected")
func rejectsLongComponents() {
    let long = String(repeating: "a", count: PathSanitizer.maxComponentBytes + 1)
    #expect(throws: PathSanitizer.Rejection.self) {
        try PathSanitizer.sanitizeRelativePath("Artist/\(long).flac")
    }
}

@Test("Over-deep paths are rejected")
func rejectsDeepPaths() {
    let deep = Array(repeating: "d", count: PathSanitizer.maxDepth + 1).joined(separator: "/")
    #expect(throws: PathSanitizer.Rejection.self) {
        try PathSanitizer.sanitizeRelativePath("\(deep)/x.flac")
    }
}

@Test("Over-long whole paths are rejected before component analysis")
func rejectsLongTotalPath() {
    let huge = String(repeating: "a/", count: PathSanitizer.maxTotalBytes) + "x.flac"
    #expect(throws: PathSanitizer.Rejection.self) {
        try PathSanitizer.sanitizeRelativePath(huge)
    }
}

// MARK: - Acceptance

@Test("Ordinary library paths pass through unchanged")
func acceptsOrdinaryPaths() throws {
    #expect(try PathSanitizer.sanitizeRelativePath("Boards of Canada/Geogaddi/01 Ready Lets Go.flac")
            == "Boards of Canada/Geogaddi/01 Ready Lets Go.flac")
    #expect(try PathSanitizer.sanitizeRelativePath("song.flac") == "song.flac")
}

@Test("A trailing separator is tolerated")
func toleratesTrailingSeparator() throws {
    #expect(try PathSanitizer.sanitizeRelativePath("Artist/Album/") == "Artist/Album")
}

@Test("Illegal filename characters are sanitised, not rejected")
func sanitisesIllegalCharacters() throws {
    // A colon is a path separator in classic Mac APIs and illegal on Windows;
    // ImportCopy.sanitize strips it, exactly as it does for local imports.
    let result = try PathSanitizer.sanitizeRelativePath("AC:DC/Album?/song*.flac")
    #expect(!result.contains(":"))
    #expect(!result.contains("?"))
    #expect(!result.contains("*"))
    #expect(result.hasSuffix(".flac"))
}

@Test("Hidden-file names are defused")
func defusesHiddenFiles() throws {
    // A peer must not be able to drop a dotfile into the library root, where
    // it would sit alongside .flactastic and be invisible in Finder.
    let result = try PathSanitizer.sanitizeRelativePath(".hidden.flac")
    #expect(result.hasPrefix("_"))
}

// MARK: - Audio-extension gate

@Test("Non-audio extensions are rejected for incoming tracks")
func rejectsNonAudioExtensions() {
    // Unsandboxed on macOS, so a dylib or plist landing in a scanned folder
    // would be a code-execution primitive rather than a mere annoyance.
    let attacks = [
        "Artist/evil.dylib",
        "evil.plist",
        "Artist/Album/run.sh",
        "noextension",
        "song.flac.txt",
    ]
    for attack in attacks {
        #expect(throws: PathSanitizer.Rejection.self) {
            try PathSanitizer.sanitizeAudioRelativePath(attack)
        }
    }
}

@Test("Every format the app understands is accepted")
func acceptsKnownAudioExtensions() throws {
    for ext in ["flac", "mp3", "wav", "wave", "aif", "aiff", "m4a", "aac", "FLAC", "Mp3"] {
        let path = try PathSanitizer.sanitizeAudioRelativePath("Artist/song.\(ext)")
        #expect(path.hasSuffix(ext))
    }
}

// MARK: - Containment

@Test("isContained compares path components, not string prefixes")
func containmentIsComponentwise() {
    let root = URL(fileURLWithPath: "/Users/x/Library")
    #expect(PathSanitizer.isContained(URL(fileURLWithPath: "/Users/x/Library/a.flac"), in: root))
    #expect(PathSanitizer.isContained(root, in: root))
    // The prefix-check bug: "Library Backup" is NOT inside "Library".
    #expect(!PathSanitizer.isContained(URL(fileURLWithPath: "/Users/x/Library Backup/a.flac"), in: root))
    #expect(!PathSanitizer.isContained(URL(fileURLWithPath: "/Users/x"), in: root))
}

@Test("A symlinked ancestor pointing outside the root is caught")
func rejectsSymlinkedAncestor() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("flactastic-sync-\(UUID().uuidString)")
    let root = base.appendingPathComponent("library")
    let outside = base.appendingPathComponent("outside")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    // "Music" looks like an ordinary component and survives sanitising, but on
    // this filesystem it escapes the library entirely.
    try fm.createSymbolicLink(at: root.appendingPathComponent("Music"), withDestinationURL: outside)

    let safe = try PathSanitizer.sanitizeAudioRelativePath("Music/song.flac")
    #expect(throws: PathSanitizer.Rejection.self) {
        try PathSanitizer.resolvedDestination(forSanitizedPath: safe, under: root)
    }
}

@Test("A clean path resolves to a URL under the root")
func resolvesCleanPath() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("flactastic-sync-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let destination = try PathSanitizer.destinationForIncomingTrack(
        remoteRelativePath: "Artist/Album/01 Song.flac",
        under: root
    )
    #expect(PathSanitizer.isContained(destination, in: root.resolvingSymlinksInPath()))
    #expect(destination.lastPathComponent == "01 Song.flac")
}
