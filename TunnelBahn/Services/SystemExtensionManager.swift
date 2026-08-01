import Foundation
import SystemExtensions
import OSLog

@MainActor
final class SystemExtensionManager: NSObject, ObservableObject {
    private nonisolated static let osLog = AppLog(subsystem: "com.tunnelbahn.mac", category: "SystemExtensions")

    private let extensionIDs = [
        AppConstants.packetTunnelProviderBundleIdentifier,
        PerAppStatsProxyManager.extensionBundleIdentifier,
    ]

    /// True when at least one extension is waiting for user approval in System Settings.
    @Published var needsUserApproval = false

    private var pendingApprovalIDs: Set<String> = []

    /// Submit activation requests for both network extensions. Safe to call on every launch —
    /// the framework is a no-op if the extension is already at the current version.
    func installExtensions() {
        for id in extensionIDs {
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: id,
                queue: .main
            )
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
            Self.osLog.info("submitted activation request: \(id)")
        }
    }
}

extension SystemExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        MainActor.assumeIsolated {
            Self.osLog.info("\(request.identifier) activation result=\(result.rawValue)")
            pendingApprovalIDs.remove(request.identifier)
            needsUserApproval = !pendingApprovalIDs.isEmpty
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        MainActor.assumeIsolated {
            // .requestCanceled is this manager's own answer when the installed extension is
            // already this exact build (see actionForReplacingExtension) — not a failure.
            if (error as? OSSystemExtensionError)?.code == .requestCanceled {
                Self.osLog.info("\(request.identifier) already active at this build; activation request canceled")
            } else {
                Self.osLog.error("\(request.identifier) activation failed: \(error.localizedDescription)")
            }
            pendingApprovalIDs.remove(request.identifier)
            needsUserApproval = !pendingApprovalIDs.isEmpty
        }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated {
            Self.osLog.info("\(request.identifier) needs user approval in System Settings → General → Login Items & Extensions")
            pendingApprovalIDs.insert(request.identifier)
            needsUserApproval = true
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        let shouldReplace = SysextReplacementPolicy.shouldReplace(
            existingVersion: existing.bundleShortVersion,
            existingBuild: existing.bundleVersion,
            candidateVersion: ext.bundleShortVersion,
            candidateBuild: ext.bundleVersion
        )
        Self.osLog.info(
            "\(request.identifier) \(existing.bundleShortVersion) (\(existing.bundleVersion)) → \(ext.bundleShortVersion) (\(ext.bundleVersion)): \(shouldReplace ? "replace" : "keep running copy")"
        )
        return shouldReplace ? .replace : .cancel
    }
}
