# Full-Tunnel Exclude Mode — Design

**Date:** 2026-08-01
**Status:** Approved (brainstorming session)

## Problem

"Tunnel all except selected" (exclude mode) works only in App-Tunnel routing mode. In
Full Tunnel mode the UI disables the exclude radio and `isFullTunnelDestFilterShape`
accepts only `filterMode == .include` — the include shape narrows the packet tunnel's
`includedRoutes` to the filter CIDRs, which is exactly backwards for exclude semantics.
Users want full-tunnel exclude: tunnel everything system-wide except a listed set
(e.g. domestic country IP ranges).

## Decisions (from brainstorming)

- **Same proxy stack as the include shape.** Full-tunnel exclude activates the identical
  transparent-proxy + XPC-relay stack (`useTransparentProxy`), with the proxy told
  `filterMode == .exclude`. The proxy's `DestinationRouteDecision` already implements
  exclude verdicts (from App-Tunnel mode); per-app stats, per-destination stats, and
  live IP push come along for free.
- **Route shape is the inverse of include.** Packet tunnel gets `includedRoutes =
  default route` (v4 + v6, like plain full-tunnel) and `excludedRoutes = the enabled
  exclude-list CIDRs`, no gateway on excluded routes.
- **DNS mirrors the include shape:** `NEDNSSettings` is NOT applied. DNS flows through
  the proxy's port-53 redirect to `tunnelDNSHost` over the XPC relay; "Resolve DNS
  locally" suppresses the redirect exactly as in App-Tunnel exclude mode. No new DNS
  plumbing; the redirect target never depends on kernel utun routes.
- **Kernel excludedRoutes are sanitized silently:** any exclude CIDR that contains a
  tunnel interface address or a tunnel DNS server IP is dropped from the kernel route
  list (with a traceLog naming it). The proxy still honors the user's direct verdict
  for real traffic; the WG virtual network and DNS can never be black-holed. No
  connect failure — bulk country lists legitimately contain RFC-1918 space.
- **Domain rules stay resolved-IP-only in full-tunnel** (both filter modes, as today):
  `destinationDomainNames` continues to be passed only in App-Tunnel mode. Domains
  work via their resolved IPs in the CIDR set plus the 30s re-resolution live push.
  SNI matching for full-tunnel filter modes is a possible follow-up, out of scope.
- **Runtime-state plumbing (Option A):** add a parallel optional field
  `appTunnelExcludedRoutes: [String]?` to `TunnelRuntimeState`, mutually exclusive
  with `appTunnelIncludedRoutes` by construction. No rename of the existing field.

## Connect path (TunnelBahn/Services/VPNManager.swift)

`isFullTunnelDestFilterShape` (~line 318) drops the `destinationFilterMode == .include`
clause. It now activates for include AND exclude, still gated on:
`isPerAppSplitTunnelEnabled && !appTunnelModeSelected && enforceDestinationFiltering
&& !destinationCidrStrings.isEmpty && profileOkForAccounting`.

Everything downstream the flag drives is already mode-agnostic:

- Proxy stack activation (`useTransparentProxy = useAppTunnelNEStack ||
  isFullTunnelDestFilterShape`, line ~854).
- `destinationSplitActive` and the proxy-only NEAppRules.
- Destination-routing file + `TransparentProxyRuntimeConfig` persistence, which already
  pass `destinationFilterMode` through when enforce is on (the enforce-off
  normalization at ~line 404 stays untouched and still collapses residual `.exclude`
  to tunnel-all behavior).

The only mode-sensitive part is route building (~line 520–548):

- **Include (unchanged):** `tunnelIncludedRoutes = filter CIDRs + DNS /32s (v4) //128s
  (v6)`, `tunnelExcludedRoutes = nil`.
- **Exclude (new):** `tunnelIncludedRoutes = nil`, `tunnelExcludedRoutes = sanitized
  exclude CIDRs`.

Sanitization happens host-side before persisting runtime state: drop any CIDR that
contains a tunnel interface address or DNS server IP (containment check via
`IPCIDRMatcher`), traceLog each dropped CIDR. Both `makeRuntimeStateData` calls (file
and providerConfiguration payloads) carry the new field.

`configureManager` needs no change: the exclude shape passes `narrowedRoutes: false`
(its includedRoutes ARE the default route), taking the same `includeAllNetworks` path
as today's full-tunnel accounting shape.

## Extension (Shared/TunnelRuntimeState.swift, NetworkExtension/)

- `TunnelRuntimeState`: new `let appTunnelExcludedRoutes: [String]?`. NE-side
  providerConfiguration decoding stays tolerant (per 466689b): a stale extension
  ignores the key and runs plain full-tunnel — over-tunnels, never leaks, the safe
  fallback for exclude semantics.
- `PacketTunnelProvider.startWireGuard` threads the field into `adapter.start(...)`.
- `BoringTunAdapter.start` / `buildNetworkSettings` gain an
  `appTunnelExcludedRoutes: [String]?` parameter. Exclude shape builds:
  - `ipv4.includedRoutes = [NEIPv4Route.default()]`, `ipv6.includedRoutes =
    [NEIPv6Route.default()]` (per address-family presence, as plain full-tunnel).
  - `ipv4/ipv6.excludedRoutes =` parsed exclude CIDRs, no `gatewayAddress` (they route
    via the physical interface).
  - `NEDNSSettings` skipped (same as the include shape).
  - The adapter asserts the two route fields are never both non-empty.
- The adapter's outbound packet filter (`destinationSplitFilterActive`) stays OFF in
  the exclude shape: an excluded destination leaking through utun is suboptimal
  routing, not a privacy leak, and tunneled traffic rides the smoltcp XPC path which
  bypasses that filter anyway. The existing else-branch (AllowedIPs-derived ranges
  with default route → no filtering) already yields the right behavior.

## UI (TunnelBahn/Views/RoutingView.swift)

- Remove the `appState.settings.routingMode == .fullTunnel` disabled clause and the
  `&& appState.settings.routingMode != .fullTunnel` isOn clause on the exclude radio.
- Delete `normalizeExcludeModeForRoutingMode()` and its three call sites (onAppear,
  onChange(routingMode), and the doc comment).
- Update `excludeDestinationsTooltip`: drop "App-Tunnel mode only." Keep it one short
  sentence, no em dashes.

Per-mode destination lists, section toggles, warning banner, and the empty-mode
preview already handle exclude generically — no other UI change.

## Edge cases

- **Enforce-off residual `.exclude`:** already safe. The shape flag requires
  `enforceDestinationFiltering`; the existing normalization forces `.include` on the
  proxy config when enforce is off. Behavior is tunnel-all.
- **SSH:** unaffected. SSH profiles have no WG default-route peer, so
  `profileOkForAccounting` is false, the shape never activates, and the "SSH requires
  App-Tunnel" guard (~line 333) still fires.
- **Private/local destinations:** proxy-level `localBypassRanges` behavior is
  unchanged (exclude mode passes empty `tunnelRanges`, listed private CIDRs mean
  direct — which the bypass already does).
- **Live IP push:** `syncDestinationRoutingFromHostActivity` already carries
  `filterMode`; re-resolved domain IPs widen the proxy's exclude set mid-session.
  Kernel excludedRoutes stay connect-time static, same staticness as the include
  shape's narrowed routes.
- **Empty exclude CIDR set:** shape gate requires non-empty `destinationCidrStrings`,
  so an all-disabled list falls through to plain full-tunnel, matching the UI's
  "destination lists inactive" state.

## Testing

Unit tests (`TunnelBahnUnitTests`):

- Shape flag: `.exclude` now qualifies; enforce-off, App-Tunnel mode, empty CIDRs, and
  no-default-route profiles still do not.
- Sanitization: a CIDR containing a DNS server IP or interface address is dropped;
  non-overlapping CIDRs are kept; v4 and v6.
- `buildNetworkSettings` exclude shape: default includedRoutes, excludedRoutes
  installed without gateway, no dnsSettings, include/exclude fields never both set.
  Extract a pure helper if the current shape is not directly testable.

Existing `DestinationRouteDecision` exclude tests already cover proxy verdicts. E2E
(tunnel up, domestic bulk group excluded, verify direct vs tunneled) stays manual, per
repo convention. Known environmental failure to ignore:
`WGTCPWrapperRelayTests.testDatagramRoundTripsThroughRelay`.

## Out of scope

- SNI/domain-name matching in full-tunnel filter modes (follow-up candidate).
- Any change to App-Tunnel exclude behavior, SSH transport, or the include shape's
  narrowed-routes logic.
- GeoIP / built-in country lists.
