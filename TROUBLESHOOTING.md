# Troubleshooting

## Tunnel fails immediately — keychain error -25300

**Symptom:** The tunnel connects, the extension starts, logs show `startTunnel invoked`,
BoringTun loads the profile, then immediately: `Started with error Keychain operation
failed with status: -25300`.

**Root cause:** The WireGuard private key for the selected profile is missing from the
macOS keychain. The extension reads the key at `startTunnel` time using the
`privateKeyRef` UUID stored in `vpn-state.json`. If that UUID has no corresponding
keychain item, the tunnel fails before it can do any crypto.

**Why it happens:** The most common trigger is a change to `AppConstants.appGroupID` in
`Shared/Constants.swift`. macOS creates a fresh, empty container for the new ID. Any
profiles that end up in the new container — either re-imported manually or copied via
backup — may end up with fresh `privateKeyRef` UUIDs that were never written to the
keychain, or the keychain write failed silently during a partial import.

**How to fix:**

1. Open TunnelBahn → go to the Profiles tab.
2. Delete each affected profile (the app will remove its stale keychain reference).
3. Re-import from the original `.conf` files — `WireGuardConfigParser` writes the
   private key into the keychain as part of the import flow.
4. Connect again.

**How to diagnose in logs:**

```
log stream --level debug --predicate 'subsystem BEGINSWITH "com.tunnelbahn"'
```

Look for:
- `Signature check failed: code failed to satisfy specified code requirement(s)` —
  from `com.apple.networkextension:`; usually cosmetic, does not block the extension.
- `Started with error Keychain operation failed with status: -25300` — this is the
  real failure: private key not found.
- `Keychain operation failed with status: -25300` in the host app's error message —
  the `tunnelConnectFailureMessage` path.

The built-in guard (`ProfileStore.runKeychainIntegrityCheck()`) runs at startup and
will show an alert if any loaded profile has a broken keychain reference.

---

## Tunnel shows error briefly, then connects

**Symptom:** The app briefly shows "VPN packet-tunnel extension failed to start (Plugin
failed)" or "Tunnel did not connect (NEVPN disconnected)", then the tunnel connects on
its own a second later.

**Root cause:** Race condition in `waitForTunnelConnectOutcome`. After `startVPNTunnel()`
is called, `NETunnelProviderManager` (especially `forPerAppVPN`) briefly stays in the
`.disconnected` state while the NE daemon processes the request. The host app's wait loop
used to treat that initial `.disconnected` as an immediate failure.

**Fix applied (2026-05-19):** A startup grace period was added before the wait loop
treats `.disconnected` as a hard failure. Initially 1 s; raised to 3 s (2026-05-19) to
cover slower Macs and heavier on-demand configs without causing false teardowns.
See `VPNManager.waitForTunnelConnectOutcome` and `VPNManager.finishConnectAfterDeferredTunnelWait`.

If this reappears, check that the grace period is still in place in both functions:

```swift
// VPNManager.swift
let graceDeadline = Date().addingTimeInterval(3.0)
// ...
if (status == .disconnected || status == .invalid), Date() > graceDeadline {
    return .failed
}
```

---

## App group ID change — what breaks and how to recover

`AppConstants.appGroupID` is the identifier shared by all three targets (TunnelBahn,
PacketTunnelExtension, TransparentProxyExtension) for their shared container. Changing
it is **destructive**:

| What breaks | Why |
|---|---|
| All profiles vanish | `ProfileStore` reads/writes `UserDefaults(suiteName: appGroupID)` — different ID = different suite = empty |
| Routing settings vanish | Same UserDefaults suite |
| `vpn-state.json` not found | `SharedPaths` functions derive paths from the container URL |
| Private keys orphaned | Profiles in the new container have new `privateKeyRef` UUIDs; old keychain items exist under old UUIDs |

The keychain access group (`$(AppIdentifierPrefix)com.tunnelbahn.mac`, i.e.
`92G3VZAPVG.com.tunnelbahn.mac`) is **not** tied to the app group ID — it uses the team
ID prefix and remains stable across app group renames. Old keychain items are still
technically accessible; they just aren't looked up because their accounts (UUIDs) no
longer match anything in the new container's profiles.

**Migration history:**

| Commit | App Group ID |
|---|---|
| `3c9b7b1` (AppSplitWG era) | `92G3VZAPVG.group.com.appsplit.wg` |
| `6f32874` (TunnelBahn rename) | `92G3VZAPVG.group.com.tunnelbahn.mac` |
| `8a39c7f` (App Store readiness) | `group.com.tunnelbahn.mac` ← current |

If you must change the app group ID again:
1. Update `AppConstants.appGroupID` in `Shared/Constants.swift`.
2. Update `com.apple.security.application-groups` in all three `.entitlements` files.
3. Register the new group in the Apple Developer Portal under the team `92G3VZAPVG`.
4. Re-run `xcodegen generate` and rebuild.
5. Inform users they must delete and re-import all WireGuard profiles.
