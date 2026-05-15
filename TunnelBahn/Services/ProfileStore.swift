import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [WireGuardProfile] = []
    @Published private(set) var selectedProfileID: UUID?

    private enum Keys {
        static let profiles = "profiles"
        static let selectedProfileID = "selectedProfileID"
    }
    
    private let keychainService = KeychainService.shared
    var onProfileDeleted: ((UUID) -> Void)?

    init() {
        load()
    }

    /// Adds a profile or replaces one with the **same id** (upsert). Names may collide with other profiles.
    func add(_ profile: WireGuardProfile) {
        var new = profile
        new.updatedAt = .now
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            cleanupKeychainSecrets(for: profiles[index])
            profiles.remove(at: index)
        }
        profiles.append(new)
        selectedProfileID = new.id
        save()
    }

    /// Replaces the profile at `id` (keychain cleanup + new row). Use when importing under an existing display name.
    func replaceExisting(id: UUID, with profile: WireGuardProfile) {
        if let existing = profiles.first(where: { $0.id == id }) {
            cleanupKeychainSecrets(for: existing)
            profiles.removeAll { $0.id == id }
        }
        var new = profile
        new.updatedAt = .now
        profiles.append(new)
        selectedProfileID = new.id
        save()
    }

    func delete(id: UUID) {
        // Clean up keychain entries before removing profile
        if let profile = profiles.first(where: { $0.id == id }) {
            cleanupKeychainSecrets(for: profile)
        }
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
        }
        save()
        onProfileDeleted?(id)
    }

    func update(_ profile: WireGuardProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var next = profile
        next.updatedAt = .now
        profiles[index] = next
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func select(id: UUID?) {
        guard id != selectedProfileID else { return }
        selectedProfileID = id
        save()
    }

    var selectedProfile: WireGuardProfile? {
        profiles.first(where: { $0.id == selectedProfileID })
    }

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(profiles) {
            AppGroupStore.defaults.set(data, forKey: Keys.profiles)
        }
        AppGroupStore.defaults.set(selectedProfileID?.uuidString, forKey: Keys.selectedProfileID)
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = AppGroupStore.defaults.data(forKey: Keys.profiles),
           let decoded = try? decoder.decode([WireGuardProfile].self, from: data)
        {
            profiles = decoded
        }
        if let raw = AppGroupStore.defaults.string(forKey: Keys.selectedProfileID),
           let uuid = UUID(uuidString: raw)
        {
            selectedProfileID = uuid
        } else {
            selectedProfileID = profiles.first?.id
        }
    }
    
    private func cleanupKeychainSecrets(for profile: WireGuardProfile) {
        // Delete private key
        try? keychainService.delete(account: profile.interface.privateKeyRef)
        
        // Delete preshared keys from all peers
        for peer in profile.peers {
            if let presharedKeyRef = peer.presharedKeyRef {
                try? keychainService.delete(account: presharedKeyRef)
            }
        }
    }
}
