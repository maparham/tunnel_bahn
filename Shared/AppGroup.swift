import Foundation

enum AppGroupStore {
    /// True when this process can access the shared App Group container (signing + entitlements OK).
    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID) != nil
    }

    /// Avoid `UserDefaults(suiteName:)` when the container is missing — that triggers a CoreFoundation
    /// warning (`Container: (null)`, `kCFPreferencesAnyUser`) and does not share data with extensions.
    static let defaults: UserDefaults = {
        guard isAvailable, let suite = UserDefaults(suiteName: AppConstants.appGroupID) else {
            return .standard
        }
        return suite
    }()

    static func ensureSharedDirectories() throws {
        guard let profilesDirectory = SharedPaths.profilesDirectory() else {
            throw NSError(
                domain: "TunnelBahn.AppGroup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to access App Group container."]
            )
        }

        try FileManager.default.createDirectory(
            at: profilesDirectory,
            withIntermediateDirectories: true
        )
    }
}
