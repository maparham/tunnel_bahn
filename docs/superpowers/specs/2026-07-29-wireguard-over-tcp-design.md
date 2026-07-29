# WireGuard-over-TCP (wstunnel v10-compatible obfuscation sub-mode)

**Status:** Design approved 2026-07-29
**Author:** brainstorming session
**Related precedents:** SSH transport (`docs/superpowers/specs/2026-07-23-ssh-transport-design.md`), BoringTun FFI bridge (`BORINGTUN_INTEGRATION.md`)

## Problem

WireGuard is UDP-only. Some networks (captive portals, censored ISPs) silently drop all
outbound UDP, so the WG handshake never lands. The fix — validated by hand against our
server — is to carry WG's encapsulated UDP packets inside a TCP/TLS WebSocket connection
to a server-side unwrapper (`wstunnel`), which forwards them to a normal WireGuard
listener. This design makes that a first-class, in-app feature.

## Goal / Acceptance

- A WireGuard profile with TCP-wrapper mode enabled connects through
  `wss://3.139.146.5:443` + the secret path and completes a WG handshake, verified by an
  exit-IP check showing `3.139.146.5` — reproducing `~/Downloads/AWS-over-tcp.conf`
  manually run alongside the reference `wstunnel` CLI.
- Plain (unwrapped) WireGuard and the SSH transport are byte-for-byte unchanged.
- Parser/renderer round-trip + unit tests for the new config fields.
- README/CHANGELOG updated describing the new mode and its limitations.

## Non-goals

- Reverse tunnels, TCP-over-wstunnel, SOCKS/HTTP-proxy modes, or any wstunnel feature
  beyond the single UDP-forward client path.
- Multi-peer wrapped profiles (the app is already single-peer).
- Interop with wstunnel HTTP/2 transport (v10 WebSocket transport only).

## Ground truth (verified, not from memory)

Captured against the live reference server and confirmed in `erebe/wstunnel` v10.6.2 source.

### wstunnel v10 UDP-over-WebSocket wire protocol

The client's UDP tunnel is **lazy**: it dials the WebSocket only on the first inbound UDP
datagram. The upgrade request (captured byte-for-byte via a local plaintext listener):

```
GET /tun74fd08a683078a3e0439/events HTTP/1.1
host: <server host:port>
upgrade: websocket
connection: upgrade
sec-websocket-key: <random>
sec-websocket-version: 13
sec-websocket-protocol: v1, authorization.bearer.<JWT>
```

- **Path:** `/<secret-path-prefix>/events`.
- **Tunnel request** rides in the `sec-websocket-protocol` header as
  `v1, authorization.bearer.<JWT>`.
- **JWT:** header `{"typ":"JWT","alg":"HS256"}`; claims
  `{"id":"<uuid v7>","p":{"Udp":{"timeout":{"secs":30,"nanos":0}}},"r":"<forward-host>","rp":<forward-port>}`.
  - `r`/`rp` = the **server-side** forward target the unwrapper hands UDP to
    (`127.0.0.1:51840` in the reference — the WG listener behind nginx). This is the
    `remote` half of the reference CLI's `-L 'udp://127.0.0.1:51840:127.0.0.1:51840'`.
  - **Signature is not verified by the server** — `wstunnel/src/tunnel/transport/jwt.rs`
    decodes with `jsonwebtoken::dangerous::insecure_decode`, and the client itself signs
    with a random per-run secret (system-time nanos). **There is no shared secret to
    reproduce**; any HS256 signature bytes are accepted.
- **After the 101:** each UDP datagram is sent as exactly **one WebSocket binary frame**
  (raw bytes, no length prefix); return path identical. WebSocket **ping/pong keepalive**
  is used (`Frame::binary(...)` write path in `tunnel/transport/websocket.rs`).

### App integration points

- `BoringTunAdapter.swift:227` derives its `NWHostEndpoint` straight from
  `peer.endpoint` via `endpointToken(...)`. Repointing WG at a local relay is therefore a
  single new optional parameter, not a data-plane rewrite.
- `TunnelRuntimeState.profile` already carries the full `WireGuardProfile` to the
  extension, so a wrapper struct on the profile travels for free — no new runtime-state
  field, unlike SSH (which needed the out-of-keychain PEM in `TunnelSSHParams`).
- The wrapper carries **no secrets** (the path prefix is low-sensitivity), so no Keychain
  round-trip is required.

## Design decisions (settled in brainstorming)

1. **Obfuscation sub-mode, not a new `TransportKind`.** The entire WG data plane —
   BoringTun, keys, handshake, utun, smoltcp relay, per-app routing — is unchanged; only
   the encapsulated UDP's carrier changes. A third transport case would force a
   near-duplicate `startWireGuard`.
2. **Reimplement the relay in Swift / Network.framework**, not embed the wstunnel Rust
   crate. The protocol is small and now captured exactly, and the server doesn't verify
   the JWT, so there is no shared secret to track. Embedding would add
   tokio+hyper+fastwebsockets+rustls+aws-lc-rs and a second async runtime to the NE, and
   would vendor non-public-API internal client modules.
3. **Local loopback UDP socket** feeds BoringTun (not an in-process shunt). The relay
   listens on `127.0.0.1:<port>` and WG's effective endpoint is rewritten to it — exactly
   what the reference `.conf` does. BoringTun sees an ordinary endpoint; the data plane is
   literally untouched, which is what makes "plain WG unchanged" defensible.

## Architecture

### Model — `WireGuardTCPWrapper`

```swift
struct WireGuardTCPWrapper: Codable, Hashable {
    var serverHost: String     // 3.139.146.5  — TLS/WebSocket connect target
    var serverPort: UInt16     // 443
    var tls: Bool              // default true (wss); false = ws
    var verifyCert: Bool       // default false — wstunnel default; server cert won't match a bare IP
    var pathPrefix: String     // tun74fd08a683078a3e0439 (no leading/trailing slash)
    var forwardHost: String    // 127.0.0.1 — server-side WG listener (JWT "r")
    var forwardPort: UInt16    // 51840      (JWT "rp")
}
```

Added to `WireGuardProfile`:
- `var tcpWrapper: WireGuardTCPWrapper?` (nil = plain WG, unchanged behavior).
- **`tcpWrapper` MUST be added to the `CodingKeys` enum** in `WireGuardProfile.swift`. The
  file's own comment (lines 72–79) warns that a stored property missing from `CodingKeys`
  is silently dropped from persistence — the round-trip test asserts against exactly this.
- The defaulting `init(from:)` decodes it with `decodeIfPresent(...)` so pre-existing
  profiles (no key on disk) load as `nil`.
- `transport` stays `.wireguard`. No `TransportKind` change.

### Relay — `WGTCPWrapperRelay` (NetworkExtension, in-process)

A focused component (~200 lines) with one job: bridge a local UDP socket to a
wstunnel-v10 WebSocket. Single unit, testable against a mock WS server.

Responsibilities:
- Bind a UDP socket on `127.0.0.1:0` (kernel-assigned ephemeral port); expose the chosen
  port so the provider can repoint BoringTun.
- Open **one** `NWConnection` to `serverHost:serverPort`:
  - `NWProtocolTLS` when `tls == true`; when `verifyCert == false`, install a
    `sec_protocol_options_set_verify_block` that accepts the presented chain. (Pinning is
    a future extension; v1 mirrors wstunnel's skip-verify default.)
  - `NWProtocolWebSocket` (client) with request path `/<pathPrefix>/events` and
    subprotocol list `["v1", "authorization.bearer.<JWT>"]`.
- **JWT builder** (own small type + test): base64url(header).base64url(claims).base64url(HMAC-SHA256).
  `id` = a fresh UUID (v7 preferred; any UUID is accepted since the server ignores it
  beyond logging), `p` = `{"Udp":{"timeout":{"secs":30,"nanos":0}}}`, `r`/`rp` from the
  wrapper's forward target. Signing key = locally-generated random bytes.
- Datagram pump: UDP recv → WS binary frame; WS binary frame → UDP send back to BoringTun's
  source. Reply to WS pings with pongs. Surface fatal WS/TLS errors so the provider can
  fail `startTunnel` cleanly.

Connection timing: to match wstunnel's lazy dial and keep the WG handshake retrying, the
relay may dial the WS on first inbound datagram OR eagerly on start — v1 dials eagerly on
`start()` so connect/TLS failures surface immediately at `startTunnel` (cleaner UX than a
silent stall). BoringTun's `PersistentKeepalive`/handshake retries drive datagrams either
way.

**Transport chosen: `URLSessionWebSocketTask`, validated against the live server
(spike, 2026-07-29).** A `URLSessionWebSocketTask` opened to
`wss://3.139.146.5:443/tun74fd08a683078a3e0439/events` with
`protocols: ["v1", "authorization.bearer.<jwt>"]` and the cert-skip delegate completes the
handshake: HTTP `101`, `Sec-WebSocket-Accept` returned, server selects subprotocol `"v1"`
(accepted by URLSession). URLSession is therefore wire-compatible with wstunnel v10 without
`NWProtocolWebSocket`, whose arbitrary-path/header control is more limited. Two facts the
spike established, reflected in the plan: (1) **readiness is the `didOpenWithProtocol`
delegate, not `sendPing`** — the spike's ping never got a pong even though the tunnel was
up, so gating on a ping would fail a working tunnel; (2) **the relay sends no client pings**
— WireGuard's `PersistentKeepalive` (25s in the reference) keeps datagrams and the socket
alive, and URLSession auto-answers inbound server pings.

### Wiring — `PacketTunnelProvider.startWireGuard`

When `runtime.profile.tcpWrapper != nil`:
1. Construct `WGTCPWrapperRelay` from the wrapper struct; call `start()`.
2. Read its bound local port.
3. Pass `effectiveEndpointOverride = "127.0.0.1:<port>"` into
   `BoringTunAdapter.start(...)` (new optional param, defaults nil → current behavior).
   The adapter uses the override in place of `peer.endpoint` at
   `BoringTunAdapter.swift:227`; **all** downstream logic (handshake, smoltcp, utun,
   routing, stats) is the existing path.
4. Retain the relay for `stopTunnel`/teardown symmetry (mirror the SSH `teardown` shape).

Plain WG (`tcpWrapper == nil`) and SSH paths are untouched.

### Loop guard

No new route pin. Add a verify-and-assert comment mirroring the SSH self-loop invariant
(`PacketTunnelProvider.swift:117-121`): the relay's outbound TCP originates from **this**
packet-tunnel extension process, which is **not** one of the per-app-routed matched apps,
so it exits over the physical interface and cannot recurse into its own tunnel. The
reference `.conf` needs `route add -host <server> <gw>` only because `wg-quick` installs a
system-wide default route; TunnelBahn's per-app routing (`forPerAppVPN` /
`sourceApplication`) never captures the extension's own sockets. If the relay ever fails
to connect under full-tunnel, this assumption is the first suspect.

### Config surface — parse / render

`.conf` encoding: a dedicated **`[TCPWrapper]`** section (TunnelBahn extension). The
existing `parseSections` already handles arbitrary sections, and the renderer already
emits Address/DNS/MTU separately from the strict `wg setconf` config — so the wrapper
section is stripped before any `wg setconf` and never reaches the WG backend.

```
[TCPWrapper]
Server = 3.139.146.5:443
TLS = true
VerifyCert = false
PathPrefix = tun74fd08a683078a3e0439
Forward = 127.0.0.1:51840
```

- Parser: if `[TCPWrapper]` present, build `WireGuardTCPWrapper`; set `tcpWrapper` on the
  profile. Missing/blank required keys → a clear `WireGuardConfigParserError.invalidConfig`.
- When `tcpWrapper` is present, the authored `[Peer] Endpoint` is **advisory** — the
  runtime overrides it with the local relay address — so import does not persist a bogus
  `127.0.0.1` peer endpoint as meaningful. (The peer endpoint field still exists in the
  model; it is simply overridden at connect time.)
- Renderer: emit the `[TCPWrapper]` section for the full-config/QR export path
  (`renderFullConfigString`) when `tcpWrapper != nil`. The strict `wg setconf` render path
  (`render`) never emits it.

### UI — profile editor

Add a **"TCP wrapper (WebSocket/TLS)"** toggle in the WireGuard profile editor. When on,
reveal the six fields: Server host, Server port (default 443), TLS toggle (default on),
Verify certificate toggle (default off, with a short caption that off matches
`wstunnel` and is required for the bare-IP reference server), Secret path prefix, Forward
target host:port (default `127.0.0.1:51840`). Off → `tcpWrapper = nil`.

## Error handling

- Relay connect/TLS/WS-upgrade failure → thrown from `start()`, aborts `startTunnel` with a
  descriptive `[APPSPLIT_WGTCP]`-prefixed error (matches SSH log conventions).
- WS drop mid-session → relay logs and stops feeding; provider treats it like a transport
  loss. (v1: no auto-reconnect of the WS beyond BoringTun's own retry pressure; noted as a
  limitation. A reconnect loop is a follow-up.)
- Malformed wrapper config (missing prefix/forward) → parser error at import; editor
  validates before save.

## Testing

1. **Parser/renderer round-trip** (`WireGuardConfigParser` / `WireGuardConfigRenderer`):
   a `[TCPWrapper]` config parses to the expected struct and re-renders identically;
   assert the profile **JSON `Codable` round-trip preserves `tcpWrapper`** (guards the
   `CodingKeys` hazard — a profile encoded then decoded must retain the wrapper).
2. **JWT builder unit test:** decode the produced token's header + claims and assert they
   match the captured reference shape (`alg HS256`, `p.Udp.timeout.secs == 30`, `r`/`rp`
   equal the forward target). Signature bytes are not asserted (server ignores them).
3. **Relay unit test** against an in-process mock WebSocket server: assert the request path
   is `/<prefix>/events`, the `authorization.bearer.<jwt>` subprotocol is present, and a
   datagram written to the local UDP socket arrives as a single binary frame (and the
   reverse).
4. **Manual acceptance:** import a wrapped profile targeting `3.139.146.5:443` +
   `tun74fd08a683078a3e0439`, connect a routed app, run
   `curl https://1.1.1.1/cdn-cgi/trace` and confirm `ip=3.139.146.5`; `wg show` on the
   server shows a recent handshake.

## Documentation

- **README:** a "WireGuard-over-TCP (WebSocket/TLS wrapper)" subsection under the WG
  transport, describing when to use it (UDP-blocked networks), the config fields, and
  limitations: single WebSocket connection (head-of-line blocking under load), cert
  verification off by default, no WS auto-reconnect in v1, WebSocket-transport only (not
  HTTP/2), wire-compatible with `wstunnel` v10 servers.
- **CHANGELOG:** new entry under the current unreleased section.

## Rollout / risk notes

- The reference server's TLS cert is a Cloudflare **origin** cert that won't validate
  against the bare IP — `verifyCert` defaults off for this reason. Document that turning it
  on requires a hostname + matching cert.
- The `~/Downloads/AWS-over-tcp.conf` private key is live and must be rotated after
  integration testing (out of scope for the code change; flagged for the operator).
- Binary size / dependencies: **zero** new third-party deps — Network.framework and
  CryptoKit (HMAC-SHA256) are system frameworks.
