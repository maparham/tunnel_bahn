import Foundation

enum AppGroupStore {
    static let defaults = UserDefaults(suiteName: AppConstants.appGroupID) ?? .standard

    static func ensureSharedDirectories() throws {
        guard let profilesDirectory = SharedPaths.profilesDirectory() else {
            throw NSError(
                domain: "AppSplitWG.AppGroup",
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
