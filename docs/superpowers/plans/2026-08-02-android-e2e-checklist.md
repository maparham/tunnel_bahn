# Android Client On-Device e2e Checklist

Date: 2026-08-02
Status: pending device + real-server credentials

## Preconditions

- A physical Android device on adb (`adb devices` shows it `device`, not `unauthorized`).
- App installed: `./gradlew :app:installDebug` (uses the JBR; NDK-built AAR bundled).
- VPN consent granted once: open the app, tap Connect on any profile, accept the
  system VPN dialog. The headless driver requires consent to be pre-granted.
- At least one real profile configured against the existing TunnelBahn servers:
  - SSH profile: server `host:port`, user, OpenSSH private key PEM, host key line.
  - WG+wstunnel profile: `wss://host/<path>/events`, WG private key, peer public key,
    local addresses, forward host/port.

## Driver

```
adb shell am start -a android.intent.action.VIEW \
  -d "tunnelbahn-android://test?profile=<id>" tunnelbahn.app
adb logcat -s TB_E2E
```

Expected on success: `PASS: exit IP through tunnel = <server exit IP>`.

## Cases

| # | Case | Setup | Pass criterion | Result |
|---|------|-------|----------------|--------|
| 1 | SSH, include mode | Include only one app's traffic (CIDR of a known host, or per-app) | That app's exit IP is the server; others direct. DNS resolves. | ⬜ |
| 2 | SSH, exclude/full-tunnel | Exclude mode, empty list (routes 0.0.0.0/0) | A page loads AND DNS resolves (UDP/53 to TCP/53 path). This is the case that would silently fail without the DNS interceptor. | ⬜ |
| 3 | SSH through the Iranian gateway | Real gateway network | Real traffic flows; exit IP is the server. Empirical reason SSH is primary. | ⬜ |
| 4 | WG+wstunnel | WG profile | Handshake completes; exit IP is the server; a UDP/QUIC (HTTP/3) request succeeds, proving DialUDP. | ⬜ |
| 5 | wstunnel frame masking | WG profile, inspect | UNMASKED frames complete the handshake. If frames were accidentally masked, the handshake stalls here (per the macOS root cause). | ⬜ |
| 6 | protect() loop check | Any profile | Bypass flows and the transport's own carrier socket egress directly; no routing loop, no handshake stall. | ⬜ |

## Notes

- Exit-IP echo used by the driver: `https://api.ipify.org`. Compare the tunneled
  result against the device's direct IP (disconnect and re-run, or check via a bypass
  app) to confirm the tunnel is actually carrying traffic.
- Case 2 is the highest-value regression guard: verify DNS by loading a page by
  hostname (not IP) while in full-tunnel SSH mode.
- Case 5: if the handshake stalls, confirm `wstunnel/frame.go` still emits mask bit 0
  and that no compliant WS library snuck into the relay write path.
