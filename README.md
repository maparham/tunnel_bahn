# TunnelBahn

TunnelBahn is a native macOS app for WireGuard per-application split tunneling.

## Local-machine development

This project is designed for your machine-first workflow. Homebrew dependencies are expected:

```bash
brew install xcodegen wireguard-tools swiftformat
```

Rust is required to build the BoringTun bridge library (built automatically by Xcode on first build):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

## Generate project

```bash
xcodegen generate
open TunnelBahn.xcodeproj
```

## Components

- `TunnelBahn`: SwiftUI UI, profile import, app selection, menu bar controls
- `NetworkExtension`: `NEPacketTunnelProvider` — WireGuard tunnel transport, plus an alternative SSH port-forwarding transport (`SSHFlowTransport`)
- `Shared`: shared models and app-group constants

## Per-app routing (how it works)

This project uses **Network Extension per-app VPN routing**:

- The tunnel is created with `NETunnelProviderManager.forPerAppVPN()` and `routingMethod = .sourceApplication`.
- Routing is an **allow‑list**: only apps matched by `NEAppRule` are forced into the tunnel; all other apps bypass it.
- Practical setup: set **Settings → Unmatched apps = Bypass VPN**, then enable **Route via VPN** only for the apps you want tunneled.
- Routed apps work with any `AllowedIPs` — full-tunnel (`0.0.0.0/0`) or split-tunnel (specific CIDRs). Only traffic matching `AllowedIPs` is sent through the tunnel.

## SSH transport (alternative per-profile egress)

Besides WireGuard, a profile can egress over **SSH port forwarding** (`direct-tcpip`
channels) instead. The per-app identity and destination-filter routing layer is
transport-agnostic — only the final hop changes. Pick the transport per profile in
the editor, or create one from scratch with **New SSH Profile** in the sidebar.

As-built behavior and limitations:

- **TCP-only.** SSH `direct-tcpip` carries TCP flows. Tunneled **UDP is dropped**;
  QUIC/HTTP3 clients fall back to TCP automatically.
- **DNS keeps working via the existing local-resolver bypass** — it is *not* remote
  DNS over the SSH connection. Traffic to the system/LAN resolver bypasses the
  tunnel exactly as it does for WireGuard, so name resolution is unaffected.
- **Authentication is public-key only, ed25519 or ECDSA (P-256/384/521).** **RSA
  keys are unsupported** (swift-nio-ssh has no RSA host/user key type). Import or
  paste the private key in the editor; it is stored in the Keychain, never in the
  profile JSON.
- **Host-key trust is trust-on-first-use (TOFU).** The server's host key is pinned
  by the extension on the first connect and any later change is rejected as a
  possible man-in-the-middle — this hard-fail always holds. The profile detail
  view surfaces the pinned fingerprint and offers **Reset Host Key Trust**, but
  note a v1 limitation (below): the app and the root extension resolve the App
  Group to different containers, so the app clears only its own record of the
  pin. A genuine server host-key rotation that the extension rejects may require
  reinstalling/resetting the extension to recover; an authoritative in-app reset
  (via a provider-message IPC) is a planned follow-up.

v1 limitations to be aware of:

- **Head-of-line blocking:** all flows for a profile multiplex over a single SSH
  connection, so a stall on one channel can delay others.
- **No DNS-over-TCP:** an app hardwired to a *remote UDP* resolver that falls inside
  the destination filter won't resolve (UDP is dropped and there is no DNS-over-TCP
  fallback).
- **No internal / split-horizon name resolution** through the SSH host.
- **No app-level SSH keepalive:** idle-drop detection relies on TCP keepalive only.

## Important notes

- Building requires full Xcode (not only Command Line Tools).
- Per-app VPN routing is configured via `NETunnelProviderManager` app rules (`NEAppRule`).
- The app requires `packet-tunnel-provider` Network Extension entitlement.
- The WireGuard data plane uses the Cloudflare BoringTun library (`BoringTunBridge/`), built as a static Rust library.
