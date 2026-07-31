# Auto-enable "Tunnel selected apps" on app add

**Date:** 2026-07-31
**Status:** Approved

## Problem

Selecting apps in the Apps view does not change the routing mode. A user who adds
apps must also remember to click the "Tunnel selected apps" radio button, or the
selection has no effect. The inverse direction is already automatic:
`autoSwitchToFullTunnelIfNoSelection()` in `TunnelBahn/Views/AppsView.swift`
switches back to full tunnel when the last app is removed.

## Behavior

Whenever an app is added to the selected list — via the "+" button on an
installed-app row or via the "Add App…" file picker — the routing mode is set to
`.appTunnel`. This fires on **every** add, not just the first (0 → 1): if the
user had switched back to "Tunnel all apps" with apps still selected, adding
another app switches to app-tunnel mode again. (Explicit user choice.)

## Implementation

Add a private helper in `AppsView`, symmetric to the existing one:

```swift
private func autoSwitchToAppTunnelOnAdd() {
    guard AppConstants.isPerAppSplitTunnelEnabled else { return }
    guard !rulesLocked else { return }
    appState.settings.routingMode = .appTunnel
}
```

Call it from both add paths:

- `addSelectedApp(_:)` (the "+" row button)
- the success closure of `pickAndRegisterApp()` under "Add App…"

The hook is on the explicit add actions, **not** `onChange(of: selectedCount)`,
so profile switches or rule-store changes from elsewhere never silently flip
the stored mode. Both add paths are already disabled while `rulesLocked`; the
guard is defensive consistency with the existing helper.

## Out of scope

- Radio-button enablement (`canEnableAppTunnelMode`) is unchanged.
- Removal behavior (`autoSwitchToFullTunnelIfNoSelection`) is unchanged.
