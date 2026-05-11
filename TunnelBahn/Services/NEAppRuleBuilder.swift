import Foundation
import NetworkExtension
import Security

/// Builds and deduplicates `NEAppRule` values from user selections and fixed paths (host app scan).
enum NEAppRuleBuilder {
    static func buildFromAlwaysIncludedPaths(_ paths: [String], log: (String) -> Void) -> [NEAppRule] {
        var appRules: [NEAppRule] = []
        for raw in paths {
            let path = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                log("buildAppRulesFromAlwaysIncludedPaths: no bundle at \(path)")
                continue
            }
            log("buildAppRulesFromAlwaysIncludedPaths: expanding \(path)")
            let bundleIDsAndPaths = bundleIdentifiersAndPathsForNetworkingProcesses(appPath: path)
            if bundleIDsAndPaths.isEmpty {
                log("WARNING: no bundle IDs for always-included path \(path)")
            }
            for (bundleID, subpath) in bundleIDsAndPaths {
                let requirement: String
                if let designated = designatedRequirementString(forAppAtPath: subpath, log: log) {
                    requirement = designated
                } else {
                    requirement = #"anchor apple generic and identifier "\#(bundleID)""#
                    log("WARNING: designated requirement unavailable for \(bundleID) path=\(subpath); using fallback")
                }
                appRules.append(NEAppRule(signingIdentifier: bundleID, designatedRequirement: requirement))
            }
            appendWebKitNetworkingFallbackIfSafariApp(at: path, into: &appRules, log: log)
            if path.hasSuffix("Google Chrome.app") || path.contains("/Google Chrome.app/") {
                appendGoogleChromeCatalogRules(into: &appRules, log: log)
            }
        }
        let deduped = dedupe(appRules, log: log)
        log("buildAppRulesFromAlwaysIncludedPaths: raw=\(appRules.count) deduped=\(deduped.count)")
        return deduped
    }

    static func build(from rules: [AppRule], log: (String) -> Void) -> [NEAppRule] {
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
            log("buildAppRules: expanding appPath=\(rule.appPath) displayName=\(rule.displayName)")
            let bundleIDsAndPaths = bundleIdentifiersAndPathsForNetworkingProcesses(appPath: rule.appPath)
            if bundleIDsAndPaths.isEmpty {
                log("WARNING: buildAppRules discovered no bundle identifiers for appPath=\(rule.appPath)")
            }
            let pairList = bundleIDsAndPaths
                .map { "\($0.bundleID) @ \($0.path)" }
                .joined(separator: " | ")
            if !pairList.isEmpty {
                log("buildAppRules: discovered identifiers -> \(pairList)")
            }
            for (bundleID, path) in bundleIDsAndPaths {
                let requirement: String
                if let designated = designatedRequirementString(forAppAtPath: path, log: log) {
                    requirement = designated
                } else {
                    requirement = #"anchor apple generic and identifier "\#(bundleID)""#
                    log("WARNING: designated requirement unavailable for \(bundleID) path=\(path); using fallback requirement")
                }
                appRules.append(NEAppRule(signingIdentifier: bundleID, designatedRequirement: requirement))
            }
            appendWebKitNetworkingFallbackIfSafariApp(at: rule.appPath, into: &appRules, log: log)

            if let mainBundleID = Bundle(url: URL(fileURLWithPath: rule.appPath))?.bundleIdentifier,
               mainBundleID == "com.google.Chrome" || mainBundleID.hasPrefix("com.google.Chrome.app.")
            {
                appendGoogleChromeCatalogRules(into: &appRules, log: log)
            }
        }
        let deduped = dedupe(appRules, log: log)
        log("buildAppRules: generated=\(appRules.count) deduped=\(deduped.count)")
        return deduped
    }

    static func dedupe(_ rules: [NEAppRule], log: (String) -> Void) -> [NEAppRule] {
        var seen = Set<String>()
        var output: [NEAppRule] = []
        output.reserveCapacity(rules.count)
        for rule in rules {
            if seen.insert(rule.matchSigningIdentifier).inserted {
                output.append(rule)
            } else {
                log("dedupeAppRules: dropped duplicate signing identifier \(rule.matchSigningIdentifier)")
            }
        }
        return output
    }

    private static func appendGoogleChromeCatalogRules(into appRules: inout [NEAppRule], log: (String) -> Void) {
        for bid in PerAppSigningCatalog.googleChromePerAppExtraSigningIdentifiers {
            let requirement = #"anchor apple generic and identifier "\#(bid)""#
            appRules.append(NEAppRule(signingIdentifier: bid, designatedRequirement: requirement))
            log("appendGoogleChromeCatalogRules: signingIdentifier=\(bid)")
        }
    }

    private static func appendWebKitNetworkingFallbackIfSafariApp(at appPath: String, into appRules: inout [NEAppRule], log: (String) -> Void) {
        guard let bundle = Bundle(url: URL(fileURLWithPath: appPath)),
              bundle.bundleIdentifier == "com.apple.Safari"
        else {
            return
        }
        for extraID in PerAppSigningCatalog.safariPerAppNetworkingSigningIdentifiers {
            let requirement = #"anchor apple generic and identifier "\#(extraID)""#
            appRules.append(NEAppRule(signingIdentifier: extraID, designatedRequirement: requirement))
            log("appendWebKitNetworkingFallbackIfSafariApp: signingIdentifier=\(extraID)")
        }
    }

    private static func bundleIdentifiersAndPathsForNetworkingProcesses(appPath: String) -> [(bundleID: String, path: String)] {
        let url = URL(fileURLWithPath: appPath)
        guard let mainBundle = Bundle(url: url) else {
            let bundleID = url.deletingPathExtension().lastPathComponent
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
        var output: [(String, String)] = []
        for (bid, path) in pairs {
            let trimmed = bid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                output.append((trimmed, path))
            }
        }
        return output
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
}
