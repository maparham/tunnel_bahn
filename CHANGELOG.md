# Changelog

All notable changes to TunnelBahn are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **SSH as an alternative per-profile egress transport.** A profile can now tunnel
  over SSH `direct-tcpip` port forwarding instead of WireGuard, selectable per
  profile, sharing the same transport-agnostic per-app identity + destination-filter
  routing layer. Create one via **New SSH Profile** in the sidebar, or switch an
  existing profile's transport in the editor.
  - **TCP-only:** tunneled UDP is dropped; QUIC/HTTP3 falls back to TCP. DNS keeps
    working via the existing local-resolver bypass (not remote DNS).
  - **Public-key auth, ed25519 or ECDSA (P-256/384/521) only** — RSA is unsupported.
    Keys are stored in the Keychain (shared access group), never in the profile JSON.
  - **Host-key trust-on-first-use (TOFU):** the server key is pinned by the extension
    on first connect and any later change is rejected (this hard-fail always holds).
    The profile detail view surfaces the pinned fingerprint and offers **Reset Host
    Key Trust**; note that on the shipping root-extension configuration this clears
    only the app's own record, so recovering from a genuine host-key rotation may
    require reinstalling the extension (an authoritative IPC-based reset is a planned
    follow-up).
  - Known v1 limitations: single-connection head-of-line blocking, no DNS-over-TCP,
    no internal/split-horizon name resolution, no app-level SSH keepalive
    (idle-drop detection is TCP-keepalive-only), and best-effort (non-authoritative)
    in-app host-key reset.
- **WireGuard-over-TCP (WebSocket/TLS wrapper).** WireGuard profiles can now carry traffic
  over a `wstunnel` v10-compatible TLS WebSocket for networks that block UDP. Configured in
  the profile editor or via a `[TCPWrapper]` section in imported `.conf` files. The wrapper
  runs in-process in the network extension; the WireGuard data plane is unchanged. Cert
  verification defaults off (matching wstunnel); single-connection, WebSocket-transport
  only, no auto-reconnect in this release.

### Fixed
- SSH private-key material is no longer orphaned in the Keychain when a profile's
  transport is switched SSH→WireGuard or when an SSH profile is deleted.
- The keychain-integrity check and connect-time key guard are now transport-aware,
  so SSH profiles are validated against their SSH key rather than the (inert)
  WireGuard interface key.

## [0.1.0] - 2026-07-02

First public release: a native macOS app for WireGuard per-application split
tunneling, built on Network Extension per-app VPN routing (`.sourceApplication`
allow-list) with a transparent-proxy data path.

### Added
- Per-app split tunneling via `NETunnelProviderManager.forPerAppVPN()`; route
  chosen apps through the tunnel while everything else bypasses it.
- BoringTun-based WireGuard transport (`PacketTunnelExtension`) with a
  userspace smoltcp TCP stack over a UDS relay to the transparent proxy.
- Filesystem-based app discovery with lazy icon loading; routing UI, profile
  import, menu-bar controls, and an in-app Logs tab.
- Encrypted backup/restore of profiles with Keychain-referenced key material.
- Distribution tooling: `sign-for-direct-distribution.sh`, `verify-build.sh`,
  git build-stamping, and a routing test harness (`run-routing-tests.sh`).

### Fixed
- **Private/local destinations bypass the tunnel.** In full/app-tunnel the proxy
  previously relayed *every* routed flow through WireGuard — including DNS to an
  RFC-1918 system resolver (e.g. Cloudflare WARP's `10.206.231.57` or a LAN
  router), which the WG peer can't route back, black-holing DNS. Private,
  loopback, and link-local destinations now bypass the tunnel (TCP declined to
  the OS; UDP sent via the relay's direct path). IPv4-mapped IPv6 literals
  (`::ffff:a.b.c.d`) and `0.0.0.0/8` are covered.
- **UDP direct-path use-after-free.** The direct read path released its
  `NWConnection` from inside its own `stateUpdateHandler`, segfaulting in
  `objc_release` (which surfaced as apps appearing to leak past the tunnel).
  Teardown is now deferred to the serial `flowQueue`, identity-guarded, and
  nils the handler first.
- **Relay protocol hardening.** Malformed vs. incomplete frames are now
  distinguished (readers tear down instead of wedging); payloads above the
  1 MiB frame cap are chunked; remote FIN/RST propagates from smoltcp so
  read-only flows get EOF instead of hanging; smoltcp uses a monotonic
  timebase so retransmission timers no longer freeze on wall-clock steps.
- **Close/leak propagation.** TCP app-EOF on the tunnel path now finishes the
  flow (previously leaked one relay per app-initiated close); UDP send errors
  tear down only the failing destination; `stopProxy`/flush-timer races are
  closed with a session-generation guard.
- **Routing correctness.** A-only domains no longer fail on the AAAA negative
  answer; connect failure disables the saved on-demand rule (no phantom
  reconnect); auto-reconnect targets the previously-connected profile; IPv6 DNS
  servers get `/128` routes.
- **UI/tooling.** QR panel over-release crash; no-flicker tunnel-mode label; log
  auto-scroll past the 10k cap; leaked provider-message timeout tasks; routing
  test harness no longer reports PASS on black-holed routing; signing script no
  longer swallows verify failures.

### Known issues
See [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Notably, empirical verification
that routed-app **UDP** (QUIC/HTTP3, public DNS) egresses via the tunnel rather
than the physical interface is still pending, and the SNI-peek path currently
fails open on a truncated ClientHello. Treat 0.1.0 as an early release.

[0.1.0]: https://github.com/maparham/tunnel_bahn/releases/tag/v0.1.0
