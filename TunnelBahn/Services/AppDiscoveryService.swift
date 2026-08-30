import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppDiscoveryService: ObservableObject {
    @Published private(set) var apps: [DiscoveredApp] = []
    @Published private(set) var isRefreshing = false
    @Published var searchText = ""

    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    var filteredApps: [DiscoveredApp] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.lowercased().contains(term) ||
                $0.bundleIdentifier.lowercased().contains(term)
        }
    }

    func refresh() {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true
        refreshTask = Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let searchDirs: [URL] = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/System/Applications"),
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            ]
            let skipSuffixes = ["installer", "updater", "uninstaller"]

            var appURLs: [URL] = []
            for dir in searchDirs {
                guard let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsPackageDescendants, .skipsHiddenFiles]
                ) else { continue }
                while let url = enumerator.nextObject() as? URL {
                    if url.pathExtension == "app" { appURLs.append(url) }
                }
            }

            var byPath: [String: DiscoveredApp] = [:]
            for url in appURLs {
                guard !Task.isCancelled else { break }

                // Skip obvious installer/updater/uninstaller bundles by filename before
                // opening the bundle.
                let baseName = url.deletingPathExtension().lastPathComponent.lowercased()
                guard !skipSuffixes.contains(where: { baseName.hasSuffix($0) }) else { continue }

                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !bundleID.isEmpty
                else { continue }

                // Skip background agents and helpers (static equivalent of activationPolicy != .regular).
                let info = bundle.infoDictionary ?? [:]
                let isUIElement = (info["LSUIElement"] as? Bool) == true
                    || (info["LSUIElement"] as? String) == "1"
                let isBackgroundOnly = (info["LSBackgroundOnly"] as? Bool) == true
                    || (info["LSBackgroundOnly"] as? String) == "1"
                guard !isUIElement, !isBackgroundOnly else { continue }

                let path = url.path
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
                    ?? url.deletingPathExtension().lastPathComponent
                // Icons are loaded lazily per-row in the view (on the main thread) to avoid
                // loading hundreds of icons up front.
                byPath[path] = DiscoveredApp(
                    displayName: name,
                    bundleIdentifier: bundleID,
                    appPath: path,
                    icon: NSImage(),
                    bookmarkData: nil
                )
            }

            let sorted = byPath.values.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            await MainActor.run {
                // Only commit if this is still the most recent refresh request.
                guard self.refreshGeneration == generation else { return }
                self.apps = sorted
                self.isRefreshing = false
            }
        }
    }

    /// Opens an NSOpenPanel so the user can pick a .app bundle or a bare executable
    /// (CLI binary). Captures a security-scoped bookmark while access is granted by the panel.
    func pickAndRegisterApp() async -> DiscoveredApp? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.applicationBundle, UTType.unixExecutable]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose an app or a command-line executable to route through the VPN"

        guard await panel.begin() == .OK, let url = panel.url else { return nil }

        let name: String
        let bundleID: String
        if let bundle = Bundle(url: url),
           let id = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty
        {
            bundleID = id
            name = bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
                ?? url.deletingPathExtension().lastPathComponent
        } else {
            // Bare executable: flows are matched by the binary's code-signing identifier.
            guard FileManager.default.isExecutableFile(atPath: url.path),
                  let id = NEAppRuleBuilder.signingIdentifier(forExecutableAtPath: url.path)
            else { return nil }
            bundleID = id
            name = url.lastPathComponent
        }
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

}
