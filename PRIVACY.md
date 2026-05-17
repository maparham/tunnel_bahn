# TunnelBahn Privacy Policy

**Last updated:** May 17, 2026

This policy describes how **TunnelBahn** (“the App”), a native macOS utility for WireGuard-based VPN connectivity and per-application routing, handles information.

If anything here conflicts with what you declare in **App Store Connect → App Privacy**, update both so they agree.

---

## Summary

TunnelBahn is built to configure VPN tunnels **on your Mac**. You supply configuration (profiles, keys, endpoints). The App does **not** ship third-party advertising or analytics SDKs in this open-source distribution.

When you enable a tunnel, network traffic matching your profile travels through the **VPN server or service you configured**. That destination has its own privacy practices; this policy does not cover them.

---

## Information the App uses

- **VPN configuration and profiles** you import or create (for example WireGuard profiles), **stored locally** on your Mac to operate the tunnel and related settings.

- **App preferences** (such as routing options and selections you make in the UI), **stored locally** using standard Apple storage mechanisms unless you migrate data yourself.

- **Network traffic** handled by Apple’s VPN and Network Extension framework when you connect. Routing and encryption operate under macOS controls you approve (for example VPN permission prompts).

TunnelBahn does **not** operate its own centralized account system or synchronization service as part of the App.

---

## What we do not do (as shipped here)

Based on how this codebase is structured, TunnelBahn does **not**:

- Sell your personal information.

- Embed third-party ad or behavioral analytics frameworks in this repository’s App source.

Nothing here limits **Apple** or **your chosen VPN providers** from processing data according to their own terms when you use the system or their networks.

---

## Logging and diagnostics

The App may write **technical logs on your Mac** (for troubleshooting) consistent with developer logging on macOS. Those logs generally stay **on-device** unless you choose to export or share them (for example with Apple during a Feedback report or via Console).

macOS crash reports handled by Apple are subject to **[Apple’s privacy policy](https://www.apple.com/privacy/)**.

---

## Children’s privacy

TunnelBahn is **not directed at children** under 13. If you believe a minor has supplied personal context through support channels you control, delete it and stop processing as appropriate.

---

## Changes

We may update this policy periodically. When we do, the **“Last updated”** date above will change. Material changes affecting users are best surfaced in release notes when you distribute builds.

---

## Contact

Privacy questions related to TunnelBahn can be filed at:

**[https://github.com/maparham/tunnel_bahn/issues](https://github.com/maparham/tunnel_bahn/issues)**

Replace or supplement this URL with a dedicated privacy contact email when you operate a commercial storefront.
