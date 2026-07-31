# Exclude-Mode Destination Routing — Design

**Date:** 2026-07-31
**Status:** Approved (brainstorming session)

## Problem

Destination filtering today is whitelist-only: a profile lists CIDRs/domains and only
matching destinations are tunneled. Users in censored/degraded-network environments need
the inverse: tunnel *everything except* a listed set — e.g. route all non-Iranian IPs
through the tunnel, because Iranian destinations are faster on the domestic intranet or
unreachable from outside Iran.

## Decisions (from brainstorming)

- **Semantics:** per-profile mode toggle. A profile is either *include* mode (current
  behavior) or *exclude* mode (tunnel everything except listed rules). No mixed
  per-rule priorities.
- **List source:** reuse the existing bulk CIDR import (named bulk groups). No built-in
  country lists, no URL subscriptions.
- **Domain rules invert too:** in exclude mode an SNI/domain rule means "this hostname
  goes direct" (covers CDN-hosted domestic sites served from foreign IPs).
- **DNS:** per-profile toggle on exclude-mode profiles. Default keeps today's behavior
  (redirect routed apps' port-53 to the tunnel resolver); the toggle lets DNS resolve via
  the local resolver instead (better domestic CDN steering, at the cost of local DNS
  filtering applying).

## Data model & config plumbing

New shared type (in `Shared/`, used by app + extension):

```swift
public enum DestinationFilterMode: String, Codable, Sendable {
    case include   // current behavior: tunnel only matching destinations
    case exclude   // tunnel everything EXCEPT matching destinations
}
```

Threaded through all three config layers, each decoding a missing key as `.include`
(backward compatible with existing profiles, App Group files, and app/extension version
skew):

1. `ProfileRoutingSnapshot` — add `filterMode: DestinationFilterMode`.
2. `DestinationRoutingFilePayload` — add `filterMode`; `schemaVersion` stays 1 (decode
   is tolerant).
3. `TransparentProxyRuntimeConfig` — add `filterMode`.

DNS toggle: add `localDNSForExcluded: Bool` (default `false`) to the profile snapshot and
runtime config. When `true`, the UDP port-53 redirect to `tunnelDNSHost` is suppressed so
routed apps' DNS reaches the local resolver directly. Only meaningful (and only shown) in
exclude mode; include mode is unaffected.

Rule containers (`customCidrRules`, `bulkGroups`, `domainRules`) are structurally
unchanged — the mode reinterprets them at decision time. `enforceDestinationFiltering`
remains the master on/off switch; `filterMode` only matters when it is on.

## Interception rules

`buildIncludedNetworkRules`: in exclude mode (enforce on, mode `.exclude`) return
catch-all TCP + catch-all UDP — the same shape SNI mode already publishes for TCP. Every
flow of a routed app must be seen to decide; `NENetworkRule` cannot express negation and
transparent proxies have no `excludedNetworkRules`. Non-routed apps are declined by the
signing-ID check as always.

## TCP decision flow (flow-open, routed apps, exclude mode)

1. **Local/private bypass first, unchanged — always direct.** The
   `shouldBypassLocal(_:tunnelRanges:)` override ("user listed a private CIDR, so tunnel
   it") must NOT apply in exclude mode — there, a listed CIDR means *direct*, which the
   bypass already does. Exclude mode passes empty `tunnelRanges`.
2. **Remote IP literal matches exclude CIDRs → decline the flow** (return false; the OS
   routes it directly over en0). No relay, no peek. Both rule types agree on "direct"
   here, so SNI cannot change the answer.
3. **Otherwise intercept and tunnel.** If domain rules exist, attach the inverted SNI
   decider: peek the ClientHello; SNI suffix-matches a domain rule → direct (relay's
   existing en0 path); no match or no SNI → tunnel. With no domain rules there is no
   peek at all.

Fail-open direction inverts: include mode's "no SNI, no IP match" falls back to direct;
exclude mode falls back to **tunnel** — the conservative default for the censorship use
case.

## UDP decision flow (per-datagram, exclude mode)

1. Local bypass unchanged (tunnel-override disabled, as above).
2. Datagram IP in exclude ranges → `sendViaDirect` (existing path).
3. Everything else → tunnel via smoltcp, including the existing port-53 redirect to
   `tunnelDNSHost` — unless `localDNSForExcluded` is on, in which case the redirect is
   skipped and DNS exits via the local-bypass direct path.
4. SSH mode's `dropTunneledUDP` fail-closed behavior is untouched.

Domain rules never apply to UDP (no SNI); UDP exclusion is IP-only, same as today.

The exclude ranges reach these decision points through the existing
`cachedPreparedRanges` / `tunnelRanges()` machinery — same prepared `IPCIDRMatcher`
ranges, consulted with inverted meaning.

## UI

In `RoutingView`, inside the "destination filtering on" branch: a segmented `Picker` —
**"Tunnel only listed"** (include, default) / **"Tunnel all except listed"** (exclude).
Rule sections are identical in both modes; captions adapt (exclude mode: "these
destinations will bypass the tunnel"). Exclude mode additionally shows the
**"Resolve DNS locally"** toggle (off by default, with a note that local DNS may be
filtered). Menu bar and profile UI unchanged — the mode lives in the profile snapshot,
so profile switching just works.

## Error handling & edge cases

- Missing `filterMode` key decodes as `.include` at every layer.
- Exclude mode with an empty rule list is legal: "tunnel everything" for routed apps.
  No special-casing; the UI may note it.
- Invalid CIDR lines are skipped by `IPCIDRMatcher.prepare`, as today.
- Live appMessage config pushes carry the mode; a mid-session mode flip republishes
  network rules through the existing `applyDestinationPayload` change-detection path.

## Testing

- Extract the tunnel-vs-direct choice into a pure helper in `Shared/` (e.g.
  `DestinationRouteDecision.decide(mode:ipMatchesRules:sniMatchesRules:)` returning
  tunnel / direct / decline) and unit-test both modes, including the fail-open inversion
  and the disabled local-bypass override in exclude mode.
- Codec tests: all three config types decode without the new keys → `.include` /
  `false`.
- E2E (tunnel up, Iranian CIDR bulk group excluded, verify direct vs tunneled paths)
  remains manual, consistent with the rest of the codebase.

## Out of scope

- Built-in or downloadable country IP lists (GeoIP).
- Per-rule allow/deny priorities or mixing modes within one profile.
- Any change to per-app (signing-ID) selection or SSH transport behavior.
