# Android Plain WireGuard Transport Design

**Date:** 2026-09-16
**Status:** Proposed
**Context:** The Android client carries WireGuard only inside a wstunnel WebSocket relay (`wgws`). The macOS app refuses to export a plain WireGuard profile to Android ("This profile has no Android-compatible transport"), so a profile such as the user's AWS server, which has no TCP wrapper, cannot be used on the phone. The Android client design (2026-08-02) stated "the app never exposes raw WG on the wire" because raw WireGuard is fingerprinted on the target network. That principle is now relaxed: the app mirrors TunnelBahn's primary function, WireGuard tunneling, and the user chooses per profile whether to wrap it.

## Goal

Add a third Android transport, plain UDP WireGuard (`wg`), that connects to the same server a macOS plain-WireGuard profile does, importable by QR from macOS and creatable by hand in the Android editor.

## Decisions

- **Both entry points.** The editor gains a third "WireGuard" transport with an endpoint field, and QR import accepts `"transport":"wg"`.
- **Liveness is a handshake-age watchdog.** Plain UDP has no carrier connection to observe, so the transport polls wireguard-go's `last_handshake_time_sec`. With a 25 s persistent keepalive, wireguard-go rekeys at least every 2 minutes while traffic flows; no handshake for 180 s means the server is unreachable. The transport then reports `degraded` (UI shows "Reconnecting"), and reports `running` again when a fresh handshake lands. This matches the SSH and wgws carrier semantics without inventing a new state.
- **Single, connected, protected UDP socket.** The transport dials the peer endpoint once with the existing protected dialer (`VpnService.protect`) so WireGuard's own packets never loop into the tunnel. A custom `conn.Bind` wraps that socket, mirroring the existing `relayBind`, so no Android-specific wireguard-go socket hooks are needed. Endpoint roaming is not supported; a server IP change requires a reconnect, which is the same behaviour as the other transports.
- **Hostname endpoints resolve outside the tunnel.** `Dial("udp", host:port)` resolves through the protected dialer; the resolved `RemoteAddr()` is what wireguard-go's uapi `endpoint=` receives, since uapi requires an IP.
- **Keepalive comes from the profile.** The QR carries the macOS peer's `persistentKeepalive`; absent or zero, both sides use 25, the value `wgws` already hard-codes.
- **Old Android builds fail loudly, not silently.** A pre-existing app scanning a `wg` QR shows "Unknown transport in QR code." No compatibility shim.
- **macOS keeps preferring the wrapper.** A profile with an enabled TCP wrapper still exports as `wgws`; only a WireGuard profile with no enabled wrapper exports as `wg`.

## Non-goals

- Multiple peers, endpoint roaming, or IPv6-only endpoints beyond what `net.Dial` already handles.
- Obfuscation of plain WireGuard. If the network blocks it, the user picks `wgws` or SSH.
- Changing the routing, DNS, per-app, or exit-probe layers. They already work over the `Transport` interface.

## Payload and config format

The QR `wg` object gains two fields. All other fields are unchanged; the wstunnel fields are omitted for `wg` (the Kotlin parser defaults them to empty).

```json
{
  "kind": "tunnelbahn.profile",
  "name": "AWS",
  "transport": "wg",
  "wg": {
    "privateKey": "...", "peerPublicKey": "...", "presharedKey": "",
    "localAddrs": ["10.9.0.2"], "dns": ["1.1.1.1"], "mtu": 1280,
    "endpoint": "3.139.146.5:51820",
    "keepalive": 25
  }
}
```

The Kotlin-to-core config JSON (`Profile.toCoreConfigJson`) mirrors this: `"transport":"wg"` and the same two fields inside `"wg"`. `parseConfig` accepts `"wg"` and rejects it when `endpoint` is empty.

## Architecture

### Go core (`android/core`)

**`transport/wg_device.go` (new, extracted from `wgws.go`).** The parts of `NewWGWS` that are not relay-specific move here so both transports share them:

- `newWGDevice(cfg WGConfig, bind conn.Bind, endpoint string) (*device.Device, *netstack.Net, error)`: creates the netstack TUN, the device, applies uapi, brings it up, and cleans up on any failure.
- `uapiConfig(cfg WGConfig, endpoint string, keepalive int) (string, error)`: as today, with the endpoint and keepalive parameterised. `wgws` passes its cosmetic `127.0.0.1:51820` and 25.
- `handshakeAge(dev *device.Device) (time.Duration, bool)`: reads `last_handshake_time_sec`; `ok` is false until the first handshake. Replaces `handshakeComplete`.
- `waitHandshake(ctx, dev, dialErr func() error) error`: the polling loop that `WGWS.WaitReady` uses today, with the fast-fail hook passed in.

`WGConfig` gains `Keepalive int` (0 means 25). `wgws.go` shrinks to the relay bind plus a thin `WGWS` that calls the shared helpers. Behaviour of `wgws` does not change; its existing tests must still pass unmodified.

**`transport/wg.go` (new).**

- `udpBind`: a `conn.Bind` over one `net.Conn`. `Open` returns a receive fn that calls `Read` into `packets[0]`; `Send` writes each buffer; `Close` closes the conn and makes the receive fn return `net.ErrClosed`. Like `relayBind`, it tolerates wireguard-go's Close-then-Open cycle on `Up` by reopening a fresh `closed` channel. `BatchSize` is 1. `ParseEndpoint` returns a stub endpoint; the socket is connected so the endpoint is cosmetic.
- `NewWG(ctx, cfg WGConfig, endpoint string, dial DialFunc, onState func(bool)) (*WG, error)`: dials `udp` to `endpoint` via `dial`, builds the device with `udpBind` and `conn.RemoteAddr().String()` as the uapi endpoint, and starts the watchdog goroutine.
- `WaitReady`: `waitHandshake` with no dial error hook. A UDP dial to an unreachable network fails synchronously in `NewWG`, so the fast-fail case is already covered at construction; a silently blackholed server times out at the session's existing connect deadline.
- **Watchdog.** A goroutine ticks every 5 s: if `handshakeAge > 180s` and state is up, call `onState(false)`; if a handshake is fresh and state is down, call `onState(true)`. It never fires before the first handshake (WaitReady owns that phase) and exits on `Close`. The threshold and tick are package constants so the test can shorten them via an unexported hook (`newWGWithClock`), the same way `ssh_reconnect_test.go` drives timing.
- `DialTCP`, `DialUDP`, `Close`: identical to `WGWS`, minus the relay.

**`config.go`.** `wgParams` gains `Endpoint string` and `Keepalive int`. `parseConfig` accepts `"wg"` and errors with `config: wg endpoint required` when `Endpoint` is empty for that transport.

**`session.go`.** `buildTransport` gains a `case "wg"` that logs `connect: wg dial <endpoint>`, and passes an `onState` closure identical to the wgws one (`logCarrier("wg", …)`, then `sink.OnState("running"/"degraded")`).

### Kotlin app (`android/app`)

- `Transport` enum gains `WG`. `Profile` gains `wgEndpoint: String = ""` and `wgKeepalive: Int = 25`. `toCoreConfigJson` maps the enum to `"ssh" | "wgws" | "wg"` and emits both new fields in the `wg` block. Existing persisted profiles deserialize unchanged because both fields have defaults.
- `QRImport.kt`: `QRWg` gains `endpoint` and `keepalive` (defaults `""` and 25). A `"wg"` branch mirrors `"wgws"` and additionally requires a non-empty `endpoint` ("QR is missing the WireGuard endpoint.").
- `ProfileEditor.kt`: the transport row becomes three radios: "SSH", "WireGuard", "WG over TCP". `WgFields` takes the transport and shows an "Endpoint (host:port)" field for `WG` instead of the wstunnel URL field. Keepalive is not exposed in the editor; the default 25 is fine and the QR carries the macOS value.
- Any place that switches on `Transport` for display (the `when` in `ProfileEditor` and any summary strings) handles `WG`. Kotlin's exhaustive `when` on the enum surfaces every site at compile time.

### macOS app (`TunnelBahn`)

- `AndroidProfileQRPayload.WG` gains `endpoint: String` and `keepalive: Int`; the wstunnel fields become optional so `wg` omits them from the JSON (the `Encodable` conformance already skips `nil`).
- `AndroidProfileQRCodec.encode` ordering: SSH; else wrapper enabled and a peer exists, `wgws`; else a peer exists with a non-empty endpoint, `wg` with `peer.endpoint` and `peer.persistentKeepalive ?? 25`; else throw. The `noAndroidTransport` error is renamed `noPeer` with the text "This profile has no peer endpoint to export."
- `ProfilesView.showAndroidQRPanel`: the error text gets `.fixedSize(horizontal: false, vertical: true)` and a fixed width so it wraps instead of truncating. The "Export to Android (QR)" menu item stays always enabled, since every well-formed profile can now export.
- The 2026-08-02 Android client design's "never exposes raw WG on the wire" paragraph gets a dated note pointing at this spec.

## Data flow (connect, `wg`)

1. Kotlin builds config JSON with `transport:"wg"` and `wg.endpoint`, hands it to `Session.Start`.
2. `parseConfig` validates; `buildTransport` dials UDP through the protected dialer, builds the device, and the peer's keepalive triggers the first handshake initiation.
3. `WaitReady` polls until the first handshake or the connect deadline, then the engine starts and the UI shows Connected.
4. The watchdog reports `degraded` if handshakes stop for 180 s and `running` when they resume.
5. `Close` stops the watchdog, closes the device, and closes the socket.

## Error handling

| Failure | Where | Surfaces as |
|---|---|---|
| Empty endpoint | `parseConfig` / QR import | "wg endpoint required" / "QR is missing the WireGuard endpoint." |
| Unresolvable host or no network | `NewWG` dial | "build transport: wg dial …" via the existing connect failure path |
| Server silent (wrong key, port filtered) | `WaitReady` | "server not reachable: context deadline exceeded" at the connect deadline |
| Server dies mid-session | watchdog | `degraded` → "Reconnecting"; back to `running` on recovery |
| Bad key material | `uapiConfig` | existing "private key / peer public key" errors |

## Testing

**Go (`android/core`).** Note: the module declares Go 1.26.3, the machine has 1.25.3, and the toolchain download is blocked from the agent sandbox; tests run with `GOTOOLCHAIN=local` if the code compiles on 1.25, otherwise the download must be allowed once.

- `udpBind`: a loopback UDP echo server; `Send` then the receive fn returns the echoed datagram; after `Close` the receive fn returns `net.ErrClosed`; Close-then-Open cycle works.
- `uapiConfig`: emits the given endpoint and keepalive; wgws output is byte-identical to before.
- `parseConfig`: accepts `"wg"` with an endpoint, rejects it without.
- Watchdog: with a fake handshake-age source and shortened constants, the state callback fires `false` when the age crosses the threshold and `true` when it drops, and never fires before the first handshake.
- `NewWG` against an unreachable address fails at construction, not at `WaitReady`.
- Existing `wgws_*` tests pass unmodified after the extraction.

**Kotlin (`android/app` unit tests).** `QRImportTest` gains `wg` success and missing-endpoint cases. `ProfileStoreTest` or a new test asserts `toCoreConfigJson` emits `"transport":"wg"` with the endpoint.

**Swift (`Tests/Unit/AndroidProfileQRCodecTests.swift`).** Plain WireGuard profile encodes as `wg` with the peer endpoint and keepalive and no wstunnel keys; wrapper-enabled still encodes as `wgws`; no peers throws `noPeer`.

**Manual.** Scan the AWS QR on the phone, connect, pass the exit-IP check; kill the server's WireGuard for four minutes and confirm the UI shows Reconnecting, then Connected after restart.
