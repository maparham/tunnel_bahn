import Foundation

@MainActor
final class ProfileRoutingStore: ObservableObject {
    private let defaultsKey = "profileRoutingSnapshots"
    private var store: [UUID: ProfileRoutingSnapshot] = [:]

    init() {
        load()
    }

    func snapshot(for profileID: UUID) -> ProfileRoutingSnapshot {
        store[profileID] ?? .default
    }

    func save(snapshot: ProfileRoutingSnapshot, for profileID: UUID) {
        store[profileID] = snapshot
        persist()
    }

    /// Applies `transform` to every stored snapshot; `transform` returns true when it changed
    /// the snapshot. Persists once if anything changed.
    func updateAll(_ transform: (inout ProfileRoutingSnapshot) -> Bool) {
        var changed = false
        for (id, snapshot) in store {
            var next = snapshot
            if transform(&next) {
                store[id] = next
                changed = true
            }
        }
        if changed { persist() }
    }

    /// Country codes of country-sourced bulk lists across all stored snapshots.
    var countryListCodes: Set<String> {
        var codes = Set<String>()
        for snapshot in store.values {
            for g in snapshot.include.bulkGroups + snapshot.exclude.bulkGroups {
                if let code = g.countryCode { codes.insert(code) }
            }
        }
        return codes
    }

    func delete(for profileID: UUID) {
        store.removeValue(forKey: profileID)
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        let stringKeyed = Dictionary(uniqueKeysWithValues: store.map { (key, value) in
            (key.uuidString, value)
        })
        if let data = try? encoder.encode(stringKeyed) {
            AppGroupStore.defaults.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = AppGroupStore.defaults.data(forKey: defaultsKey) else { return }
        let decoder = JSONDecoder()
        guard let stringKeyed = try? decoder.decode([String: ProfileRoutingSnapshot].self, from: data) else { return }
        store = Dictionary(uniqueKeysWithValues: stringKeyed.compactMap { (key, value) in
            guard let uuid = UUID(uuidString: key) else { return nil }
            return (uuid, value)
        })
    }
}
