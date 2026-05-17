import AppKit

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

    func renderFullConfigString(profile: WireGuardProfile) throws -> String {
        let privateKey = try keychainService.read(account: profile.interface.privateKeyRef)

        var lines: [String] = ["[Interface]", "PrivateKey = \(privateKey)"]

        if !profile.interface.addresses.isEmpty {
            lines.append("Address = \(profile.interface.addresses.joined(separator: ", "))")
        }
        if !profile.interface.dnsServers.isEmpty {
            lines.append("DNS = \(profile.interface.dnsServers.joined(separator: ", "))")
        }
        if let mtu = profile.interface.mtu {
            lines.append("MTU = \(mtu)")
        }

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

        return lines.joined(separator: "\n") + "\n"
    }

    /// Convenience for callers that just need a one-shot render with the default keychain.
    static func renderFullConfigString(profile: WireGuardProfile) throws -> String {
        try WireGuardConfigRenderer().renderFullConfigString(profile: profile)
    }

    static func makeQRCodeImage(from configString: String, scale: CGFloat = 10) -> NSImage? {
        guard let data = configString.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private func debugLog(_ message: String) {
        print("[DEBUG][WGConfigRenderer] \(message)")
    }
}
