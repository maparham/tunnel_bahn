import Foundation
import SystemExtensions
import OSLog

@MainActor
final class SystemExtensionManager: NSObject, ObservableObject {
    private nonisolated static let osLog = Logger(subsystem: "com.tunnelbahn.mac", category: "SystemExtensions")

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
            Self.osLog.info("submitted activation request: \(id, privacy: .public)")
        }
    }
}

extension SystemExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        MainActor.assumeIsolated {
            Self.osLog.info("\(request.identifier, privacy: .public) activation result=\(result.rawValue)")
            pendingApprovalIDs.remove(request.identifier)
            needsUserApproval = !pendingApprovalIDs.isEmpty
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        MainActor.assumeIsolated {
            Self.osLog.error("\(request.identifier, privacy: .public) activation failed: \(error.localizedDescription, privacy: .public)")
            pendingApprovalIDs.remove(request.identifier)
            needsUserApproval = !pendingApprovalIDs.isEmpty
        }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated {
            Self.osLog.info("\(request.identifier, privacy: .public) needs user approval in System Settings → General → Login Items & Extensions")
            pendingApprovalIDs.insert(request.identifier)
            needsUserApproval = true
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        Self.osLog.info("replacing \(request.identifier, privacy: .public) \(existing.bundleShortVersion, privacy: .public) → \(ext.bundleShortVersion, privacy: .public)")
        return .replace
    }
}
