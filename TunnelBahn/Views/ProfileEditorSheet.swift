import SwiftUI
import AppKit

struct ProfileEditorSheet: View {
    private let original: WireGuardProfile
    let onSave: (WireGuardProfile) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var addressesCSV: String
    @State private var dnsCSV: String
    @State private var mtuText: String
    @State private var peerRows: [PeerEditRow]
    @State private var validationMessage: String?

    init(original: WireGuardProfile, onSave: @escaping (WireGuardProfile) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: original.name)
        _addressesCSV = State(initialValue: original.interface.addresses.joined(separator: ", "))
        _dnsCSV = State(initialValue: original.interface.dnsServers.joined(separator: ", "))
        _mtuText = State(initialValue: original.interface.mtu.map(String.init) ?? "")
        _peerRows = State(
            initialValue: original.peers.map { peer in
                PeerEditRow(
                    id: peer.id,
                    presharedKeyRef: peer.presharedKeyRef,
                    publicKey: peer.publicKey,
                    endpoint: peer.endpoint,
                    allowedIPsCSV: peer.allowedIPs.joined(separator: ", "),
                    keepaliveText: peer.persistentKeepalive.map(String.init) ?? ""
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Profile")
                .font(.title2.bold())
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("General") {
                        TextField("Display name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .maxLength($name, WireGuardProfile.maxNameLength)
                    }

                    GroupBox("Interface") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Addresses (comma-separated)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("10.0.0.2/32, …", text: $addressesCSV)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))

                            Text("DNS servers (comma-separated)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("Optional", text: $dnsCSV)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))

                            Text("MTU (optional)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("e.g. 1420", text: $mtuText)
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding(.top, 4)
                    }

                    ForEach($peerRows) { $row in
                        GroupBox("Peer") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Public key")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Base64 public key", text: $row.publicKey)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))

                                Text("Endpoint")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("host:port", text: $row.endpoint)
                                    .textFieldStyle(.roundedBorder)

                                Text("Allowed IPs (comma-separated)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("0.0.0.0/0, …", text: $row.allowedIPsCSV)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))

                                Text("Persistent keepalive (seconds, optional)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("e.g. 25", text: $row.keepaliveText)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 6)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Copy") {
                    guard let built = buildProfile() else { return }
                    do {
                        let config = try WireGuardConfigRenderer.renderFullConfigString(profile: built)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(config, forType: .string)
                        validationMessage = nil
                    } catch {
                        validationMessage = error.localizedDescription
                    }
                }
                Button("Save") {
                    if let built = buildProfile() {
                        validationMessage = nil
                        onSave(built)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
    }

    private func buildProfile() -> WireGuardProfile? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Display name is required."
            return nil
        }

        let addresses = splitCSV(addressesCSV)
        guard !addresses.isEmpty else {
            validationMessage = "At least one interface address is required."
            return nil
        }

        let mtu: Int?
        let mtuTrimmed = mtuText.trimmingCharacters(in: .whitespacesAndNewlines)
        if mtuTrimmed.isEmpty {
            mtu = nil
        } else if let value = Int(mtuTrimmed), value > 0 {
            mtu = value
        } else {
            validationMessage = "MTU must be a positive integer or empty."
            return nil
        }

        var builtPeers: [WireGuardPeer] = []
        for row in peerRows {
            let pk = row.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidWireGuardKeyBase64(pk) else {
                validationMessage = "Each peer needs a valid base64 public key (32 bytes)."
                return nil
            }
            let endpoint = row.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !endpoint.isEmpty else {
                validationMessage = "Each peer needs a non-empty endpoint."
                return nil
            }
            let allowed = splitCSV(row.allowedIPsCSV)
            guard !allowed.isEmpty else {
                validationMessage = "Each peer needs at least one Allowed IP."
                return nil
            }
            let keepTrimmed = row.keepaliveText.trimmingCharacters(in: .whitespacesAndNewlines)
            let keepalive: Int?
            if keepTrimmed.isEmpty {
                keepalive = nil
            } else if let k = Int(keepTrimmed), k > 0 {
                keepalive = k
            } else {
                validationMessage = "Persistent keepalive must be a positive integer or empty."
                return nil
            }
            builtPeers.append(
                WireGuardPeer(
                    id: row.id,
                    publicKey: pk,
                    presharedKeyRef: row.presharedKeyRef,
                    endpoint: endpoint,
                    allowedIPs: allowed,
                    persistentKeepalive: keepalive
                )
            )
        }

        guard !builtPeers.isEmpty else {
            validationMessage = "At least one peer is required."
            return nil
        }

        guard builtPeers.count == 1 else {
            validationMessage = "Only one peer is supported. Remove extra peers or use separate profiles."
            return nil
        }

        let iface = WireGuardInterface(
            privateKeyRef: original.interface.privateKeyRef,
            addresses: addresses,
            dnsServers: splitCSV(dnsCSV),
            mtu: mtu
        )

        return WireGuardProfile(
            id: original.id,
            name: trimmedName,
            interface: iface,
            peers: builtPeers,
            createdAt: original.createdAt,
            updatedAt: .now
        )
    }

    private func splitCSV(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isValidWireGuardKeyBase64(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value) else { return false }
        return data.count == 32
    }
}

private struct PeerEditRow: Identifiable, Hashable {
    let id: UUID
    var presharedKeyRef: String?
    var publicKey: String
    var endpoint: String
    var allowedIPsCSV: String
    var keepaliveText: String
}
