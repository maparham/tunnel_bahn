import Foundation

enum AppConstants {
    static let appGroupID = "92G3VZAPVG.group.com.appsplit.wg"
    static let keychainService = "com.appsplit.wg"
    static let keychainAccessGroup = "92G3VZAPVG.com.appsplit.wg"
    static let packetTunnelProviderBundleIdentifier = "com.appsplit.wg.networkextension"
    static let vpnManagerDescription = "AppSplit WG Tunnel"

    /// When `false`, every connect uses full tunnel (`NETunnelProviderManager` + destination-IP, no `NEAppRule`).
    static let isPerAppSplitTunnelEnabled = true

    /// Extra per-app VPN include paths. Keep empty in production:
    /// per-app routing must be driven only by user-selected apps.
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
