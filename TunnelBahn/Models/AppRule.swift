import AppKit
import Foundation

struct AppRule: Codable, Identifiable, Hashable {
    var id: UUID
    var displayName: String
    var bundleIdentifier: String
    var appPath: String
    var action: RoutingAction
    var bookmarkData: Data?

    init(
        id: UUID = UUID(),
        displayName: String,
        bundleIdentifier: String,
        appPath: String,
        action: RoutingAction,
        bookmarkData: Data? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.action = action
        self.bookmarkData = bookmarkData
    }

    var useVPN: Bool {
        get { action == .routeVPN }
        set { action = newValue ? .routeVPN : .bypass }
    }
}

struct DiscoveredApp: Identifiable, Hashable {
    var id: String { appPath }

    let displayName: String
    let bundleIdentifier: String
    let appPath: String
    let icon: NSImage
    let bookmarkData: Data?

    init(displayName: String, bundleIdentifier: String, appPath: String, icon: NSImage, bookmarkData: Data? = nil) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.icon = icon
        self.bookmarkData = bookmarkData
    }

    func hash(into hasher: inout Hasher) { hasher.combine(appPath) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.appPath == rhs.appPath }
}
