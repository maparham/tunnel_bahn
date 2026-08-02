# TunnelBahn for Android — Design

Date: 2026-08-02
Status: Approved

## Problem

TunnelBahn is a native macOS WireGuard split-tunnel client with a TCP-wrapping
obfuscation mode, an SSH port-forwarding transport, and per-app + per-destination
routing. We need an Android client with the same core capability so it is usable from
the Iranian intranet, whose international gateway runs actively-probing DPI, SNI
filtering, protocol fingerprinting, bandwidth throttling, and periodic near-total
blackouts.

Ground truth for the target network (verified 2026-08-02, not from memory):

- WireGuard's handshake is reliably fingerprinted and blocked in Iran; a fresh WG
  server is identified within hours. Raw WG on the wire is not viable.
- Plain SSH is generally reported as throttled/fingerprinted — **but the user has
  primary-source, real-world confirmation that SSH `direct-tcpip` port forwarding
  currently gets through their gateway.** This empirical result outweighs the aggregate
  reports and makes SSH the proven, primary transport for this project.
- VLESS+REALITY (Xray/sing-box) is the 2026 gold standard for Iran but requires
  server-side changes; it is explicitly out of scope for v1 (see Non-goals) and the
  transport layer is designed to accept it later.

Because WG is only safe when wrapped, the app never exposes raw WG on the wire: the WG
transport always rides inside the wstunnel TLS/WebSocket layer.

## Goal / Acceptance

- An Android app that connects to the **existing** TunnelBahn servers (WG+wstunnel on
  443, sshd) using the **existing** TunnelBahn profile format. No server changes.
- Two selectable transports, chosen per profile:
  - **SSH flow forwarding** (`direct-tcpip`) — primary, proven on the target network.
  - **WireGuard-over-wstunnel** (v10 WebSocket) — secondary, carries both TCP and UDP
    flows (so QUIC/HTTP3 is tunneled, not degraded).
- Shared routing layer: **per-app** (allow-list or deny-list by package) and
  **per-destination CIDR** (bulk lists + custom ranges, independent include/exclude
  rule sets per mode), ported from the macOS `DestinationRuleStore` model.
- Verified e2e on-device:
  - SSH profile carries real traffic through the Iranian gateway.
  - **SSH profile in full-tunnel (exclude) mode resolves DNS and carries traffic** — the
    UDP/53-over-a-UDP-dropping-transport case that would otherwise silently fail.
  - WG+wstunnel profile completes a handshake and passes an exit-IP check.
- Unit tests for CIDR classification and the wstunnel v10 frame codec.

## Non-goals (v1)

- **Per-destination domain-name rules.** Deferred; the routing layer is designed to
  accept them later, but v1 routing is CIDR-only. (This is distinct from
  DNS-for-connectivity, which v1 *does* handle — see the DNS Handling section.)
- **REALITY / VLESS / Xray / sing-box protocols and any server-side change.** The user
  has a working transport (SSH); REALITY is added only if/when SSH stops getting
  through. The `Transport` interface leaves room for it without a rewrite.
- **Google Play / F-Droid distribution.** v1 is sideload/personal, so native libs are
  bundled freely and no VPN-policy review applies.
- Kernel WireGuard backend (root). Userspace only.
- Multi-peer WG profiles (single-peer, as on macOS).
- Reverse tunnels, SOCKS/HTTP-proxy inbound, or any wstunnel feature beyond the single
  UDP-forward client path.

## Architecture

Two layers with a strict boundary. Kotlin owns OS integration and policy; a single Go
core owns all packet movement. This mirrors shipping, in-production Android VPN cores
(Firestack, sing-box), so no component is unproven.

```
┌─ Kotlin / Android (app process) ──────────────────────────┐
│  UI (Material 3): profile list, transport picker,         │
│                    app picker, CIDR rule editor           │
│  ProfileStore ── parses existing TunnelBahn profile format│
│  TunnelBahnVpnService (extends VpnService)                │
│     • builds tun fd; per-app allow/deny list              │
│     • coarse addRoute() prefixes                          │
│     • exposes protect(fd) as a gomobile callback          │
│     • starts/stops Go core; surfaces state + stats        │
└───────────────────────┬───────────────────────────────────┘
                        │ gomobile binding
                        │  down: tun fd, config JSON, Protector callback
                        │  up:   connection state, per-transport stats
┌───────────────────────▼─ Go core (libtunnelbahn.aar) ─────┐
│  netstack (gVisor) ── terminates TCP + UDP flows from tun │
│  DNS handler ── intercepts UDP/53, forwards over TCP/53   │
│  Router ── per-flow: tunnel via transport, or direct      │
│            bypass (protect()ed socket)                    │
│  Transport interface { DialTCP; DialUDP (may be unsup.) } │
│    ├─ SSHTransport    x/crypto/ssh direct-tcpip (primary) │
│    │                  DialTCP only; DialUDP unsupported   │
│    └─ WGWSTransport   wireguard-go tnet: DialTCP + DialUDP │
│  Protector (callback into Kotlin VpnService.protect)      │
└────────────────────────────────────────────────────────────┘
```

### Layer responsibilities

**Kotlin owns:**

- `ProfileStore` — reads/writes the existing TunnelBahn profile format (WG keys,
  endpoint, SSH host + user key, wstunnel path, routing rules). **Private keys are never
  in the profile JSON; they are stored encrypted at rest under a Keystore-wrapped AES key
  (EncryptedSharedPreferences / Jetpack Security).** They are *not* held in the Keystore
  directly: Android Keystore has no usable X25519 type and cannot hand the raw
  Curve25519 bytes `wireguard-go` requires, nor sign for `x/crypto/ssh` here (RSA is
  excluded). The macOS build uses the Keychain; this is the equivalent-security Android
  form, not a literal port.
- `TunnelBahnVpnService` (`VpnService`) — builds the tun fd; applies per-app
  `addAllowedApplication` / `addDisallowedApplication`; sets coarse `addRoute()` CIDR
  prefixes; passes the tun fd + a config blob + a `Protector` callback down to Go;
  receives state/stat events back.
- UI (Material 3, functional; power-user tool): profile list, per-profile transport
  picker, per-app selection with include/exclude mode, CIDR rule editor with
  include/exclude modes and bulk-list import.

**Go core owns:**

- netstack tun2socks reading/writing the tun fd, reassembling TCP flows.
- `Router` — classifies each flow and decides tunnel-vs-bypass.
- `Transport` implementations (SSH, WG+wstunnel).
- `Protector` — the single seam back into Android; every outbound socket Go opens
  (SSH connection, wstunnel WebSocket, direct-bypass flows) is `protect()`ed through it.

No packet logic in Kotlin; no Android APIs in Go except `Protector`.

## Routing layer (shared by both transports)

Two-stage filtering — OS-level for apps, Go-level for destinations.

**Per-app (OS level).** `VpnService.Builder.addAllowedApplication()` (include mode) or
`addDisallowedApplication()` (exclude mode). Allow-list OR deny-list per tunnel — the
same either/or the macOS include/exclude app modes already express. Apps outside the
tunnel never reach the tun fd.

**Per-destination CIDR (Go level).** Ported from the macOS `DestinationRuleStore`:

```go
type ModeRuleSet struct {
    CustomRanges []CIDR // custom ranges
    BulkGroups   []CIDR // flattened bulk lists
    // (DomainRules deferred to a later version)
}
// config carries { include: ModeRuleSet, exclude: ModeRuleSet } + active mode
```

The `Router` matches each flow's destination IP against the active mode's flattened
CIDR set:

- **Include mode:** dst in set → tunnel; else → direct bypass.
- **Exclude mode:** dst in set → direct bypass; else → tunnel.

Both modes' rule sets are stored and captured in the profile, independent of each other,
exactly as on macOS.

**How the two filter layers compose (AND semantics).** A packet reaches a transport only
if it passes *both* the OS route table and the Go `Router`. The `addRoute()` prefixes are
the coarse admission filter (what enters the tun at all); the `Router` is authoritative
for tunnel-vs-bypass among admitted flows.

- **Include mode:** `addRoute()` is set to exactly the include CIDRs, so only those flows
  enter the tun. The `Router`'s "else → bypass" branch is therefore unreachable in this
  mode — the OS route already gates it. The Router still runs (uniform code path) but is
  effectively a pass-through here.
- **Exclude mode:** `addRoute()` is `0.0.0.0/0` (everything enters the tun) and the
  `Router` does the real work — dst in the exclude set → bypass, else → tunnel. This is
  the mode where the Router is load-bearing (and where DNS handling below matters).

**Direct bypass.** Flows classified as bypass are dialed on a fresh socket that is
`protect()`ed before connect, so they egress on the underlying network without looping
back into the tun.

## Transports

Both satisfy one interface so the `Router` is transport-agnostic. netstack surfaces both
TCP and UDP flows, so the interface exposes a dial for each. A transport that cannot carry
a protocol returns `ErrUnsupportedProtocol`, and the `Router` drops that flow — an
explicit, visible outcome rather than a silent hang.

```go
var ErrUnsupportedProtocol = errors.New("transport: protocol unsupported")

type Transport interface {
    DialTCP(dst netip.AddrPort) (io.ReadWriteCloser, error)
    DialUDP(dst netip.AddrPort) (net.PacketConn, error) // may return ErrUnsupportedProtocol
    Close() error
}
```

This is flow-level forwarding (TCP + UDP), not raw IP-packet tunneling — ICMP and other
L3 traffic are not carried by either transport. "Full-tunnel" here means *any destination*
can be routed through, not that every IP protocol is tunneled.

### SSHTransport (primary)

- One SSH client connection per active profile; a `direct-tcpip` channel per tunneled
  TCP flow (`ssh.Client.Dial`). This is byte-stream forwarding, not packet tunneling, so
  it avoids the classic TCP-over-TCP meltdown (no inner-retransmit carried over an outer
  retransmit).
- **TCP-only.** `DialUDP` returns `ErrUnsupportedProtocol`; UDP flows are dropped and
  QUIC/HTTP3 clients fall back to TCP. Documented limitation, identical to the macOS SSH
  transport. **Exception: DNS — see the DNS Handling section**, since a dropped UDP/53 in
  full-tunnel mode would otherwise break all name resolution.
- **Auth:** public-key only (ed25519 / ECDSA P-256/384/521; no RSA), reusing the macOS
  key model. Host-key trust is TOFU, pinned on first connect (reuse the
  `SSHHostKeyStore` concept).
- **Resilience (primary transport, gets the hardening budget):** keepalive
  (`SSH_MSG_IGNORE` / server keepalive), bounded exponential-backoff reconnect on drop,
  in-flight flows on a dead connection failed fast rather than hung.

### WGWSTransport (secondary)

- `wireguard-go` in userspace, peer endpoint pointed at a loopback UDP listener.
- A local **UDP ↔ WebSocket relay** implements the wstunnel v10 client wire protocol
  already reverse-engineered for macOS: `GET /<secret-path>/events`, tunnel request in
  the `sec-websocket-protocol` header as `v1, authorization.bearer.<JWT>`, HS256 JWT with
  a random per-run secret (server does not verify the signature), one WebSocket **binary
  frame per UDP datagram**, WS ping/pong keepalive.
- **Frames are sent unmasked.** Go owns the WebSocket writer, so the macOS
  `NWProtocolWebSocket` auto-masking bug (wstunnel does not unmask) cannot recur.
- **Carries both TCP and UDP.** `DialTCP`/`DialUDP` are served by `wireguard-go`'s
  netstack `tnet.Net` (`DialContextTCP` / `DialUDP`), so QUIC/HTTP3 and other UDP flows
  are tunneled, not degraded. This is the concrete reason to keep WG as the secondary
  transport rather than collapsing it into an SSH-like TCP-only path.
- **Inner MTU must absorb the wrapper overhead.** Inner WG rides WS → TLS → TCP, so the
  `wireguard-go` interface MTU is lowered (≈1280, tuned empirically) to leave headroom
  for the WebSocket/TLS/TCP framing; otherwise large packets fragment or blackhole.
- TCP-over-TCP meltdown risk applies (the same server-side BBR configuration used on
  macOS mitigates it).
- WG bytes are never on the wire unwrapped — the endpoint is always the local relay.

### Transport selection

Per profile, exactly as on macOS. The `Transport` interface is the extension point for a
future REALITY transport (added without touching `Router`, routing storage, or UI).

## DNS handling

DNS-for-connectivity is a first-class v1 concern, separate from (deferred) domain-based
routing rules. It is the case that silently breaks otherwise:

- **The failure:** in full-tunnel (exclude) mode `addRoute()` is `0.0.0.0/0`, so app
  DNS queries (UDP/53) enter the tun. The resolver IP is not in the exclude set, so the
  `Router` classifies it as *tunnel*. On the SSH transport `DialUDP` is unsupported →
  the query is dropped → every tunneled app loses name resolution while the UI still
  reads "connected."
- **Why bypass is not the answer:** the target network poisons DNS. Sending queries
  direct to the local resolver (`addDnsServer` + force-bypass) returns forged answers.
  DNS must be resolved *through the tunnel*.

**Design:** the Go core runs a **DNS interceptor** in netstack that captures UDP/53
destined for the tunnel and issues the query over the transport's **`DialTCP` to the
configured upstream resolver on TCP/53** (DNS-over-TCP, RFC 7766), then writes the
response back into the UDP flow. This works uniformly for both transports (both carry
TCP), so SSH full-tunnel resolves correctly and WG does too. The upstream resolver is a
profile field (default: a trusted public resolver reachable from the server side, not the
ISP resolver). DoT/DoH upstreams are a possible later refinement; TCP/53 is sufficient and
simplest for v1.

Bypass-classified flows (exclude mode, dst in set) keep using the system resolver
directly — those are the flows the user chose to leave off the tunnel.

## Data flow

```
app packet
  → tun fd  (per-app filtering already applied by the OS)
  → netstack surfaces the flow (TCP or UDP)
  → is it UDP/53 classified as tunnel?
      └─ yes: DNS interceptor → Transport.DialTCP(resolver:53)  (DoT/TCP, defeats poisoning)
  → Router: match dst IP vs active-mode CIDR set → tunnel | bypass
      ├─ tunnel + TCP: Transport.DialTCP(dst)
      ├─ tunnel + UDP: Transport.DialUDP(dst)   (WG: ok · SSH: ErrUnsupportedProtocol → drop)
      └─ bypass:       protect()ed direct socket
  → server / direct egress
```

## Error handling

- **Transport dial failure** → surfaced to Kotlin as a connection-state event; never a
  silent packet drop.
- **SSH disconnect** → bounded exponential-backoff reconnect; existing flows on the dead
  connection fail fast.
- **`protect()` failure** → logged loudly; this is the loop-risk seam and must be
  visible, not swallowed.
- **Throttle / blackout** (target-network reality) → reported as a "degraded" /
  "no route" state to the user, not hidden behind an apparently-connected UI.

## Testing

- **Go unit tests:** `Router` CIDR classification (include/exclude, boundary cases,
  overlapping ranges); wstunnel v10 frame codec round-trip against captured reference
  bytes.
- **SSH integration test:** `SSHTransport` against a real sshd, verifying a
  `direct-tcpip` flow carries bytes end-to-end.
- **DNS interceptor test:** UDP/53 query in exclude mode is answered via TCP/53 over the
  transport; verify it does not fall through to the (poisoned) system resolver.
- **On-device e2e:** a headless connect/probe driver (mirroring the macOS
  `tunnelbahn://test` URL driver) — SSH profile carries real traffic through the target
  gateway; **SSH full-tunnel (exclude) mode resolves DNS and loads a page**; WG+wstunnel
  profile completes a handshake, tunnels a UDP/QUIC flow, and passes an exit-IP check
  against the existing server.

## Open questions

None blocking. Deferred items (domain rules, REALITY transport, store distribution) are
captured under Non-goals and do not affect the v1 interfaces.
