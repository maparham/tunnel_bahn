import Foundation

enum AppConstants {
    /// Host app bundle identifier (extensions use `\(primaryBundleID).<suffix>`).
    static let primaryBundleID = "com.tunnelbahn.mac"
    /// Must match `com.apple.security.application-groups` on the app and all extensions.
    ///
    /// WARNING — changing this value is destructive:
    ///   • macOS creates a brand-new empty container; all UserDefaults data (profiles,
    ///     settings, routing snapshots, signing identifiers) in the old container becomes
    ///     invisible to the new build.
    ///   • Profiles that were re-imported into the new container get fresh `privateKeyRef`
    ///     UUIDs. If the import flow doesn't run — or the user copies profile metadata
    ///     without going through import — those UUIDs have no corresponding keychain items
    ///     and every tunnel-start fails with keychain error -25300 (errSecItemNotFound).
    ///   • The keychain access group (team-ID-prefixed, set in Info.plist as
    ///     `$(AppIdentifierPrefix)\(primaryBundleID)`) is SEPARATE from this value and is
    ///     stable across app-group renames, so old keychain items stay readable as long as
    ///     the same team signs the app.
    ///
    /// If you must change this: update all three entitlements files, the App ID / app-group
    /// in the Apple Developer Portal, re-run `xcodegen generate`, and tell users to
    /// delete + re-import all WireGuard profiles.
    ///
    /// Migration history:
    ///   3c9b7b1  (AppSplitWG era)       92G3VZAPVG.group.com.appsplit.wg
    ///   6f32874  (TunnelBahn rename)     92G3VZAPVG.group.com.tunnelbahn.mac
    ///   8a39c7f  (App Store readiness)   group.com.tunnelbahn.mac  ← current
    static let appGroupID = "group.\(primaryBundleID)"
    static let keychainService = primaryBundleID
    /// Matches `keychain-access-groups`. Set in each target's Info.plist as
    /// `$(AppIdentifierPrefix)\(primaryBundleID)` (`SecTaskCopyTeamIdentifier` is unavailable in app extensions).
    static let keychainAccessGroup: String = {
        let plistKey = "TunnelBahnKeychainAccessGroup"
        guard let group = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String, !group.isEmpty else {
            fatalError("\(plistKey) missing or empty in Info.plist — ensure each target's Info.plist sets this to $(AppIdentifierPrefix)\(primaryBundleID)")
        }
        return group
    }()
    static let packetTunnelProviderBundleIdentifier = "\(primaryBundleID).networkextension"
    static let vpnManagerDescription = "TunnelBahn Tunnel"

    /// When `false`, every connect uses full tunnel (`NETunnelProviderManager` + destination-IP, no `NEAppRule`).
    static let isPerAppSplitTunnelEnabled = true

    /// Extra app-tunnel VPN include paths. Keep empty in production:
    /// app-tunnel routing must be driven only by user-selected apps.
    static let perAppAlwaysIncludeAppPaths: [String] = []
}

enum SharedPaths {
    static func appGroupContainer() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
    }

    static func profilesDirectory() -> URL? {
        appGroupContainer()?.appendingPathComponent("Profiles", isDirectory: true)
    }

    static func stateFileURL() -> URL? {
        appGroupContainer()?.appendingPathComponent("vpn-state.json")
    }

    static func perAppRoutedSigningIdentifiersFileURL() -> URL? {
        appGroupContainer()?.appendingPathComponent("per-app-routed-signing-identifiers.json")
    }

    /// Host-written JSON read by `TransparentProxyProvider` (`DestinationRoutingFilePayload`).
    static func destinationRangesFileURL() -> URL? {
        appGroupContainer()?.appendingPathComponent("destination-routing.json")
    }

    /// Extension-written JSON listing signing IDs of *other* transparent proxy extensions
    /// observed in `handleNewFlow`. The host app reads this to surface a warning when a
    /// competing proxy is shadowing app-tunnel routing.
    static func observedForeignProxySigningIDsFileURL() -> URL? {
        appGroupContainer()?.appendingPathComponent("observed-foreign-proxy-signing-ids.json")
    }
}
