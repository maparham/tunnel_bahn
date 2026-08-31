import Foundation

struct BackupOptions {
    var includeSettings: Bool
    var includeProfiles: Bool
    var includeAppRouting: Bool
    var includeDestinationRouting: Bool
}

enum ProfileConflictPolicy {
    case replaceByName
    case keepBoth
    case skip
}

struct ImportSummary {
    var profilesAdded: Int = 0
    var profilesReplaced: Int = 0
    var profilesSkipped: Int = 0
    var settingsRestored: Bool = false
    /// Per-profile import failures ("name: reason"). A bad entry must not abort the rest
    /// of the import, but it must not vanish silently either.
    var profileFailures: [String] = []

    var description: String {
        var parts: [String] = []
        let total = profilesAdded + profilesReplaced
        if total > 0 {
            var profileParts: [String] = []
            if profilesAdded > 0 { profileParts.append("\(profilesAdded) added") }
            if profilesReplaced > 0 { profileParts.append("\(profilesReplaced) replaced") }
            if profilesSkipped > 0 { profileParts.append("\(profilesSkipped) skipped") }
            parts.append("Profiles: \(profileParts.joined(separator: ", "))")
        } else if profilesSkipped > 0 {
            parts.append("Profiles: \(profilesSkipped) skipped (already exist)")
        }
        if settingsRestored { parts.append("General settings restored") }
        if !profileFailures.isEmpty {
            parts.append("\(profileFailures.count) profile(s) could not be imported: \(profileFailures.joined(separator: "; "))")
        }
        return parts.isEmpty ? "Nothing imported" : parts.joined(separator: ". ")
    }
}

enum BackupServiceError: LocalizedError {
    case unsupportedVersion(Int)
    case keychainReadFailed(profileName: String, underlying: Error)
    case keychainWriteFailed(profileName: String, underlying: Error)
    case missingKeyMaterial(profileName: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(v):
            return "This backup was created with a newer version of TunnelBahn (format version \(v)) and cannot be imported."
        case let .keychainReadFailed(name, err):
            return "Could not read private key for profile \"\(name)\": \(err.localizedDescription)"
        case let .keychainWriteFailed(name, err):
            return "Could not save private key for profile \"\(name)\": \(err.localizedDescription)"
        case let .missingKeyMaterial(name):
            return "The backup entry for profile \"\(name)\" is missing its private key."
        }
    }
}

@MainActor
final class BackupService {
    private let keychainService = KeychainService.shared

    // MARK: - Encoder / Decoder

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Export

    func buildBackup(
        options: BackupOptions,
        profileStore: ProfileStore,
        profileRoutingStore: ProfileRoutingStore,
        appSettings: AppSettings
    ) throws -> AppBackup {
        var backup = AppBackup(
            version: AppBackup.currentVersion,
            createdAt: .now,
            appSettings: nil,
            profiles: nil
        )

        if options.includeSettings {
            backup.appSettings = AppSettingsSnapshot(
                autoReconnect: appSettings.autoReconnect,
                launchAtLogin: appSettings.launchAtLogin,
                showTrafficRates: appSettings.showTrafficRates,
                diagnosticsLevel: appSettings.diagnosticsLevel,
                runTunnelConnectivityProbe: appSettings.runTunnelConnectivityProbe
            )
        }

        if options.includeProfiles {
            backup.profiles = try profileStore.profiles.map { profile in
                let (privateKey, psks, sshKey) = try resolveProfileSecrets(profile: profile)

                var snapshot: ProfileRoutingSnapshot? = nil
                if options.includeAppRouting || options.includeDestinationRouting {
                    var raw = profileRoutingStore.snapshot(for: profile.id)
                    if !options.includeAppRouting {
                        raw.appRules = []
                    }
                    if !options.includeDestinationRouting {
                        raw.include = DestinationModeRuleSet()
                        raw.exclude = DestinationModeRuleSet()
                        raw.enforceDestinationFiltering = false
                        raw.includeToggles = DestinationSectionToggles()
                        raw.excludeToggles = DestinationSectionToggles()
                    }
                    snapshot = raw
                }

                // Strip machine-scoped bookmarks from app rules
                if var s = snapshot {
                    s.appRules = sanitizeAppRules(s.appRules)
                    snapshot = s
                }

                return ProfileBackupEntry(
                    profile: profile,
                    privateKeyValue: privateKey,
                    peerPresharedKeys: psks,
                    sshPrivateKeyValue: sshKey,
                    routingSnapshot: snapshot
                )
            }
        }

        return backup
    }

    func encode(_ backup: AppBackup) throws -> Data {
        try makeEncoder().encode(backup)
    }

    // MARK: - Import

    func decode(from data: Data) throws -> AppBackup {
        let backup = try makeDecoder().decode(AppBackup.self, from: data)
        guard backup.version <= AppBackup.currentVersion else {
            throw BackupServiceError.unsupportedVersion(backup.version)
        }
        return backup
    }

    func applyBackup(
        _ backup: AppBackup,
        options: BackupOptions,
        conflictPolicy: ProfileConflictPolicy,
        profileStore: ProfileStore,
        profileRoutingStore: ProfileRoutingStore,
        appSettings: AppSettings
    ) throws -> ImportSummary {
        var summary = ImportSummary()

        if options.includeSettings, let snap = backup.appSettings {
            appSettings.autoReconnect = snap.autoReconnect
            appSettings.showTrafficRates = snap.showTrafficRates
            appSettings.diagnosticsLevel = snap.diagnosticsLevel
            appSettings.runTunnelConnectivityProbe = snap.runTunnelConnectivityProbe
            if appSettings.launchAtLogin != snap.launchAtLogin {
                appSettings.launchAtLogin = snap.launchAtLogin
                try? LaunchAtLoginService.setEnabled(snap.launchAtLogin)
            }
            summary.settingsRestored = true
        }

        if options.includeProfiles, let entries = backup.profiles {
            for entry in entries {
                let importedProfile: WireGuardProfile
                do {
                    importedProfile = try saveProfileSecrets(entry: entry)
                } catch {
                    // Record and move on — aborting here would leave an unannounced partial
                    // import (earlier entries and settings are already committed).
                    summary.profileFailures.append("\(entry.profile.name): \(error.localizedDescription)")
                    continue
                }

                let existing = profileStore.profiles.first { $0.name == importedProfile.name }

                switch conflictPolicy {
                case .replaceByName:
                    if let existing {
                        // Adopt the existing UUID so the routing snapshot key stays consistent
                        var adopted = importedProfile
                        adopted.id = existing.id
                        profileStore.replaceExisting(id: existing.id, with: adopted)
                        if let snapshot = buildImportSnapshot(entry: entry, options: options) {
                            profileRoutingStore.save(snapshot: snapshot, for: existing.id)
                        }
                        summary.profilesReplaced += 1
                    } else {
                        profileStore.add(importedProfile)
                        if let snapshot = buildImportSnapshot(entry: entry, options: options) {
                            profileRoutingStore.save(snapshot: snapshot, for: importedProfile.id)
                        }
                        summary.profilesAdded += 1
                    }

                case .keepBoth:
                    profileStore.add(importedProfile)
                    if let snapshot = buildImportSnapshot(entry: entry, options: options) {
                        profileRoutingStore.save(snapshot: snapshot, for: importedProfile.id)
                    }
                    summary.profilesAdded += 1

                case .skip:
                    if existing != nil {
                        // Clean up the keychain entries we just minted since we're not using them
                        cleanupProfileSecrets(importedProfile)
                        summary.profilesSkipped += 1
                    } else {
                        profileStore.add(importedProfile)
                        if let snapshot = buildImportSnapshot(entry: entry, options: options) {
                            profileRoutingStore.save(snapshot: snapshot, for: importedProfile.id)
                        }
                        summary.profilesAdded += 1
                    }
                }
            }
        }

        return summary
    }

    // MARK: - Private Helpers

    private func resolveProfileSecrets(profile: WireGuardProfile) throws -> (privateKey: String?, psks: [String: String], sshKey: String?) {
        // SSH-transport profiles authenticate with the PEM key under ssh.privateKeyRef, but a
        // profile converted from WireGuard still carries its WG interface key and peer PSKs
        // (the editor preserves interface/peers across conversion so the user can switch
        // back). Export all of it — dropping the WG material would make the restored profile
        // unable to ever return to WireGuard transport.
        if profile.transport == .ssh {
            guard let ref = profile.ssh?.privateKeyRef, !ref.isEmpty else {
                throw BackupServiceError.missingKeyMaterial(profileName: profile.name)
            }
            let sshKey: String
            do {
                sshKey = try keychainService.read(account: ref)
            } catch {
                throw BackupServiceError.keychainReadFailed(profileName: profile.name, underlying: error)
            }
            var wgKey: String? = nil
            if !profile.interface.privateKeyRef.isEmpty {
                do {
                    wgKey = try keychainService.read(account: profile.interface.privateKeyRef)
                } catch {
                    throw BackupServiceError.keychainReadFailed(profileName: profile.name, underlying: error)
                }
            }
            return (wgKey, try readPeerPresharedKeys(of: profile), sshKey)
        }

        let privateKey: String
        do {
            privateKey = try keychainService.read(account: profile.interface.privateKeyRef)
        } catch {
            throw BackupServiceError.keychainReadFailed(profileName: profile.name, underlying: error)
        }
        return (privateKey, try readPeerPresharedKeys(of: profile), nil)
    }

    private func readPeerPresharedKeys(of profile: WireGuardProfile) throws -> [String: String] {
        var psks: [String: String] = [:]
        for peer in profile.peers {
            guard let ref = peer.presharedKeyRef, !ref.isEmpty else { continue }
            do {
                psks[peer.id.uuidString] = try keychainService.read(account: ref)
            } catch {
                throw BackupServiceError.keychainReadFailed(profileName: profile.name, underlying: error)
            }
        }
        return psks
    }

    /// Returns the imported profile with EVERY keychain ref freshly minted (or cleared).
    /// The refs inside `entry.profile` are the source machine's account IDs; on a
    /// same-machine restore they alias the live profile's keys, so carrying any of them
    /// over would let `cleanupProfileSecrets` (skip path) destroy live key material.
    private func saveProfileSecrets(entry: ProfileBackupEntry) throws -> WireGuardProfile {
        var mintedAccounts: [String] = []
        var committed = false
        defer {
            if !committed {
                for account in mintedAccounts {
                    try? keychainService.delete(account: account)
                }
            }
        }

        func mint(_ value: String, prefix: String) throws -> String {
            let ref = "\(prefix)\(UUID().uuidString)"
            do {
                try keychainService.save(value, account: ref)
            } catch {
                throw BackupServiceError.keychainWriteFailed(profileName: entry.profile.name, underlying: error)
            }
            mintedAccounts.append(ref)
            return ref
        }

        var importedProfile = entry.profile

        if entry.profile.transport == .ssh {
            guard var ssh = entry.profile.ssh, let pem = entry.sshPrivateKeyValue else {
                throw BackupServiceError.missingKeyMaterial(profileName: entry.profile.name)
            }
            ssh.privateKeyRef = try mint(pem, prefix: "ssh-key-")
            importedProfile.ssh = ssh
            // WG material of a profile converted from WireGuard: restore it when the backup
            // carries it, otherwise clear the stale source-machine refs.
            if let privateKeyValue = entry.privateKeyValue {
                importedProfile.interface.privateKeyRef = try mint(privateKeyValue, prefix: "wg.private.")
            } else {
                importedProfile.interface.privateKeyRef = ""
            }
        } else {
            guard let privateKeyValue = entry.privateKeyValue else {
                throw BackupServiceError.missingKeyMaterial(profileName: entry.profile.name)
            }
            importedProfile.interface.privateKeyRef = try mint(privateKeyValue, prefix: "wg.private.")
        }

        var updatedPeers: [WireGuardPeer] = []
        for peer in entry.profile.peers {
            var updatedPeer = peer
            if let rawPsk = entry.peerPresharedKeys[peer.id.uuidString] {
                updatedPeer.presharedKeyRef = try mint(rawPsk, prefix: "wg.psk.")
            } else {
                updatedPeer.presharedKeyRef = nil
            }
            updatedPeers.append(updatedPeer)
        }
        importedProfile.peers = updatedPeers

        committed = true
        return importedProfile
    }

    private func cleanupProfileSecrets(_ profile: WireGuardProfile) {
        if let sshRef = profile.ssh?.privateKeyRef, !sshRef.isEmpty {
            try? keychainService.delete(account: sshRef)
        }
        if !profile.interface.privateKeyRef.isEmpty {
            try? keychainService.delete(account: profile.interface.privateKeyRef)
        }
        for peer in profile.peers {
            if let ref = peer.presharedKeyRef {
                try? keychainService.delete(account: ref)
            }
        }
    }

    private func sanitizeAppRules(_ rules: [AppRule]) -> [AppRule] {
        rules.map { rule in
            var sanitized = rule
            sanitized.bookmarkData = nil
            return sanitized
        }
    }

    private func buildImportSnapshot(entry: ProfileBackupEntry, options: BackupOptions) -> ProfileRoutingSnapshot? {
        guard options.includeAppRouting || options.includeDestinationRouting,
              var snapshot = entry.routingSnapshot else { return nil }
        if !options.includeAppRouting {
            snapshot.appRules = []
        }
        if !options.includeDestinationRouting {
            snapshot.include = DestinationModeRuleSet()
            snapshot.exclude = DestinationModeRuleSet()
            snapshot.enforceDestinationFiltering = false
            snapshot.includeToggles = DestinationSectionToggles()
            snapshot.excludeToggles = DestinationSectionToggles()
        }
        snapshot.appRules = sanitizeAppRules(snapshot.appRules)
        return snapshot
    }
}
