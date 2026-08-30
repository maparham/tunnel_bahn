# Tunnel Sharing (Phone Relay) — Design

Date: 2026-08-30
Status: Approved (conversation with user, 2026-08-30)

## Problem

When the Android phone is the uplink (Wi-Fi hotspot, USB or Ethernet tethering), traffic
from tethered devices is NATed by Android directly out the upstream interface — it never
enters the phone's tun, so the phone's tunnel does not cover it. The MacBook *can* run its
own TunnelBahn tunnel over the hotspot today (two independent sessions), but that requires
full server credentials on the Mac and opens a second flow through the DPI gateway.

## Goal

Let the Mac's TunnelBahn ride the **phone's existing tunnel session**:

- The Mac keeps its normal capture path (transparent proxy + per-app/per-destination
  routing, unchanged UX) but egresses flows to a **relay listener on the phone** instead of
  a remote server.
- The phone serves those flows by dialing through its already-connected
  `transport.Transport` (SSH or WG+wstunnel).
- Pairing is credential-free for the server: the Mac never holds server keys. A QR code
  shown on the Mac and scanned by the phone (the direction the existing scanner supports)
  establishes a shared secret.

Value (from the brainstorm): zero-config second device, one upstream flow through the DPI
gateway instead of two, shared exit IP, single point of policy on the phone.

## Acceptance

- Mac profile of the new `phoneRelay` transport connects while on the phone's
  hotspot/tether (or any shared LAN) and passes traffic through the phone's active tunnel;
  an exit-IP check on the Mac shows the phone tunnel's exit IP.
- TCP flows work on both phone transports. UDP flows work when the phone runs `wgws`;
  on `ssh` non-DNS UDP is refused (visible flow error, not a hang) — same contract the
  phone applies to its own apps.
- DNS from the Mac resolves through the tunnel on **both** phone transports (served
  phone-side via the existing DNS-over-TCP path).
- Unauthenticated or wrongly-keyed clients are rejected; a MITM on the tether link cannot
  read or splice the relay (TLS + proof bound to the server certificate).
- Phone UI: pair via QR scan, list/revoke paired devices, toggle sharing, see connected
  client count. Mac UI: create a Phone Relay profile, show pairing QR, connect/disconnect
  like any profile.
- Unit tests: wire-codec cross-language golden vectors, handshake proof vectors
  (Go + Swift), share-server flow relay against a fake transport, pairing payload parsing
  (Kotlin), gateway-route parsing (Swift).

## Non-goals (v1)

- iOS-phone-as-host (iOS backgrounding + extension memory cap; Android host only).
- Sharing to more than a handful of clients; no per-client stats or QoS.
- Transparent (no-app) coverage for other client OSes — this feature is Mac-app-to-Android-app.
- mDNS discovery. On hotspot/USB/Ethernet tether the phone **is** the Mac's default
  gateway; discovery = "dial the default gateway on the fixed port", with a manual host
  override field as fallback (also enables same-LAN testing).
- ICMP or raw L3 (flow-level relay, same as the SSH transport's contract).
- Hostname AAAA resolution phone-side (A records only; v1 matches the IPv4-only tun).

## Architecture

```
MacBook                                        Android phone (hotspot)
┌──────────────────────────────┐               ┌─────────────────────────────────┐
│ TransparentProxyExtension    │               │ Go core (libtunnelbahn)         │
│  per-app / per-dst matching  │               │  share.Server                   │
│  TCPFlowRelay / UDPFlowRelay │               │   TLS + tbshare handshake       │
│        │ RelayWireFrame/UDS  │               │   RelayWireFrame over TCP       │
│ PacketTunnelProvider         │   TCP+TLS     │   openFlow → tr.DialTCP/DialUDP │
│  PacketTunnelRelayServer     │  gateway:47600│   UDP/53  → ResolveOverTCP      │
│  PhoneRelayFlowTransport ────┼──────────────►│        │                        │
│  (conforms RelayFlowTransport│               │  transport.Transport (existing, │
│   like SSHFlowTransport)     │               │   SSH or WG+wstunnel session)   │
└──────────────────────────────┘               └───────────┬─────────────────────┘
                                                           ▼ existing carrier
                                                       tunnel server
```

Both reuse points are proven in-tree:

- **Mac:** the SSH path already carries 100% of traffic with *zero* utun routes through
  `TransparentProxyExtension` → UNIX socket → a `RelayFlowTransport`
  (`PacketTunnelProvider.swift:293-297`). `PhoneRelayFlowTransport` is a fourth
  implementation of that protocol; unlike SSH it also implements `openUDP`/`sendUDP`.
- **Phone:** `Session.RunTunnelSpeedTest` and `runExitProbe` already dial through the live
  `transport.Transport` concurrently with the packet path (`session.go:143,192`). The
  share server is another such consumer — it never touches the tun or the (singleton)
  netstack engine.

**No nested tunneling.** Flows are terminated and re-dialed at each hop (Mac proxy flow →
frame stream → phone-side dial). There is no packet-in-packet encapsulation, so the MTU
nesting and TCP-over-TCP meltdown concerns from the brainstorm do not apply.

## Wire protocol

`RelayWireFrame` (Shared/RelayWireFrame.swift), reused byte-for-byte:
`[uint32 length][uint8 type][body]`, big-endian, `length` covers type+body, 1 MiB body cap,
`.malformed` is fatal to the link. Types: `reqOpenFlow 0x01`, `reqSendPayload 0x02`,
`reqCloseFlow 0x03` (Mac→phone); `repOpenFlow 0x81`, `pushDeliver 0x82`,
`pushFlowClosed 0x83` (phone→Mac). `reqOpenFlow` carries hostname or IP-literal + port +
isTCP. A Go port (`android/core/relaywire`) is pinned to the Swift implementation by
shared golden test vectors.

UDP flows: one `sendPayload`/`deliver` frame per datagram (datagrams ≤ 64 KiB always fit
under the 1 MiB chunking threshold, so chunking never splits a datagram).

## Pairing and authentication ("tbshare v1")

**Pairing:** the Mac generates `peerID` (16 random bytes) + `secret` (32 random bytes),
stores the secret in the Keychain, and shows a QR:

```json
{"kind":"tunnelbahn.pair","v":1,"id":"<peerID hex>","secret":"<secret hex>",
 "name":"<Mac name>","port":47600}
```

The phone scans it (existing ZXing scanner) and persists the peer in
EncryptedSharedPreferences. Direction matches the hardware: the Mac has no camera pointed
at a phone screen; the phone already scans Mac-rendered QRs (`AndroidProfileQRCodec`).

**Connection handshake** (after TLS is established; all fields fixed-size, big-endian):

1. Mac → phone: `"TBSH"` (4) ‖ version `0x01` ‖ peerID (16) ‖ clientNonce (32)
2. phone → Mac: serverNonce (32) ‖ serverProof (32) where
   `serverProof = HMAC-SHA256(secret, "tbshare-server" ‖ clientNonce ‖ serverNonce ‖ SHA256(serverCertDER))`
3. Mac verifies serverProof against the certificate it *observed* in the TLS handshake,
   then sends `clientProof (32) = HMAC-SHA256(secret, "tbshare-client" ‖ serverNonce ‖ clientNonce)`
4. phone verifies, replies status `0x01`, and both switch to `RelayWireFrame` frames.

TLS uses a phone-side self-signed ECDSA P-256 certificate, generated fresh per share
session (no cert persistence needed): the Mac does not verify the chain, it verifies the
**proof binding** — a MITM presenting its own certificate to the Mac cannot produce a
serverProof covering that certificate without the secret, and nonces prevent replay.
Unknown peerID or bad clientProof: the phone closes without a distinguishing response.
Handshake deadline 10 s.

The listener binds `0.0.0.0:47600` (tether interface names are OEM-soup; auth is the
gate) with the existing `protectedControl` socket hook, and the app's own package is
already excluded from the tun by `PerAppRules` — belt and braces against loops.

## Phone-side flow serving

Per authenticated connection, a flow table keyed by the Mac's `flowID`:

- `openFlow` TCP → resolve host if not an IP literal (A-record query built with
  `x/net/dns/dnsmessage`, sent through the existing `ResolveOverTCP` path against the
  session's configured resolver) → `tr.DialTCP` → `repOpenFlow ok` → pump conn reads into
  `pushDeliver`, `reqSendPayload` into conn writes, EOF/error → `pushFlowClosed`.
- `openFlow` UDP to port 53 (any destination) → a DNS flow: each datagram is one query
  answered via `ResolveOverTCP` — this is what makes Mac DNS work when the phone runs the
  TCP-only SSH transport.
- `openFlow` UDP other → `tr.DialUDP` (wgws serves it; ssh returns
  `ErrUnsupportedProtocol` → `repOpenFlow ok=false` with the error string — the Mac's
  `UDPFlowRelay` drops the flow visibly, matching phone-local behavior).
- Relayed bytes are wrapped by the existing `counters` so they appear in session Rx/Tx.

## Mac-side transport

`PhoneRelayFlowTransport: RelayFlowTransport` in the packet-tunnel extension:
`NWConnection` TCP+TLS with a verify block that accepts any certificate but captures its
DER for the proof check; handshake logic lives in `Shared/` (unit-testable, CryptoKit);
frame encode/decode reuses `RelayWireFrame` directly. Reconnect loop with bounded backoff
modeled on `SSHFlowTransport`; while down, `sendTCP` returns `.transient` and open flows
are failed fast (fail-closed for matched apps, same as SSH).

Endpoint resolution: the app resolves the default IPv4 gateway via a `PF_ROUTE` sysctl
(`Shared/DefaultGatewayResolver.swift`) at connect time — on hotspot/USB/Ethernet tether
the gateway *is* the phone — and passes it in `TunnelRuntimeState` (mirroring how SSH
secrets and pre-resolved WG endpoints travel). A manual host override field covers
same-LAN testing and exotic setups. Loop safety on the Mac needs no new code: per-app
`sourceApplication` matching never captures extension-owned sockets, and
`excludeLocalNetworks = true` is already set on every `includeAllNetworks` branch.

## Profile & runtime plumbing (Mac)

`TransportKind.phoneRelay`; `PhoneRelayProfile { port, manualHost, peerIDHex, secretRef }`
as `WireGuardProfile.phoneRelay` (optional field, same back-compat decoding pattern as
`tcpWrapper`); `TunnelPhoneRelayParams { host, port, peerIDHex, secretHex }` on
`TunnelRuntimeState` (secret resolved app-side — the root extension cannot read the user
Keychain); a `startPhoneRelay` case in `PacketTunnelProvider.startTunnel` mirroring
`startSSH` (minimal network settings, `PacketTunnelRelayServer` over the new transport).

## Lifecycle

- Phone: sharing is a persisted toggle. When ON and the session reaches `running`, the
  service calls `Session.StartShare`; on session stop (or toggle OFF) `StopShare` closes
  the listener and all relayed flows.
- Mac: relay connection drop → transport reconnect loop; flows on the dead link fail
  fast; UI shows reconnecting via existing state plumbing. Matched apps fail closed while
  the relay is down.
- Phone UI polls `Session.ShareClientCount()` for "N device(s) connected".

## Error handling

- Handshake failure/timeout phone-side: close, log via existing `logf`; never crash the
  session. Mac-side: surfaced as transport start failure → tunnel start error.
- `.malformed` frame on either side: tear down the link (poisoned stream, per
  `RelayWireFrame`'s contract); Mac reconnects.
- Phone transport dial errors propagate as `repOpenFlow ok=false` / `pushFlowClosed` with
  the error string — never a silent drop.

## Testing

- **Golden vectors** (hex fixtures in both repos' tests) pin the Go codec to the Swift
  codec, and the Go proofs to the Swift proofs (vectors generated once with python3
  hmac/hashlib during implementation).
- **Go:** `share.Server` end-to-end over a real TLS loopback listener with a fake
  `transport.Transport` (echo server), covering TCP relay, UDP refusal on
  `ErrUnsupportedProtocol`, DNS flow, auth rejection, malformed-frame teardown.
- **Kotlin:** pairing payload parse (model: `QRImportTest`), peer store round-trip
  (Robolectric, model: `ProfileStoreTest`).
- **Swift:** handshake proof + QR payload codec tests; gateway route-message parser test
  with a captured fixture.
- **On-device e2e checklist** (separate doc): Mac on phone hotspot, phone on SSH then
  wgws, exit-IP parity, DNS, UDP behavior per transport, revoke-while-connected,
  phone-session-restart reconnect.

## Open questions

None blocking. Deferred: multi-client stats, AAAA resolution, iOS host, mDNS discovery.
