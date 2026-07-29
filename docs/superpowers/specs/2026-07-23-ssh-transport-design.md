# SSH port-forwarding as a second egress transport

**Date:** 2026-07-23
**Status:** Implemented

## Goal

Today per-app traffic can only tunnel through WireGuard. Add **SSH port
forwarding** as an alternative egress transport, selectable per profile,
coexisting with WireGuard. The per-app identity + destination-filter routing
layer is transport-agnostic and stays unchanged — only the final hop changes.

## Background: current data path

1. `TransparentProxyExtension` captures per-app TCP/UDP flows (by signing ID)
   in `handleNewFlow`.
2. Flows are relayed over a UDS (App Group container) to the packet-tunnel
   extension via `TransparentProxyRelayClient` → `PacketTunnelRelayServer`.
3. The packet-tunnel extension runs each TCP flow through
   `SmoltcpRelayBridge` (userspace TCP/IP) → `BoringTunAdapter`
   (WireGuard crypto) → WG-over-UDP to the peer.

The routing/filter decision (whether a flow is tunneled) is made in the proxy
extension and is independent of *how* the flow egresses.

## Key finding: the transport seam already exists

`PacketTunnelRelayServer` talks to its bridge through a small,
transport-agnostic method set:

- `openTCP(flowID, remoteHost, remotePort) -> Bool`
- `sendTCP(flowID, data) -> SendResult` (`.ok` / `.transient` / `.permanent`)
- `close(flowID)`
- `onPayloadFromFlow: ((UInt64, Data) -> Void)?` callback
- `onFlowClosed: ((UInt64, String?) -> Void)?` callback

The relay wire protocol (`RelayWireFrame`) is already stream-oriented, and the
relay layer **already rejects UDP** at the packet-tunnel boundary
(`"UDP not implemented"`), which matches the drop-UDP decision below. This is
the pluggable seam.

## Architecture

### Transport protocol

Extract the method set above into a `RelayFlowTransport` protocol.

- `SmoltcpRelayBridge` conforms as-is (it already has the exact methods). Its
  smoltcp-specific methods (`feedInbound`, `pollOutboundPackets`,
  `shouldInterceptInbound`) remain on the concrete type, used only by the WG
  packet path.
- New `SSHFlowTransport` conforms to the same protocol, backed by SwiftNIO SSH.

`PacketTunnelRelayServer` depends on `RelayFlowTransport`, not the concrete
type. **The hardened UDS layer — framing, backpressure hysteresis, flow
lifecycle, per-app stats — is reused untouched.**

### Provider branch

`PacketTunnelProvider.startTunnel` branches on the active profile's transport:

- **WireGuard**: `BoringTunAdapter` + `SmoltcpRelayBridge` — today's path,
  unchanged.
- **SSH**: `SSHFlowTransport` only. No BoringTun, no smoltcp, no utun packet
  loop. Calls `setTunnelNetworkSettings` with minimal settings solely to
  signal the provider as connected to the OS.

## SSH engine

Embed **SwiftNIO SSH** (`swift-nio-ssh`, Apple's pure-Swift implementation) as
an SPM package added to `project.yml` (`packages:`), linked into the
packet-tunnel target. This is the first SPM dependency in the project
(BoringTun is a prebuilt static lib). No subprocess / no shelling out to the
`ssh` binary — the system extension is sandboxed against `exec`.

- One SSH transport connection to the server per active session.
- Each captured TCP flow → a `direct-tcpip` channel to `host:port`.
- `openTCP` opens a channel; `sendTCP` writes with the channel window mapped
  onto the existing `.transient` backpressure signal; channel EOF/close →
  `onFlowClosed`.

## UDP & DNS policy

- **Tunneled UDP flows are dropped, explicitly.** Browsers fall back to TCP;
  nothing leaks outside the tunnel, preserving the split-tunnel no-leak
  guarantee. Implementation (see Task 7): the proxy's `UDPFlowRelay` normally
  sends a matched app's tunneled UDP via `sendViaTunnel` →
  `RelayOutboundConnection`, a path that depends on the WG utun. In SSH mode
  there is no WG backing, so the proxy is made transport-aware (a
  `dropTunneledUDP` flag in `TransparentProxyRuntimeConfig`) and **drops** any
  would-be-tunneled UDP datagram rather than dialing that path — a
  deterministic drop instead of relying on a utun-to-nowhere.
- **DNS needs no special handling — it already works.** DNS to a local/LAN
  system resolver is bypassed direct (`UDPFlowRelay` `shouldBypassLocal`), the
  same in SSH mode as WG mode: the app resolves via the system resolver, gets
  IPs, then opens TCP that SSH tunnels. No DNS-over-TCP translation is built.
- **Deferred (v1 limitations, documented):** (a) DNS-over-TCP is not
  implemented, so an app hardwired to a *remote* UDP resolver that itself
  falls in the tunnel range won't resolve in SSH mode; (b) internal-only /
  split-horizon names won't resolve remotely, because by flow-capture time the
  app has already resolved the name to an IP — no hostname survives to hand the
  SSH server. Both are inherent to this capture architecture, not SSH-specific
  regressions.

## Profile model & UI

- Unified profile list. Each profile carries `transport: .wireguard | .ssh`.
- New SSH profile fields: host, port, username, **private key**
  (ed25519 or ECDSA P-256/384/521; RSA unsupported by swift-nio-ssh), imported from file or pasted PEM, stored in Keychain via the
  existing `KeychainService`.
- Auth: **private key only** for v1 — ed25519 or ECDSA (P-256/384/521). RSA is unsupported (swift-nio-ssh has no RSA key type). No password / keyboard-interactive / agent.
- `ProfileEditorSheet` shows WG or SSH fields based on type.
- Connect flow, status view, per-app stats, and routing/destination filters
  are unchanged — they sit above the transport.

## Security & robustness (designed in, not optional)

- **Host-key verification**: TOFU on first connect; the extension pins the
  server key fingerprint (as-built: in the App Group defaults it owns).
  Mismatch on reconnect is a hard failure (prevents silent MITM) — this always
  holds. Caveat (as-built): the host app and the root extension resolve the App
  Group to different containers, so the app's fingerprint surfacing and "Reset
  trust" are best-effort (they touch the app-side copy, not the extension's).
  An authoritative reset needs a `sendProviderMessage` IPC — a documented v1
  limitation / planned follow-up, not shipped here.
- **Self-loop guard**: the extension's own outbound TCP connection to the SSH
  server must not be diverted back into the proxy. The extension is not a
  matched app so `handleNewFlow` won't divert it (documented as an invariant).
- **Reconnect**: all flows share one SSH connection — transport-level reconnect
  with backoff and teardown of orphaned flows on drop, mirroring the WG
  watchdog philosophy. As-built keepalive is TCP `SO_KEEPALIVE` + `closeFuture`
  drop detection only; an application-level SSH keepalive is deferred
  (`keepalive@openssh.com` is `internal` in swift-nio-ssh 0.14.1).

## Known limitation (v1, documented)

**Head-of-line blocking**: a single SSH connection multiplexes all channels;
one lost TCP segment on that connection stalls all flows. Accepted for v1.
Multi-connection pooling is a later optimization, not part of this work.

## Testing

Extend the existing S1..SN scenario-probe workflow with an SSH profile:

- In-filter TCP probe — reaches destination, tunneled via SSH.
- Out-of-filter probe — proves the destination filter still narrows routing.
- UDP-dropped / no-leak probe — QUIC/UDP to a filter-matched host is dropped
  (no UDP egress), TCP fallback succeeds; paired out-of-filter UDP still egresses
  direct.
- DNS probe — resolution still works via the existing local-resolver bypass
  (no DNS-over-TCP was built).

Per project convention: set toggles + start the tunnel via URL scheme, then
stop — the user runs the probes.

## Feasibility risk

The one item not verifiable without a build (per the no-build rule): that
`swift-nio-ssh` links cleanly into the system-extension target. This is the
de-risking first step of implementation, not a design unknown.

## Out of scope (v1)

- Password / keyboard-interactive / ssh-agent auth.
- UDP forwarding of any kind.
- Multi-connection pooling / HOL-blocking mitigation.
- SSH-as-per-app-override (global transport is per active profile).

## As-built: SSH server-side DNS (SNI-based)

SSH mode resolves destination hostnames on the SSH server by using the TLS SNI
recovered from each routed-app flow's ClientHello as the `direct-tcpip` target,
instead of the app's locally-resolved IP. This defeats local DNS hijacking/
sinkholing for TLS traffic and matches `ssh -D` SOCKS remote-DNS behavior.

Limitations (future work — DNS-over-SSH task):
- Non-TLS (plain HTTP), non-SNI TLS, and ECH have no recoverable name → they
  fall back to the app-resolved IP and therefore remain subject to local DNS.
  They fail closed (no real-interface leak); they do not bypass the tunnel.
- Genuine RFC1918 LAN access from a routed app is not distinguished from a
  private-range sinkhole while remote-DNS is active; such flows are peeked
  and, absent SNI, fail closed rather than reaching the LAN.
- Full parity (covering non-TLS + making local `getaddrinfo` return real
  answers) requires an in-extension DNS resolver forwarding queries over the
  SSH connection. Tracked as the DNS-over-SSH follow-on.
- **SSH + domain-rules combination**: when a profile is both SSH (remote-DNS
  active) *and* has domain/SNI split rules configured, a routed app's flow to
  a **non-matching** domain still routes direct on the real interface (en0)
  using the app's locally-resolved IP — this is the inherited WireGuard
  SNI-split behavior, applied unchanged. It is not a leak of *tunneled*
  traffic (the user configured that domain to split), but it does mean the
  anti-hijack protection does **not** apply to non-matching domains in that
  combined configuration. Recommendation: for full anti-hijack coverage, use
  SSH App-Tunnel mode **without** domain rules, so every routed-app flow
  tunnels and is resolved server-side.
- The peek-forcing predicate is scoped to overridable-private (routable-private:
  RFC1918/CGNAT/ULA) destinations only, since a DNS-hijack sinkhole always
  rewrites a public hostname to one of those ranges. Two consequences:
  - A server-speaks-first protocol (SMTP/IMAP/POP3/FTP/MySQL, etc.) whose
    destination is a private-range sinkhole still hangs: the peek waits for a
    first byte the client won't send until it sees the server's banner. This
    is rare and fails closed (no leak); it is the same class as the RFC1918-LAN
    limitation above. Server-first protocols to correctly-resolved PUBLIC hosts
    are unaffected in App-Tunnel mode (no domain rules) — they skip the peek
    entirely and use the pre-plan no-peek path. Note: if the profile ALSO has
    domain/SNI split rules configured (`sniMode`), the SNI decider is active for
    every routed TCP flow including public hosts, so those server-first flows are
    peeked too (pre-existing SNI-split behavior, unchanged by this feature) — for
    full server-first compatibility, use SSH App-Tunnel mode without domain rules.
  - A sinkhole that redirects to loopback/`0.0.0.0`/link-local (e.g. a
    Pi-hole-style `0.0.0.0` block) is NOT caught by SSH remote-DNS — those
    ranges stay unconditionally bypassed by design (they can never be a real
    tunnelable destination), so such a blocked host remains blocked. Only
    routable-private sinkholes (RFC1918/CGNAT/ULA) are re-routed by SNI.
