import Foundation

/// Single place for curated browser/process signing identifiers used in NEAppRule expansion and
/// per-app stats rollup. Add new IDs here instead of duplicating lists across `AppConstants` / UI maps.
enum PerAppSigningCatalog {
    /// Extra signing IDs for Chrome — scan often still misses helpers; traffic may use these without a nested `.app` path.
    static let googleChromePerAppExtraSigningIdentifiers: [String] = [
        "com.google.Chrome",
        "com.google.Chrome.helper",
        "com.google.Chrome.helper.renderer",
        "com.google.Chrome.helper.plugin",
        "com.google.Chrome.helper.gpu",
        "com.google.Chrome.helper.alerts",
    ]

    /// Safari performs networking in `com.apple.WebKit.Networking`, which is not always under Safari.app bundle scan paths.
    static let safariPerAppNetworkingSigningIdentifiers: [String] = [
        "com.apple.WebKit.Networking",
    ]

    /// Curated rollup table for apps with multiple known signing identifiers (stats UI + `PerAppIdentityMap`).
    static let knownRollupBySigningIdentifier: [String: String] = {
        var m = [String: String]()
        let chrome = "Google Chrome"
        for id in googleChromePerAppExtraSigningIdentifiers {
            m[id] = chrome
        }
        let safari = "Safari"
        m["com.apple.Safari"] = safari
        for id in safariPerAppNetworkingSigningIdentifiers {
            m[id] = safari
        }
        m["com.apple.WebKit.WebContent"] = safari
        m["com.apple.WebKit.GPU"] = safari

        m["org.mozilla.firefox"] = "Firefox"
        m["org.mozilla.nightly"] = "Firefox"

        m["com.brave.Browser"] = "Brave"
        m["com.microsoft.edgemac"] = "Microsoft Edge"

        m["com.apple.curl"] = "Terminal"
        m["com.apple.ssh"] = "Terminal"

        return m
    }()
}
