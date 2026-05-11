import Foundation

/// Normalizes a flow's `sourceAppSigningIdentifier` to a user-facing display name.
///
/// macOS apps frequently do their networking from helper/XPC processes signed under different
/// bundle identifiers (Chrome's 6 helpers, Safari's `com.apple.WebKit.Networking`, etc.).
/// Without rollup, the app-tunnel stats UI would show six "Chrome helper renderer / GPU / plugin..."
/// rows instead of a single "Google Chrome" row.
///
/// Resolution order:
/// 1. Curated rollup entries from `PerAppSigningCatalog.knownRollupBySigningIdentifier`.
/// 2. Active `AppRule` list from the host app (matching by `bundleIdentifier`), so any app the
///    user explicitly added shows up under the name they picked.
/// 3. Unknown — caller decides what to do (typically: bucket under "Other (signingID)" or skip).
enum PerAppIdentityMap {
    /// Returns a display name for the given signing identifier.
    /// Returns `nil` if the identifier is unknown and not present in `rules`.
    static func displayName(for signingIdentifier: String, rules: [AppRule]) -> String? {
        let trimmed = signingIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let curated = PerAppSigningCatalog.knownRollupBySigningIdentifier[trimmed] {
            return curated
        }

        if let exact = rules.first(where: { $0.bundleIdentifier == trimmed }) {
            return exact.displayName
        }

        // Heuristic: a renderer/helper of a known app might share the parent prefix
        // (e.g. "com.example.app.helper" should roll up under "com.example.app").
        if let prefixMatch = rules.first(where: { rule in
            !rule.bundleIdentifier.isEmpty && trimmed.hasPrefix(rule.bundleIdentifier + ".")
        }) {
            return prefixMatch.displayName
        }

        return nil
    }

    /// Loads the active rule list from the App Group `UserDefaults` (the same storage used
    /// by `AppRuleStore`). Safe to call from inside the extension.
    static func loadActiveRules() -> [AppRule] {
        guard let data = AppGroupStore.defaults.data(forKey: "appRules") else {
            return []
        }
        return (try? JSONDecoder().decode([AppRule].self, from: data)) ?? []
    }
}
