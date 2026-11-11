import Foundation
import Observation

/// Persists organizer profiles and the user's currently-selected profile. Stores
/// JSON in UserDefaults so the existing Settings pattern is matched without
/// pulling in a database. Always guarantees at least one profile exists — on
/// first launch it seeds the default preset.
@Observable
@MainActor
final class OrganizerProfilesStore {
    private static let profilesKey = "flactastic.organizer.profiles"
    private static let selectedKey = "flactastic.organizer.selectedProfileID"

    var profiles: [OrganizerProfile] {
        didSet { persistProfiles() }
    }

    var selectedID: UUID {
        didSet {
            if adopting { return }
            if let remote { remote(profiles, selectedID); return }
            UserDefaults.standard.set(selectedID.uuidString, forKey: Self.selectedKey)
        }
    }

    /// Set while a server profile is the library: changes go to
    /// `PUT /v2/organizer` (§12) instead of this Mac's defaults.
    @ObservationIgnored var remote: (([OrganizerProfile], UUID) -> Void)?
    @ObservationIgnored private var adopting = false

    /// Shows the server's profiles without sending them back.
    func adopt(_ list: [OrganizerProfile], selected: UUID?) {
        adopting = true
        defer { adopting = false }
        profiles = list.isEmpty ? [OrganizerProfile.default] : list
        selectedID = selected.flatMap { id in profiles.contains { $0.id == id } ? id : nil } ?? profiles[0].id
    }

    /// This Mac's own profiles, for the one-time offer to move them to a server.
    static func localProfiles() -> [OrganizerProfile] {
        UserDefaults.standard.data(forKey: profilesKey)
            .flatMap { try? JSONDecoder().decode([OrganizerProfile].self, from: $0) } ?? []
    }

    var selected: OrganizerProfile {
        get { profiles.first { $0.id == selectedID } ?? profiles[0] }
        set {
            guard let i = profiles.firstIndex(where: { $0.id == newValue.id }) else { return }
            profiles[i] = newValue
        }
    }

    init() {
        let decoded: [OrganizerProfile]
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let parsed = try? JSONDecoder().decode([OrganizerProfile].self, from: data),
           !parsed.isEmpty {
            decoded = parsed
        } else {
            decoded = [OrganizerProfile.default]
        }
        self.profiles = decoded

        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey),
           let uuid = UUID(uuidString: raw),
           decoded.contains(where: { $0.id == uuid }) {
            self.selectedID = uuid
        } else {
            self.selectedID = decoded[0].id
        }
    }

    func add(_ profile: OrganizerProfile) {
        profiles.append(profile)
        selectedID = profile.id
    }

    func duplicateSelected() {
        let source = selected
        let copy = OrganizerProfile(
            id: UUID(),
            name: "\(source.name) Copy",
            levels: source.levels.map {
                HierarchyLevel(id: UUID(), groupBy: $0.groupBy, name: $0.name, nameTemplate: $0.nameTemplate)
            },
            fileTemplate: source.fileTemplate,
            usePrimaryArtistOnly: source.usePrimaryArtistOnly,
            deleteEmptyOriginals: source.deleteEmptyOriginals
        )
        add(copy)
    }

    func removeSelected() {
        guard profiles.count > 1 else { return }
        guard let idx = profiles.firstIndex(where: { $0.id == selectedID }) else { return }
        profiles.remove(at: idx)
        selectedID = profiles[max(0, idx - 1)].id
    }

    private func persistProfiles() {
        if adopting { return }
        if let remote { remote(profiles, selectedID); return }
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: Self.profilesKey)
    }
}
