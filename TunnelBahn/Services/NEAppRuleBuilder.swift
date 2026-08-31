import Foundation
import NetworkExtension
import Security

/// Builds and deduplicates `NEAppRule` values from user selections and fixed paths (host app scan).
enum NEAppRuleBuilder {
    static func buildFromAlwaysIncludedPaths(
        _ paths: [String],
        log: (String) -> Void,
        verbose: Bool = false
    ) -> [NEAppRule] {
        var appRules: [NEAppRule] = []
        for raw in paths {
            let path = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                log("buildAppRulesFromAlwaysIncludedPaths: no bundle at \(path)")
                continue
            }
            if verbose {
                log("buildAppRulesFromAlwaysIncludedPaths: expanding \(path)")
            }
            let bundleIDsAndPaths = bundleIdentifiersAndPathsForNetworkingProcesses(appPath: path)
            if bundleIDsAndPaths.isEmpty {
                log("WARNING: no bundle IDs for always-included path \(path)")
            }
            for (bundleID, subpath) in bundleIDsAndPaths {
                guard let requirement = requirementForBundle(bundleID: bundleID, path: subpath, log: log) else { continue }
                appendRule(signingIdentifier: bundleID, requirement: requirement, into: &appRules, log: log)
            }
            appendWebKitNetworkingFallbackIfSafariApp(at: path, into: &appRules, log: log, verbose: verbose)
            if path.hasSuffix("Google Chrome.app") || path.contains("/Google Chrome.app/") {
                appendGoogleChromeCatalogRules(into: &appRules, log: log, verbose: verbose)
            }
        }
        let deduped = dedupe(appRules, log: log, verbose: verbose)
        log("buildAppRulesFromAlwaysIncludedPaths: raw=\(appRules.count) deduped=\(deduped.count)")
        return deduped
    }

    static func build(from rules: [AppRule], log: (String) -> Void, verbose: Bool = false) -> [NEAppRule] {
        let includedRules = rules.filter { $0.action == .routeVPN }
        log(
            "buildAppRules: allow-list totalRules=\(rules.count) routeVPNRules=\(includedRules.count)"
        )
        if includedRules.isEmpty {
            log("buildAppRules: no apps set to Route via VPN; NEAppRule result empty")
        }

        var appRules: [NEAppRule] = []
        appRules.reserveCapacity(includedRules.count)
        for rule in includedRules {
            if verbose {
                log("buildAppRules: expanding appPath=\(rule.appPath) displayName=\(rule.displayName)")
            }
            // Rules added by signing identifier alone (Tunnel Monitor) or whose binary is gone:
            // match on the stored signing ID only. Signing-only rules carry no Apple anchor —
            // they exist precisely for binaries we cannot inspect on disk, which includes
            // ad-hoc signed CLI tools; an ad-hoc signature has no certificate chain, so an
            // Apple-anchored requirement would produce a rule that silently matches nothing.
            // A path-based rule whose binary is merely absent (unmounted volume, moved bundle)
            // keeps the anchor: dropping it would let any local ad-hoc binary claim the app's
            // identifier and ride the VPN in its place.
            guard !rule.isSigningOnly, FileManager.default.fileExists(atPath: rule.appPath) else {
                let bundleID = rule.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !bundleID.isEmpty else {
                    log("WARNING: buildAppRules: rule \(rule.displayName) has no path and no signing identifier; skipped")
                    continue
                }
                guard let requirement = identifierRequirement(bundleID, anchoredToApple: !rule.isSigningOnly) else {
                    log("WARNING: buildAppRules: unsafe characters in signing identifier \(bundleID); rule skipped")
                    continue
                }
                appendRule(signingIdentifier: bundleID, requirement: requirement, into: &appRules, log: log)
                if rule.isSigningOnly {
                    log("buildAppRules: signing-ID-only rule for \(bundleID)")
                } else {
                    log("WARNING: buildAppRules: binary missing at \(rule.appPath); using anchored identifier fallback for \(bundleID)")
                }
                continue
            }
            let bundleIDsAndPaths = bundleIdentifiersAndPathsForNetworkingProcesses(appPath: rule.appPath)
            if bundleIDsAndPaths.isEmpty {
                log("WARNING: buildAppRules discovered no bundle identifiers for appPath=\(rule.appPath)")
            }
            let pairList = bundleIDsAndPaths
                .map { "\($0.bundleID) @ \($0.path)" }
                .joined(separator: " | ")
            if verbose, !pairList.isEmpty {
                log("buildAppRules: discovered identifiers -> \(pairList)")
            }
            for (bundleID, path) in bundleIDsAndPaths {
                guard let requirement = requirementForBundle(bundleID: bundleID, path: path, log: log) else { continue }
                appendRule(signingIdentifier: bundleID, requirement: requirement, into: &appRules, log: log)
            }
            appendWebKitNetworkingFallbackIfSafariApp(at: rule.appPath, into: &appRules, log: log, verbose: verbose)

            if let mainBundleID = Bundle(url: URL(fileURLWithPath: rule.appPath))?.bundleIdentifier,
               mainBundleID == "com.google.Chrome" || mainBundleID.hasPrefix("com.google.Chrome.app.")
            {
                appendGoogleChromeCatalogRules(into: &appRules, log: log, verbose: verbose)
            }
        }
        let deduped = dedupe(appRules, log: log, verbose: verbose)
        log("buildAppRules: generated=\(appRules.count) deduped=\(deduped.count)")
        return deduped
    }

    static func dedupe(_ rules: [NEAppRule], log: (String) -> Void, verbose: Bool = false) -> [NEAppRule] {
        var seen = Set<String>()
        var output: [NEAppRule] = []
        output.reserveCapacity(rules.count)
        for rule in rules {
            if seen.insert(rule.matchSigningIdentifier).inserted {
                output.append(rule)
            } else if verbose {
                log("dedupeAppRules: dropped duplicate signing identifier \(rule.matchSigningIdentifier)")
            }
        }
        return output
    }

    private static func appendGoogleChromeCatalogRules(
        into appRules: inout [NEAppRule],
        log: (String) -> Void,
        verbose: Bool
    ) {
        for bid in PerAppSigningCatalog.googleChromePerAppExtraSigningIdentifiers {
            guard let requirement = identifierRequirement(bid, anchoredToApple: true) else {
                log("WARNING: unsafe characters in catalog signing identifier \(bid); rule skipped")
                continue
            }
            appendRule(signingIdentifier: bid, requirement: requirement, into: &appRules, log: log)
            if verbose {
                log("appendGoogleChromeCatalogRules: signingIdentifier=\(bid)")
            }
        }
    }

    private static func appendWebKitNetworkingFallbackIfSafariApp(
        at appPath: String,
        into appRules: inout [NEAppRule],
        log: (String) -> Void,
        verbose: Bool
    ) {
        guard let bundle = Bundle(url: URL(fileURLWithPath: appPath)),
              bundle.bundleIdentifier == "com.apple.Safari"
        else {
            return
        }
        for extraID in PerAppSigningCatalog.safariPerAppNetworkingSigningIdentifiers {
            guard let requirement = identifierRequirement(extraID, anchoredToApple: true) else {
                log("WARNING: unsafe characters in catalog signing identifier \(extraID); rule skipped")
                continue
            }
            appendRule(signingIdentifier: extraID, requirement: requirement, into: &appRules, log: log)
            if verbose {
                log("appendWebKitNetworkingFallbackIfSafariApp: signingIdentifier=\(extraID)")
            }
        }
    }

    private static func bundleIdentifiersAndPathsForNetworkingProcesses(appPath: String) -> [(bundleID: String, path: String)] {
        let url = URL(fileURLWithPath: appPath)
        guard let mainBundle = Bundle(url: url) else {
            // Bare executable (CLI binary): flows match on the code-signing identifier,
            // which for signed binaries differs from the filename (e.g. "claude" is
            // signed as "com.anthropic.claude-code").
            let bundleID = signingIdentifier(forExecutableAtPath: appPath)
                ?? url.deletingPathExtension().lastPathComponent
            return [(bundleID, appPath)]
        }

        var pairs: [(String, String)] = []
        if let bundleID = mainBundle.bundleIdentifier {
            pairs.append((bundleID, appPath))
        }

        let candidateDirs: [URL] = [
            url.appendingPathComponent("Contents/Frameworks", isDirectory: true),
            url.appendingPathComponent("Contents/XPCServices", isDirectory: true),
            url.appendingPathComponent("Contents/PlugIns", isDirectory: true),
            url.appendingPathComponent("Contents/Helpers", isDirectory: true),
        ]

        let fm = FileManager.default
        for dir in candidateDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "app" || ext == "xpc" || ext == "appex" else { continue }
                if let b = Bundle(url: fileURL), let bid = b.bundleIdentifier {
                    pairs.append((bid, fileURL.path))
                }
            }
        }

        var seen = Set<String>()
        var output: [(bundleID: String, path: String)] = []
        for (bid, path) in pairs {
            let trimmed = bid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                output.append((trimmed, path))
            }
        }
        return output
    }

    /// Reads the code-signing identifier of an executable or bundle on disk.
    /// This is the value NE flows report as `sourceAppSigningIdentifier`, and it works
    /// for bare CLI binaries that have no Info.plist (including ad-hoc signed ones).
    static func signingIdentifier(forExecutableAtPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let identifier = (dict[kSecCodeInfoIdentifier as String] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty
        else { return nil }
        return identifier
    }

    static func designatedRequirementString(forAppAtPath appPath: String, log: (String) -> Void) -> String? {
        let url = URL(fileURLWithPath: appPath)
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            log("designatedRequirement lookup failed for path=\(appPath) status=\(createStatus)")
            return nil
        }

        var requirement: SecRequirement?
        let reqStatus = SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement)
        guard reqStatus == errSecSuccess, let requirement else {
            log("designatedRequirement copy failed for path=\(appPath) status=\(reqStatus)")
            return nil
        }

        var requirementString: CFString?
        let strStatus = SecRequirementCopyString(requirement, SecCSFlags(), &requirementString)
        guard strStatus == errSecSuccess, let requirementString else {
            log("designatedRequirement string failed for path=\(appPath) status=\(strStatus)")
            return nil
        }
        return requirementString as String
    }

    // MARK: - Requirement construction

    /// Whether `id` can be interpolated into the code-requirement language verbatim.
    ///
    /// Requirement strings are a small language, and the identifier is spliced into a
    /// quoted literal. A quote or backslash would produce a requirement that fails to
    /// compile, yielding an NEAppRule that is well-formed but matches nothing — a silent
    /// routing failure. Real signing identifiers are reverse-DNS, so rejecting anything
    /// outside that character set is both safe and sufficient; escaping is not worth the
    /// subtlety for input that should never contain these characters.
    static func isSafeSigningIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-")
        }
    }

    /// Builds an identifier-based requirement, or nil when `id` cannot be expressed safely.
    ///
    /// `anchoredToApple` demands a certificate chain to an Apple root. That holds for App
    /// Store, Developer ID, and Apple-signed code, but NOT for ad-hoc signatures, which
    /// have no chain at all — so it must be omitted wherever ad-hoc signed binaries are
    /// legitimate targets.
    static func identifierRequirement(_ id: String, anchoredToApple: Bool) -> String? {
        guard isSafeSigningIdentifier(id) else { return nil }
        return anchoredToApple
            ? #"anchor apple generic and identifier "\#(id)""#
            : #"identifier "\#(id)""#
    }

    /// Appends a rule only if its requirement actually compiles.
    ///
    /// This is the backstop for every path above, including designated requirements read
    /// from disk: an uncompilable requirement produces a rule that silently matches
    /// nothing, so failing loudly here is strictly better than shipping an inert rule.
    private static func appendRule(
        signingIdentifier: String,
        requirement: String,
        into appRules: inout [NEAppRule],
        log: (String) -> Void
    ) {
        var parsed: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &parsed)
        guard status == errSecSuccess else {
            log("WARNING: requirement does not compile for \(signingIdentifier) status=\(status); rule skipped: \(requirement)")
            return
        }
        appRules.append(NEAppRule(signingIdentifier: signingIdentifier, designatedRequirement: requirement))
    }

    /// Resolves the requirement for a bundle we have on disk: its real designated
    /// requirement when readable, else an Apple-anchored identifier match.
    private static func requirementForBundle(
        bundleID: String,
        path: String,
        log: (String) -> Void
    ) -> String? {
        if let designated = designatedRequirementString(forAppAtPath: path, log: log) {
            return designated
        }
        guard let fallback = identifierRequirement(bundleID, anchoredToApple: true) else {
            log("WARNING: unsafe characters in signing identifier \(bundleID); rule skipped")
            return nil
        }
        log("WARNING: designated requirement unavailable for \(bundleID) path=\(path); using fallback")
        return fallback
    }
}
