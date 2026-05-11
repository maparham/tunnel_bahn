import Foundation

struct RenderedWireGuardConfig {
    let fileURL: URL
    let contents: String
}

final class WireGuardConfigRenderer {
    private let keychainService: KeychainService
    private let fileManager: FileManager

    init(
        keychainService: KeychainService = .shared,
        fileManager: FileManager = .default
    ) {
        self.keychainService = keychainService
        self.fileManager = fileManager
    }

    func render(profile: WireGuardProfile, interfaceName: String) throws -> RenderedWireGuardConfig {
        debugLog("render config started profile=\(profile.name) interface=\(interfaceName)")
        let privateKey = try keychainService.read(account: profile.interface.privateKeyRef)

        var lines: [String] = [
            "[Interface]",
            "PrivateKey = \(privateKey)",
        ]

        // Keep the config strictly compatible with `wg setconf`.
        // Address/DNS/MTU are applied separately via platform commands.

        for peer in profile.peers {
            lines.append("")
            lines.append("[Peer]")
            lines.append("PublicKey = \(peer.publicKey)")
            if let presharedKeyRef = peer.presharedKeyRef {
                let psk = try keychainService.read(account: presharedKeyRef)
                lines.append("PresharedKey = \(psk)")
            }
            lines.append("AllowedIPs = \(peer.allowedIPs.joined(separator: ", "))")
            lines.append("Endpoint = \(peer.endpoint)")
            if let keepalive = peer.persistentKeepalive {
                lines.append("PersistentKeepalive = \(keepalive)")
            }
        }

        let rendered = lines.joined(separator: "\n") + "\n"
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("TunnelBahn", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = tempDirectory.appendingPathComponent("wg-\(UUID().uuidString).conf")
        try rendered.write(to: fileURL, atomically: true, encoding: .utf8)
        debugLog(
            "render config finished path=\(fileURL.path) peers=\(profile.peers.count) addresses=\(profile.interface.addresses.count)"
        )
        return RenderedWireGuardConfig(fileURL: fileURL, contents: rendered)
    }

    private func debugLog(_ message: String) {
        print("[DEBUG][WGConfigRenderer] \(message)")
    }
}
