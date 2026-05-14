import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppDiscoveryService: ObservableObject {
    @Published private(set) var apps: [DiscoveredApp] = []
    @Published var searchText = ""

    var filteredApps: [DiscoveredApp] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.lowercased().contains(term) ||
                $0.bundleIdentifier.lowercased().contains(term)
        }
    }

    func refresh() {
        var byPath: [String: DiscoveredApp] = [:]
        mergeRunningApplications(into: &byPath)
        apps = byPath.values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Opens an NSOpenPanel so the user can pick a .app bundle.
    /// Captures a security-scoped bookmark while access is granted by the panel.
    func pickAndRegisterApp() async -> DiscoveredApp? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose an app to route through the VPN"

        guard await panel.begin() == .OK, let url = panel.url else { return nil }

        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty
        else { return nil }

        let name = bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
            ?? url.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: url.path)

        let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        return DiscoveredApp(
            displayName: name,
            bundleIdentifier: bundleID,
            appPath: url.path,
            icon: icon,
            bookmarkData: bookmarkData
        )
    }

    // MARK: - Running apps

    private func mergeRunningApplications(into discovered: inout [String: DiscoveredApp]) {
        for application in NSWorkspace.shared.runningApplications {
            guard application.activationPolicy == .regular,
                  let bundleID = application.bundleIdentifier,
                  let url = application.bundleURL
            else { continue }

            let path = url.path
            let name = application.localizedName ?? url.deletingPathExtension().lastPathComponent
            let icon = application.icon ?? NSWorkspace.shared.icon(forFile: path)
            // Do not store security-scoped bookmarks here: sandboxed apps cannot mint durable scoped
            // bookmarks for other bundles without explicit user consent (use Add App…).
            discovered[path] = DiscoveredApp(
                displayName: name,
                bundleIdentifier: bundleID,
                appPath: path,
                icon: icon,
                bookmarkData: nil
            )
        }
    }
}
