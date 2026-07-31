# Remove Dead Stats File Writes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the periodic stats file writes in both network extensions (and their host-side reset calls) that nothing reads — all stats consumption rides provider IPC.

**Architecture:** Deletion-only change, no new behavior. The transparent proxy's flush timer keeps its rules/IPC-cache duties but stops writing `per-app-stats.json`; the packet tunnel loses its resource-sampler timer entirely (on-demand IPC sampling remains); three now-unused Shared files are deleted. Spec: `docs/superpowers/specs/2026-07-31-remove-dead-stats-file-writes-design.md`.

**Tech Stack:** Swift, XcodeGen (`xcodegen generate` regenerates `TunnelBahn.xcodeproj` from `project.yml`; Shared sources are globbed per-target, so file deletions require regeneration).

## Global Constraints

- No behavior change visible to the UI: per-app stats and extension CPU/memory must still flow over the `getStats` / `resourceStats` IPC.
- Keep `PerAppTransferStats` (it is the `getStats` IPC payload) and keep `ProcessResourceSampler` + `sampleResources()` in both extensions (they serve the `resourceStats` IPC reply).
- No migration/cleanup of stale files in the extensions' containers.
- No new tests: this removes dead code with no testable surface; verification is compile + existing suite + manual smoke check.

---

### Task 1: TransparentProxyProvider — drop file writes from the flush path

**Files:**
- Modify: `TransparentProxyExtension/TransparentProxyProvider.swift` (in `flushOnce`, ~line 978, and `flushExtensionResourceStats`, ~line 987)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `flushOnce` no longer references `PerAppTransferStore` or `ExtensionResourceStore` (required before Task 4 deletes those files). `sampleResources()` is retained unchanged.

- [ ] **Step 1: Remove the `PerAppTransferStore.write` call and the `flushExtensionResourceStats()` call from `flushOnce`**

Delete this block at the end of `flushOnce` (directly after the `statsLock` cache update):

```swift
        do {
            try PerAppTransferStore.write(stats)
        } catch {
            Self.log.error("failed to flush app-tunnel stats: \(error.localizedDescription)")
        }

        flushExtensionResourceStats()
```

Also update the comment above the `statsLock` block — it currently reads "this, not the file write below, is what actually reaches the host across the uid boundary". Replace:

```swift
        // Cache for the host's `getStats` IPC pull — this, not the file write below, is what
        // actually reaches the host across the uid boundary.
```

with:

```swift
        // Cache for the host's `getStats` IPC pull — the only path that crosses the uid boundary.
```

- [ ] **Step 2: Delete the `flushExtensionResourceStats()` function**

Remove the whole function:

```swift
    private func flushExtensionResourceStats() {
        // Runs on `flushQueue` (via the flush timer). `sampleResources()` keeps all sampler
        // access on that one queue so its cross-sample state can't race the IPC reader.
        let sample = sampleResources()
        var merged = ExtensionResourceStore.read()
        merged.transparentProxyCPU = sample.cpuPercent
        merged.transparentProxyMemory = sample.memoryBytes
        merged.lastUpdate = .now
        merged.schemaVersion = ExtensionResourceStats.currentSchemaVersion
        do {
            try ExtensionResourceStore.write(merged)
        } catch {
            Self.log.error("failed to flush extension resource stats: \(error.localizedDescription)")
        }
    }
```

Keep `sampleResources()` and the `flushQueueKey` machinery — the `resourceStats` IPC reply still uses them.

- [ ] **Step 3: Verify no remaining references in this file**

Run: `grep -n "PerAppTransferStore\|ExtensionResourceStore\|flushExtensionResourceStats" TransparentProxyExtension/TransparentProxyProvider.swift`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add TransparentProxyExtension/TransparentProxyProvider.swift
git commit -m "refactor(proxy): drop dead per-app stats file writes from flush path"
```

---

### Task 2: PacketTunnelProvider — remove the resource-sampler timer

**Files:**
- Modify: `NetworkExtension/PacketTunnelProvider.swift` (properties ~lines 24–26, call sites ~lines 135, 289, 302–303, functions ~lines 432–455)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: no references to `ExtensionResourceStore`/`ExtensionResourceStats` remain in this file (required before Task 4). `resourceSampler`, `resourceSampleQueue`, `resourceSampleQueueKey`, and `sampleResources()` are retained unchanged for the `resourceStats` IPC reply — on-demand sampling needs no timer because the sampler's CPU math is a time-delta over actual elapsed wall clock.

- [ ] **Step 1: Remove the timer property and interval constant**

Delete these two lines (keep `resourceSampleQueue`, `resourceSampleQueueKey`, and `resourceSampler` between/around them):

```swift
    private var resourceSampleTimer: DispatchSourceTimer?
```

```swift
    private static let resourceSampleInterval: DispatchTimeInterval = .seconds(2)
```

- [ ] **Step 2: Remove both `startResourceSampler()` call sites**

At the end of `startTunnel` (WireGuard path, ~line 135):

```swift
        logger.log("startTunnel completed adapter started")
        startResourceSampler()
```

becomes:

```swift
        logger.log("startTunnel completed adapter started")
```

At the end of the SSH start path (~line 289):

```swift
        logger.notice("[APPSPLIT_EXT_SUMMARY] outcome=started transport=ssh host=\(params.host) port=\(params.port) user=\(params.username)")
        startResourceSampler()
```

becomes:

```swift
        logger.notice("[APPSPLIT_EXT_SUMMARY] outcome=started transport=ssh host=\(params.host) port=\(params.port) user=\(params.username)")
```

- [ ] **Step 3: Remove the timer teardown in `stopTunnel`**

Delete these two lines at the top of `stopTunnel`:

```swift
        resourceSampleTimer?.cancel()
        resourceSampleTimer = nil
```

- [ ] **Step 4: Delete `startResourceSampler()` and `sampleAndPublishExtensionResources()`**

Remove both functions:

```swift
    private func startResourceSampler() {
        let timer = DispatchSource.makeTimerSource(queue: resourceSampleQueue)
        timer.schedule(deadline: .now() + Self.resourceSampleInterval, repeating: Self.resourceSampleInterval)
        timer.setEventHandler { [weak self] in
            self?.sampleAndPublishExtensionResources()
        }
        timer.resume()
        resourceSampleTimer = timer
    }

    private func sampleAndPublishExtensionResources() {
        // Runs on `resourceSampleQueue` (via the sample timer).
        let sample = sampleResources()
        var merged = ExtensionResourceStore.read()
        merged.packetTunnelCPU = sample.cpuPercent
        merged.packetTunnelMemory = sample.memoryBytes
        merged.lastUpdate = .now
        merged.schemaVersion = ExtensionResourceStats.currentSchemaVersion
        do {
            try ExtensionResourceStore.write(merged)
        } catch {
            logger.error("failed to write extension resource stats: \(error.localizedDescription)")
        }
    }
```

Then update the doc comment on `sampleResources()` — it references "the sample timer" which no longer exists. Replace:

```swift
    /// Serializes `resourceSampler` on `resourceSampleQueue`. The sampler carries time-delta state
    /// between calls and is not thread-safe, while the `resourceStats` IPC reply arrives on a
    /// different queue than the sample timer — funneling both through one queue keeps the smoothed
    /// value coherent.
```

with:

```swift
    /// Serializes `resourceSampler` on `resourceSampleQueue`. The sampler carries time-delta state
    /// between calls and is not thread-safe; `resourceStats` IPC replies can arrive on arbitrary
    /// queues, so all sampling funnels through one queue to keep the smoothed value coherent.
```

- [ ] **Step 5: Verify no remaining references in this file**

Run: `grep -n "resourceSampleTimer\|resourceSampleInterval\|startResourceSampler\|sampleAndPublishExtensionResources\|ExtensionResourceStore\|ExtensionResourceStats" NetworkExtension/PacketTunnelProvider.swift`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add NetworkExtension/PacketTunnelProvider.swift
git commit -m "refactor(tunnel): remove resource-sampler timer that fed a dead stats file"
```

---

### Task 3: VPNManager — remove dead reset calls

**Files:**
- Modify: `TunnelBahn/Services/VPNManager.swift` (~lines 842 and 1300–1301)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: no references to `PerAppTransferStore`/`ExtensionResourceStore` remain in the host app (required before Task 4).

- [ ] **Step 1: Remove the connect-path reset (~line 842)**

Inside `if useTransparentProxy {`:

```swift
        if useTransparentProxy {
            PerAppTransferStore.reset()
            Self.osLog.notice("[connect] calling perAppStatsProxy.enable() destinationSplit=\(destinationSplitActive)")
```

becomes:

```swift
        if useTransparentProxy {
            Self.osLog.notice("[connect] calling perAppStatsProxy.enable() destinationSplit=\(destinationSplitActive)")
```

- [ ] **Step 2: Remove the disconnect-path resets (~lines 1300–1301)**

```swift
        await perAppStatsProxy.disable()
        PerAppTransferStore.reset()
        ExtensionResourceStore.reset()
        clearPersistedPerAppRoutedSigningIdentifiers()
```

becomes:

```swift
        await perAppStatsProxy.disable()
        clearPersistedPerAppRoutedSigningIdentifiers()
```

- [ ] **Step 3: Verify no remaining references anywhere outside the store files themselves**

Run: `grep -rn "PerAppTransferStore\|ExtensionResourceStore\|ExtensionResourceStats" --include="*.swift" . | grep -v "Shared/PerAppTransferStore.swift" | grep -v "Shared/ExtensionResourceStore.swift" | grep -v "Shared/ExtensionResourceStats.swift"`
Expected: only the stale doc-comment hit in `Shared/PerAppCounterAggregator.swift` (fixed in Task 4).

- [ ] **Step 4: Commit**

```bash
git add TunnelBahn/Services/VPNManager.swift
git commit -m "refactor(app): drop stats-file reset calls that targeted the wrong container"
```

---

### Task 4: Delete the store files, fix the stale comment, regenerate, build, test

**Files:**
- Delete: `Shared/PerAppTransferStore.swift`, `Shared/ExtensionResourceStore.swift`, `Shared/ExtensionResourceStats.swift`
- Modify: `TransparentProxyExtension/PerAppCounterAggregator.swift` (doc comment, ~lines 13–16)
- Regenerate: `TunnelBahn.xcodeproj` via `xcodegen generate`

**Interfaces:**
- Consumes: Tasks 1–3 removed every reference to the deleted types.
- Produces: final state; nothing downstream.

- [ ] **Step 1: Fix the stale design note in `PerAppCounterAggregator.swift`**

Replace:

```swift
/// - Totals are MONOTONIC for the lifetime of the proxy session. The host app diffs them
///   to compute rates if it wants to. On disconnect the host app calls
///   `PerAppTransferStore.reset()` which clears the file but the in-memory totals here
///   reset on `stopProxy` because the provider instance is torn down.
```

with:

```swift
/// - Totals are MONOTONIC for the lifetime of the proxy session. The host app diffs them
///   to compute rates if it wants to. The in-memory totals reset on `stopProxy` because
///   the provider instance is torn down.
```

- [ ] **Step 2: Delete the three dead files**

```bash
git rm Shared/PerAppTransferStore.swift Shared/ExtensionResourceStore.swift Shared/ExtensionResourceStats.swift
```

- [ ] **Step 3: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: succeeds; the deleted files disappear from all target memberships.

- [ ] **Step 4: Build all targets**

Run: `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. Any "cannot find X in scope" failure means a missed reference — fix it before proceeding.

- [ ] **Step 5: Run the unit test suite**

Run: `xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` (the suite has no references to the deleted stores).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(shared): delete write-only stats stores superseded by IPC"
```

---

### Manual smoke check (after all tasks)

Connect the tunnel, open the stats UI, and confirm per-app transfer numbers and extension CPU/memory still populate — both ride IPC (`getStats` / `resourceStats`), which this change does not touch.
