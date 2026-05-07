import Foundation

enum WireGuardConfigParserError: LocalizedError {
    case missingInterface
    case missingPeer
    case invalidPrivateKey
    case invalidPublicKey
    case invalidPresharedKey
    case invalidConfig(String)

    var errorDescription: String? {
        switch self {
        case .missingInterface:
            return "Missing [Interface] section."
        case .missingPeer:
            return "Missing [Peer] section."
        case .invalidPrivateKey:
            return "Invalid private key in config."
        case .invalidPublicKey:
            return "Invalid public key in config."
        case .invalidPresharedKey:
            return "Invalid PresharedKey: must be standard base64 encoding a 32-byte key."
        case let .invalidConfig(message):
            return "Invalid config: \(message)"
        }
    }
}

final class WireGuardConfigParser {
    private let keychainService = KeychainService.shared

    func parse(fileURL: URL) throws -> WireGuardProfile {
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        let profileName = fileURL.deletingPathExtension().lastPathComponent
        return try parse(rawConfig: raw, profileName: profileName)
    }

    func parse(rawConfig raw: String, profileName: String) throws -> WireGuardProfile {
        let sections = parseSections(raw)

        guard let interfaceMap = sections["interface"]?.first else {
            throw WireGuardConfigParserError.missingInterface
        }
        guard let peerMaps = sections["peer"], !peerMaps.isEmpty else {
            throw WireGuardConfigParserError.missingPeer
        }
        guard peerMaps.count == 1 else {
            throw WireGuardConfigParserError.invalidConfig(
                "Only one [Peer] section is supported (this build uses a single-peer tunnel). Found \(peerMaps.count) peers."
            )
        }

        guard let privateKey = interfaceMap["privatekey"], Self.looksLikeBase64Key(privateKey) else {
            throw WireGuardConfigParserError.invalidPrivateKey
        }

        var rollbackAccounts: [String] = []
        defer {
            // If anything throws after we start writing secrets, remove partial imports.
            if !rollbackAccounts.isEmpty {
                for account in rollbackAccounts {
                    try? keychainService.delete(account: account)
                }
            }
        }

        let privateKeyRef: String
        do {
            privateKeyRef = try keychainService.save(privateKey, account: "wg.private.\(UUID().uuidString)")
        } catch {
            throw error
        }
        rollbackAccounts.append(privateKeyRef)

        let addresses = splitCSV(interfaceMap["address"])
        let dnsServers = splitCSV(interfaceMap["dns"])
        let mtu = interfaceMap["mtu"].flatMap(Int.init)

        let peers: [WireGuardPeer]
        do {
            peers = try peerMaps.map { peer in
                guard let publicKey = peer["publickey"], Self.looksLikeBase64Key(publicKey) else {
                    throw WireGuardConfigParserError.invalidPublicKey
                }
                guard let endpoint = peer["endpoint"], !endpoint.isEmpty else {
                    throw WireGuardConfigParserError.invalidConfig("Peer endpoint is missing.")
                }
                let allowedIPs = splitCSV(peer["allowedips"])
                if allowedIPs.isEmpty {
                    throw WireGuardConfigParserError.invalidConfig("Peer AllowedIPs is missing.")
                }

                let presharedRef: String?
                if let rawPsk = peer["presharedkey"] {
                    let trimmed = rawPsk.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        guard Self.looksLikeBase64Key(trimmed) else {
                            throw WireGuardConfigParserError.invalidPresharedKey
                        }
                        let ref = try keychainService.save(trimmed, account: "wg.psk.\(UUID().uuidString)")
                        rollbackAccounts.append(ref)
                        presharedRef = ref
                    } else {
                        presharedRef = nil
                    }
                } else {
                    presharedRef = nil
                }

                return WireGuardPeer(
                    publicKey: publicKey,
                    presharedKeyRef: presharedRef,
                    endpoint: endpoint,
                    allowedIPs: allowedIPs,
                    persistentKeepalive: peer["persistentkeepalive"].flatMap(Int.init)
                )
            }
        } catch {
            throw error
        }

        rollbackAccounts.removeAll()

        let interface = WireGuardInterface(
            privateKeyRef: privateKeyRef,
            addresses: addresses,
            dnsServers: dnsServers,
            mtu: mtu
        )

        return WireGuardProfile(name: profileName, interface: interface, peers: peers)
    }

    private func parseSections(_ raw: String) -> [String: [[String: String]]] {
        var output: [String: [[String: String]]] = [:]
        var currentSection: String?
        var currentMap: [String: String] = [:]

        func flushSection() {
            guard let section = currentSection else { return }
            output[section, default: []].append(currentMap)
            currentMap = [:]
        }

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                continue
            }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                flushSection()
                currentSection = String(trimmed.dropFirst().dropLast()).lowercased()
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            currentMap[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }

        flushSection()
        return output
    }

    private func splitCSV(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func looksLikeBase64Key(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value) else { return false }
        return data.count == 32
    }
}
