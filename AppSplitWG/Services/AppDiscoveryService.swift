import AppKit
import Foundation

@MainActor
final class AppDiscoveryService: ObservableObject {
    @Published private(set) var apps: [DiscoveredApp] = []
    @Published var searchText = ""

    /// Standard folders to scan for `.app` bundles (non-running apps appear here).
    private static let applicationSearchRoots: [URL] = {
        let fm = FileManager.default

        // Prefer OS-provided “Applications” directories first (more stable across macOS releases).
        var roots = Set<URL>()
        roots.formUnion(fm.urls(for: .applicationDirectory, in: .localDomainMask))
        roots.formUnion(fm.urls(for: .applicationDirectory, in: .systemDomainMask))
        roots.formUnion(fm.urls(for: .applicationDirectory, in: .userDomainMask))

        // Extra roots for newer macOS system apps (e.g. Safari) that may live outside /System/Applications.
        // Only include if present, to keep older releases working.
        let extraCandidates: [URL] = [
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
        ]
        for url in extraCandidates where fm.fileExists(atPath: url.path) {
            roots.insert(url)
        }

        // Keep legacy hard-coded roots as a safety net (some environments may not return them via FileManager).
        roots.insert(URL(fileURLWithPath: "/Applications", isDirectory: true))
        roots.insert(URL(fileURLWithPath: "/System/Applications", isDirectory: true))

        // Deterministic ordering for stable UI.
        return roots.sorted { $0.path < $1.path }
    }()

    /// Max depth from each root (e.g. `Applications/Utilities/Terminal.app`).
    private static let maxDiscoveryDepth = 5

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
        mergeInstalledApplications(into: &byPath)

        apps = byPath.values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
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
            discovered[path] = DiscoveredApp(
                displayName: name,
                bundleIdentifier: bundleID,
                appPath: path,
                icon: icon
            )
        }
    }

    // MARK: - Installed apps (disk scan)

    private func mergeInstalledApplications(into discovered: inout [String: DiscoveredApp]) {
        let fm = FileManager.default
        var bundleURLs: [URL] = []
        for root in Self.applicationSearchRoots {
            guard fm.fileExists(atPath: root.path) else { continue }
            bundleURLs.append(contentsOf: Self.enumerateApplicationBundlesUnder(root: root, currentDepth: 0, maxDepth: Self.maxDiscoveryDepth))
        }

        for url in bundleURLs {
            let path = url.path
            guard let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleID.isEmpty
            else { continue }

            let name =
                bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
                ?? bundle.localizedInfoDictionary?[kCFBundleNameKey as String] as? String
                ?? url.deletingPathExtension().lastPathComponent

            if discovered[path] != nil {
                continue
            }

            let icon = NSWorkspace.shared.icon(forFile: path)
            discovered[path] = DiscoveredApp(
                displayName: name,
                bundleIdentifier: bundleID,
                appPath: path,
                icon: icon
            )
        }
    }

    /// Finds `.app` bundles under `root` without descending inside a bundle’s `Contents` (no nested helper spam).
    private static func enumerateApplicationBundlesUnder(root: URL, currentDepth: Int, maxDepth: Int) -> [URL] {
        guard currentDepth <= maxDepth else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let ext = url.pathExtension.lowercased()

            if ext == "app", isDir {
                results.append(url)
                continue
            }
            guard isDir else { continue }

            let name = url.lastPathComponent
            if name == "Contents" || name.hasSuffix(".app") {
                continue
            }

            results.append(contentsOf: enumerateApplicationBundlesUnder(
                root: url,
                currentDepth: currentDepth + 1,
                maxDepth: maxDepth
            ))
        }
        return results
    }
}
