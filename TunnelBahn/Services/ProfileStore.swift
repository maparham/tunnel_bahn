import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [WireGuardProfile] = []
    @Published private(set) var selectedProfileID: UUID?
    /// Profiles whose private key cannot be read from the keychain.
    /// Populated by `runKeychainIntegrityCheck()`. Empty until that method is called.
    @Published private(set) var profilesWithMissingKeys: [WireGuardProfile] = []

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
        runKeychainIntegrityCheck()
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
        runKeychainIntegrityCheck()
    }

    func delete(id: UUID) {
        // Clean up keychain entries before removing profile
        if let profile = profiles.first(where: { $0.id == id }) {
            cleanupKeychainSecrets(for: profile)
        }
        profiles.removeAll { $0.id == id }
        profilesWithMissingKeys.removeAll { $0.id == id }
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

    /// Checks whether each profile's private key is readable from the keychain and
    /// populates `profilesWithMissingKeys` with any that are broken.
    ///
    /// This can happen after an app-group ID change (new UserDefaults container) if
    /// profiles were added to the new container without the corresponding keychain writes
    /// — the profile metadata exists but the key material was never stored. Call once
    /// at app startup after `load()`.
    func runKeychainIntegrityCheck() {
        profilesWithMissingKeys = profiles.filter { profile in
            (try? keychainService.read(account: profile.interface.privateKeyRef)) == nil
        }
    }

    /// Returns true when the profile's private key can be read from the keychain right now.
    /// Use this as a connect-time guard to give an actionable error before the extension
    /// tries (and fails with -25300) to read the key itself.
    func hasValidPrivateKey(for profile: WireGuardProfile) -> Bool {
        (try? keychainService.read(account: profile.interface.privateKeyRef)) != nil
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
