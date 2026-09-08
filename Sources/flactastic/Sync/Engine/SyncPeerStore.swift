import Foundation

/// Remembers which devices this Mac has paired with, and how it syncs with
/// each of them.
///
/// Holds **no key material** — keys live in the Keychain via `PeerKeyStore`.
/// Keeping them apart means this file can be logged, backed up, or attached to
/// a support report without leaking anything that would let a device connect.
///
/// Stored in Application Support rather than in `<libraryRoot>/.flactastic/`,
/// following the same reasoning the iOS `SyncStore` records: this is about
/// *this machine's* relationships with other machines, not about the contents
/// of any one library, so it should not travel with a library folder or be
/// reset by opening a different one.
struct SyncPeerStore {

    private struct Record: Codable {
        var peer: PairedPeer
        var filter: SyncFilter
    }

    private let fileURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("flactastic", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("sync-peers.json")
    }

    // MARK: - Load / save

    private func load() -> [UUID: Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: records.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func save(_ records: [UUID: Record]) {
        let keyed = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        do {
            try JSONEncoder().encode(keyed).write(to: fileURL, options: .atomic)
        } catch {
            print("[SyncPeerStore] Failed to save: \(error)")
        }
    }

    // MARK: - Peers

    func peers() -> [PairedPeer] {
        load().values.map(\.peer)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Adds or updates a peer, preserving any filter already configured for it
    /// — re-pairing a device the user has already tuned should not silently
    /// reset those choices.
    func upsert(_ peer: PairedPeer) {
        var records = load()
        let existingFilter = records[peer.deviceID]?.filter ?? .unrestricted
        var updated = peer
        updated.lastSyncedAt = records[peer.deviceID]?.peer.lastSyncedAt
        records[peer.deviceID] = Record(peer: updated, filter: existingFilter)
        save(records)
    }

    func remove(deviceID: UUID) {
        var records = load()
        records.removeValue(forKey: deviceID)
        save(records)
    }

    func recordSync(deviceID: UUID, at date: Date) {
        var records = load()
        guard var record = records[deviceID] else { return }
        record.peer.lastSyncedAt = date
        records[deviceID] = record
        save(records)
    }

    // MARK: - Filters

    /// The filter for a peer, defaulting to the whole library.
    func filter(for deviceID: UUID) -> SyncFilter {
        load()[deviceID]?.filter ?? .unrestricted
    }

    func setFilter(_ filter: SyncFilter, for deviceID: UUID) {
        var records = load()
        guard var record = records[deviceID] else { return }
        record.filter = filter
        records[deviceID] = record
        save(records)
    }

    /// "Last synced 2 hours ago" / "Never synced" — the device row's subtitle.
    static func lastSyncedDescription(_ date: Date?) -> String {
        guard let date else { return "Never synced" }
        // RelativeDateTimeFormatter renders anything under a minute as
        // "in 0 seconds", which reads as broken right after a sync completes.
        guard Date.now.timeIntervalSince(date) >= 60 else { return "Synced just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last synced " + formatter.localizedString(for: date, relativeTo: .now)
    }
}
