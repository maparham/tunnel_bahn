import Foundation
import OSLog

// Temporary debug-only scaffolding for Task 2 (SSH transport data model). Not a substitute
// for a real test target — the repo intentionally has none. Safe to delete once the SSH
// transport work has real integration coverage elsewhere.
#if DEBUG
enum DebugSelfChecks {
    private static let log = AppLog(subsystem: "com.tunnelbahn.mac", category: "DebugSelfChecks")

    /// Call once from the app's launch path (`TunnelBahnApp`).
    static func run() {
        checkSSHProfileRoundTrips()
        checkLegacyProfileDefaultsToWireGuard()
        log.notice("[DEBUG_SELF_CHECKS] all checks passed")
    }

    private static func checkSSHProfileRoundTrips() {
        let ssh = SSHProfile(host: "vpn.example.com", port: 22,
                             username: "tun", privateKeyRef: "kc-ssh-1",
                             hostKeyFingerprint: nil)
        let data = try! JSONEncoder().encode(ssh)
        let decoded = try! JSONDecoder().decode(SSHProfile.self, from: data)
        assert(decoded == ssh, "SSHProfile Codable round-trip mismatch")
    }

    private static func checkLegacyProfileDefaultsToWireGuard() {
        // A profile JSON written before this feature has no `transport` key, and also
        // predates `interface`/`peers` being required in this exact shape — this is just
        // the minimal legacy payload needed to exercise the defaulting decoder path.
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Home","peers":[],\
        "interface":{"privateKeyRef":"kc-1","addresses":[],"dnsServers":[]},\
        "createdAt":0,"updatedAt":0}
        """.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(WireGuardProfile.self, from: legacy)
        assert(decoded.transport == .wireguard, "legacy profile must default to .wireguard")
        assert(decoded.ssh == nil, "legacy profile must have no ssh block")
    }
}
#endif
