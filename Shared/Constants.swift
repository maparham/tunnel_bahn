import Foundation

enum AppConstants {
    /// Host app bundle identifier (extensions use `\(primaryBundleID).<suffix>`).
    static let primaryBundleID = "com.tunnelbahn.mac"
    /// Must match `com.apple.security.application-groups` on the app and all extensions.
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
