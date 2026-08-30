import Foundation

@MainActor
final class AppRuleStore: ObservableObject {
    @Published private(set) var rules: [AppRule] = []

    private let key = "appRules"

    init() {
        load()
    }

    func setRule(for app: DiscoveredApp, action: RoutingAction) {
        if let index = rules.firstIndex(where: { $0.appPath == app.appPath }) {
            rules[index].action = action
            if let bm = app.bookmarkData { rules[index].bookmarkData = bm }
        } else {
            let rule = AppRule(
                displayName: app.displayName,
                bundleIdentifier: app.bundleIdentifier,
                appPath: app.appPath,
                action: action,
                bookmarkData: app.bookmarkData
            )
            rules.append(rule)
        }
        save()
    }

    /// Adds (or re-enables) a rule identified only by its code-signing identifier, with no
    /// on-disk path. Used by the Tunnel Monitor, which observes flows by signing ID.
    func addSigningIdentifierRule(displayName: String, signingIdentifier: String) {
        if let index = rules.firstIndex(where: { $0.bundleIdentifier == signingIdentifier }) {
            rules[index].action = .routeVPN
        } else {
            rules.append(AppRule(
                displayName: displayName,
                bundleIdentifier: signingIdentifier,
                appPath: AppRule.signingOnlyPath(for: signingIdentifier),
                action: .routeVPN
            ))
        }
        save()
    }

    func isEnabled(for appPath: String) -> Bool {
        rules.first(where: { $0.appPath == appPath })?.useVPN ?? false
    }

    func enabledRules() -> [AppRule] {
        rules.filter(\.useVPN)
    }

    func action(for appPath: String) -> RoutingAction? {
        rules.first(where: { $0.appPath == appPath })?.action
    }

    func replaceAll(_ newRules: [AppRule]) {
        rules = newRules
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(rules) {
            AppGroupStore.defaults.set(data, forKey: key)
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = AppGroupStore.defaults.data(forKey: key),
           let decoded = try? decoder.decode([AppRule].self, from: data)
        {
            rules = decoded
        }
    }
}
