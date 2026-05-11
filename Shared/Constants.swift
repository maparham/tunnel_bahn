import Foundation

enum AppConstants {
    static let appGroupID = "92G3VZAPVG.group.com.tunnelbahn.mac"
    static let keychainService = "com.tunnelbahn.mac"
    static let keychainAccessGroup = "92G3VZAPVG.com.tunnelbahn.mac"
    static let packetTunnelProviderBundleIdentifier = "com.tunnelbahn.mac.networkextension"
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
}
