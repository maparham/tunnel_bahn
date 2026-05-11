import AppKit
import Foundation

struct AppRule: Codable, Identifiable, Hashable {
    var id: UUID
    var displayName: String
    var bundleIdentifier: String
    var appPath: String
    var action: RoutingAction

    init(
        id: UUID = UUID(),
        displayName: String,
        bundleIdentifier: String,
        appPath: String,
        action: RoutingAction
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.action = action
    }

    var useVPN: Bool {
        get { action == .routeVPN }
        set { action = newValue ? .routeVPN : .bypass }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case bundleIdentifier
        case appPath
        case action
        case useVPN
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try container.decode(String.self, forKey: .displayName)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        appPath = try container.decode(String.self, forKey: .appPath)
        if let action = try container.decodeIfPresent(RoutingAction.self, forKey: .action) {
            self.action = action
        } else {
            let useVPN = try container.decodeIfPresent(Bool.self, forKey: .useVPN) ?? false
            action = useVPN ? .routeVPN : .bypass
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(appPath, forKey: .appPath)
        try container.encode(action, forKey: .action)
    }
}

struct DiscoveredApp: Identifiable, Hashable {
    var id: String {
        appPath
    }

    let displayName: String
    let bundleIdentifier: String
    let appPath: String
    let icon: NSImage
}
