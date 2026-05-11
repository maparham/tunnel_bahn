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
- `NetworkExtension`: `NEPacketTunnelProvider` WireGuard tunnel transport
- `Shared`: shared models and app-group constants

## Per-app routing (how it works)

This project uses **Network Extension per-app VPN routing**:

- The tunnel is created with `NETunnelProviderManager.forPerAppVPN()` and `routingMethod = .sourceApplication`.
- Routing is an **allow‑list**: only apps matched by `NEAppRule` are forced into the tunnel; all other apps bypass it.
- Practical setup: set **Settings → Unmatched apps = Bypass VPN**, then enable **Route via VPN** only for the apps you want tunneled.
- Routed apps work with any `AllowedIPs` — full-tunnel (`0.0.0.0/0`) or split-tunnel (specific CIDRs). Only traffic matching `AllowedIPs` is sent through the tunnel.

## Important notes

- Building requires full Xcode (not only Command Line Tools).
- Per-app VPN routing is configured via `NETunnelProviderManager` app rules (`NEAppRule`).
- The app requires `packet-tunnel-provider` Network Extension entitlement.
- The WireGuard data plane uses the Cloudflare BoringTun library (`BoringTunBridge/`), built as a static Rust library.
