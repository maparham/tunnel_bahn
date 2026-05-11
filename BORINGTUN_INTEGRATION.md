# BoringTun Integration (Current Architecture)

## Summary

`PacketTunnelExtension` uses **BoringTun** as the WireGuard backend.
The previous WireGuardKit/wireguard-go backend was removed for per-app compatibility.

## Data Plane

Per-app routing (`sourceApplication`) sends app packets to `NEPacketTunnelFlow`.

`BoringTunAdapter` does:
1. `packetFlow.readPackets` (plaintext IP packets from macOS)
2. `tunnelbahn_wg_write` (encapsulate with BoringTun)
3. `NWUDPSession.writeDatagram` (send encrypted UDP to peer)
4. `NWUDPSession.setReadHandler` (receive encrypted UDP)
5. `tunnelbahn_wg_read` (decapsulate)
6. `packetFlow.writePackets` (inject plaintext IP back to stack)

## Components

- Swift adapter: `NetworkExtension/BoringTunAdapter.swift`
- Provider entry: `NetworkExtension/PacketTunnelProvider.swift`
- C header for bridge ABI: `NetworkExtension/tunnelbahn_wg_ffi.h`
- Rust bridge crate: `BoringTunBridge/src/lib.rs`
- Rust dependency: `boringtun` with FFI bindings

## Build Integration

- `PacketTunnelExtension` has a build phase that compiles Rust and produces:
  - `BoringTunBridge/out/libboringtun_bridge.a`
- Xcode links that static library into the extension target.
- Bridging header:
  - `NetworkExtension/PacketTunnelExtension-Bridging-Header.h`

## Known Important Settings

- `ENABLE_USER_SCRIPT_SANDBOXING = NO` for `PacketTunnelExtension` (Debug/Release), so Cargo can access `BoringTunBridge/target` and `Cargo.lock`.
- Project-level script sandboxing can remain enabled for the app target.

## Stability / DNS Notes

- Per-app mode now **keeps profile DNS servers** (no forced DNS clearing).
- Packet processing is serialized on `packetQueue` to avoid concurrent access to BoringTun state and scratch buffers.

## Quick Verify

1. Build `PacketTunnelExtension`.
2. Connect in per-app mode with Chrome/Terminal selected.
3. In selected app:
   - IP works: `curl http://1.1.1.1`
   - DNS works: `curl -I https://example.com`
