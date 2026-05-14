import Foundation

/// Resolves security-scoped bookmarks stored in AppRule and tracks active accesses.
/// Call startAccess(for:) before any filesystem read on rule.appPath (e.g. SecStaticCodeCreateWithPath),
/// then stopAllAccess() after every path that consumes those accesses (includes always-included rules).
@MainActor
final class ScopedBookmarkStore {
    private var activeURLs: [String: URL] = [:]

    /// Resolved URL if scoped access succeeded. `bookmarkIsStale` is true when Apple recommends
    /// persisting refreshed bookmark data (access may still succeed for this session).
    func startAccess(for rule: AppRule, onStaleBookmark: ((String) -> Void)? = nil) -> URL? {
        if let active = activeURLs[rule.appPath] { return active }
        guard let data = rule.bookmarkData else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        guard url.startAccessingSecurityScopedResource() else { return nil }
        if isStale {
            onStaleBookmark?(
                "Bookmark for \(rule.displayName) is stale; consider re-adding the app to refresh access."
            )
        }
        activeURLs[rule.appPath] = url
        return url
    }

    /// Stops all active scoped accesses and clears the tracking table.
    func stopAllAccess() {
        for url in activeURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        activeURLs.removeAll()
    }
}
