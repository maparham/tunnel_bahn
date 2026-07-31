# Remove dead periodic stats file writes from both extensions

**Date:** 2026-07-31
**Status:** Approved

## Problem

Both network extensions perform periodic disk writes that nothing reads:

- `TransparentProxyProvider.flushOnce` JSON-encodes per-app transfer stats and
  atomically writes `per-app-stats.json` every 1.5 s via `PerAppTransferStore.write`.
  `PerAppTransferStore.read()` has zero callers — the host pulls stats exclusively
  over the `getStats` provider IPC (`PerAppStatsProxyManager.fetchStats`), because
  the root extension and user host resolve the App Group container to different
  directories and a shared file cannot cross that uid boundary.
- `PacketTunnelProvider` runs a dedicated timer (`startResourceSampler`) whose only
  job is `sampleAndPublishExtensionResources` — a read-merge-write of
  `extension-resources` via `ExtensionResourceStore`. The transparent proxy does the
  same from `flushOnce` (`flushExtensionResourceStats`). No host code reads this
  file either; the host fetches CPU/memory via the `resourceStats` IPC, whose reply
  is ad-hoc `{cpu, memory}` JSON, not the `ExtensionResourceStats` struct.
- `VPNManager` calls `PerAppTransferStore.reset()` (×2) and
  `ExtensionResourceStore.reset()`, which delete from the *host's* container — a
  location the extensions never wrote to.

These are leftovers of the pre-IPC design. They cost a JSON encode + atomic file
write every 1.5 s in the proxy and a periodic timer wakeup in the packet tunnel,
even when the app UI is closed.

## Change

Deletion only; no new configuration, no behavior change visible to the UI.

1. **TransparentProxyProvider**
   - Remove the `PerAppTransferStore.write(stats)` call (and its `do/catch`) from
     `flushOnce`.
   - Remove `flushExtensionResourceStats()` and its call site. The flush timer
     itself stays: it still re-affirms rules, refreshes destination config, and
     rebuilds the `latestStatsPayload` IPC cache.
   - `sampleResources()` stays for the `resourceStats` IPC reply.
2. **PacketTunnelProvider**
   - Remove `sampleAndPublishExtensionResources()`, `startResourceSampler()`, the
     timer property, and the timer teardown. Keep `resourceSampler`,
     `resourceSampleQueue`, and `sampleResources()` — the `resourceStats` IPC reply
     samples on demand. The time-delta CPU math is correct across arbitrary gaps,
     so on-demand sampling at the host's 2 s poll needs no warm-up timer. When the
     host is not polling, the extension does no sampling at all.
3. **VPNManager**
   - Remove the `PerAppTransferStore.reset()` and `ExtensionResourceStore.reset()`
     calls.
4. **Shared**
   - Delete `PerAppTransferStore.swift`, `ExtensionResourceStore.swift`, and
     `ExtensionResourceStats.swift`.
   - `PerAppTransferStats` stays — it is the `getStats` IPC payload.
   - Fix the stale design note in `PerAppCounterAggregator` that references
     `PerAppTransferStore.reset()`.

Stale files from previous versions are left as harmless orphans in the extensions'
containers; no migration/cleanup pass.

## Testing

- Build all targets; run the existing test suite (no tests reference the deleted
  stores).
- Smoke check: connect, open the stats UI, confirm per-app transfer numbers and
  extension CPU/memory still populate (both ride IPC, unchanged).
