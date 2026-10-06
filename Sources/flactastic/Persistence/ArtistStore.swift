import Foundation
import Observation

/// User-supplied display overrides for an artist. Display-only — never
/// rewritten back into audio file tags. Keyed by `ArtistResolver.key(for:)`.
struct ArtistOverride: Codable, Sendable, Hashable {
    var canonicalKey: String
    var displayName: String?
    var bannerImage: Data?
    var profileImage: Data?

    init(
        canonicalKey: String,
        displayName: String? = nil,
        bannerImage: Data? = nil,
        profileImage: Data? = nil
    ) {
        self.canonicalKey = canonicalKey
        self.displayName = displayName
        self.bannerImage = bannerImage
        self.profileImage = profileImage
    }

    var isEmpty: Bool {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty && bannerImage == nil && profileImage == nil
    }
}

@Observable
@MainActor
final class ArtistStore {
    private(set) var overrides: [String: ArtistOverride] = [:] {
        didSet { revision &+= 1 }
    }
    /// Bumps on every change to `overrides`: a cheap value for views to key
    /// cached work on, instead of comparing the image-carrying dictionary.
    private(set) var revision = 0

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("flactastic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("artists.json")
    }()

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let list = try JSONDecoder().decode([ArtistOverride].self, from: data)
            overrides = Dictionary(uniqueKeysWithValues: list.map { ($0.canonicalKey, $0) })
        } catch {
            print("[ArtistStore] Failed to load artist overrides: \(error)")
        }
    }

    /// Async variant of `load()` for app bootstrap: file read + JSON decode
    /// run off the main actor so launch doesn't block first paint on disk I/O.
    func loadAsync() async {
        let url = fileURL
        let loaded: [ArtistOverride]? = await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode([ArtistOverride].self, from: data)
            } catch {
                print("[ArtistStore] Failed to load artist overrides: \(error)")
                return nil
            }
        }.value
        guard let loaded else { return }
        overrides = Dictionary(uniqueKeysWithValues: loaded.map { ($0.canonicalKey, $0) })
    }

    func save() {
        do {
            let list = Array(overrides.values).sorted { $0.canonicalKey < $1.canonicalKey }
            let data = try JSONEncoder().encode(list)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[ArtistStore] Failed to save artist overrides: \(error)")
        }
    }

    func override(forKey key: String) -> ArtistOverride? {
        overrides[key]
    }

    func upsert(_ override: ArtistOverride) {
        if override.isEmpty {
            overrides.removeValue(forKey: override.canonicalKey)
        } else {
            overrides[override.canonicalKey] = override
        }
        save()
    }

    func remove(key: String) {
        overrides.removeValue(forKey: key)
        save()
    }
}
