# AppSplit WG

AppSplit WG is a native macOS app prototype for WireGuard per-application split tunneling.

## Local-machine development

This project is designed for your machine-first workflow. Homebrew dependencies are expected:

```bash
brew install xcodegen wireguard-tools swiftformat
```

## Generate project

```bash
xcodegen generate
open AppSplitWG.xcodeproj
```

## Components

- `AppSplitWG`: SwiftUI UI, profile import, app selection, menu bar controls
- `NetworkExtension`: `NEPacketTunnelProvider` WireGuard tunnel transport
- `Shared`: shared models and app-group constants

## Per-app routing (how it works)

This project uses **Network Extension per-app VPN routing**:

- The tunnel is created with `NETunnelProviderManager.forPerAppVPN()` and `routingMethod = .sourceApplication`.
- Routing is an **allow‑list**: only apps matched by `NEAppRule` are forced into the tunnel; all other apps bypass it.
- Practical setup: set **Settings → Unmatched apps = Bypass VPN**, then enable **Route via VPN** only for the apps you want tunneled.
- For routed apps to reach the Internet, the WireGuard peer typically needs default‑route `AllowedIPs` (e.g. `0.0.0.0/0` and `::/0`).

## Important notes

- Building requires full Xcode (not only Command Line Tools).
- Per-app VPN routing is configured via `NETunnelProviderManager` app rules (`NEAppRule`).
- The app requires `packet-tunnel-provider` Network Extension entitlement.
- `WireGuardKit` is added via Swift Package Manager in `project.yml`.
