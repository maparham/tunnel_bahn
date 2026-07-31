# Per-Mode Destination Lists — Design

Date: 2026-07-31
Status: Approved

## Problem

The destination-routing UI offers two filtering modes — "Tunnel only selected destinations"
(`.include`) and "Tunnel all except selected" (`.exclude`) — but both modes read and edit the
same single set of bulk lists, custom ranges, and domain names. The two modes express opposite
intents (a tunnel allowlist vs a bypass list), so sharing one rule set forces the user to
rebuild their lists every time they switch modes.

## Decision Summary

- Each mode owns fully independent rule sets: bulk lists, custom ranges, and domain rules.
- The three section enable/disable toggles (bulk lists, custom ranges, domain names) are also
  stored per mode.
- Both modes start empty. No migration of the existing shared lists (no-legacy-code policy:
  the app is undistributed; the old persisted payload is simply ignored).
- Profile snapshots capture BOTH modes' rule sets and section toggles, plus the active mode.
- UI keeps the single-stack layout (Option A from mockups): the mode radios swap the three
  sections in place. Mode identity is shown by a tinted glyph, not a text label.
- "Tunnel selected destinations" is renamed to "Tunnel only selected destinations".

## Storage

### DestinationRuleStore

Becomes mode-keyed. Internally it holds two independent sets:

```swift
struct ModeRuleSet: Codable {
    var customRules: [DestinationCidrRule]
    var bulkGroups: [DestinationCidrBulkGroup]
    var domainRules: [DestinationDomainRule]
}
```

persisted as one payload `{ include: ModeRuleSet, exclude: ModeRuleSet }` under a new
UserDefaults key `destinationRulesByMode` in the App Group. The old
`destinationCidrRules` key is ignored and no longer written; both modes therefore start empty.

- The store exposes the set for a given `DestinationFilterMode`; published properties surface
  the currently edited mode's rules so existing views keep simple bindings.
- Every mutator (`addRule`, `importCidrLines`, `removeRule`, `removeBulkGroup`,
  `renameBulkGroup`, `setEnabled`, domain-rule mutators, resolution-state mutators,
  `updateCidr`, `replaceAll`) operates on an explicit mode's set — the mode the UI is
  currently editing.
- `replaceAll` (connect/profile-load path) replaces both modes' sets; the domain-rule
  IP-union merge ("never-remove") applies per mode.
- Duplicate detection (`allExistingCidrsTrimmed`, add/import rejection) is scoped to one
  mode's set. The same CIDR or domain may exist in both modes.
- `enabledFlattenedCidrs` / `enabledDomainNames` / `matchingDestinationListLabels` take the
  mode to read (callers pass the active mode).

### AppSettings

`destinationBulkListsEnabled`, `destinationCustomRangesEnabled`,
`destinationDomainNamesEnabled` become per-mode: two persisted values each (one per mode).
The UI binds to the active mode's copies. `destinationFilterMode` is unchanged.

## Profiles and Backup

`ProfileRoutingSnapshot` replaces its single `customCidrRules` / `bulkGroups` / `domainRules`
and single trio of section-toggle booleans with both modes' rule sets and both modes'
toggles, plus the existing `filterMode` (the active mode). No back-compat decoding — the
snapshot type just changes shape (undistributed app).

- Loading a profile restores both sets and both toggle trios; switching mode after load shows
  that profile's other-mode lists.
- Saving a profile captures both sets regardless of which mode is active.
- `BackupService` inherits the new shape via the snapshot's `Codable` conformance.

## Enforcement (connect path)

Unchanged decision logic (`DestinationRouteDecision`, `DestinationRoutingFilePayload`,
transparent-proxy matching). At connect/apply time, `VPNManager`/`AppState` flatten ONLY the
active mode's set (`enabledFlattenedCidrs` / `enabledDomainNames` for
`settings.destinationFilterMode`), so the payload written for the extension is exactly what
that mode's UI shows. Exclude mode remains App-Tunnel-only (`normalizeExcludeModeForRoutingMode`
and the full-tunnel guard stay as they are).

Domain resolution (`domainResolutionCoordinator`) runs against the displayed mode's domain
rules; resolution results are stored into that mode's set.

## UI (RoutingView)

Single-stack layout retained; the mode radios swap the three sections in place.

- **Rename:** radio label becomes "Tunnel only selected destinations".
- **Mode identity:** no glyphs and no "for: <mode>" text labels (glyphs were tried and
  removed by user decision 2026-08-01). The selected radio and the warning banner wording
  are the only mode indicators.
- **Radios always clickable:** the include/exclude radios are no longer disabled when no
  destinations exist (that would be a dead end — a mode's set always starts empty). Selecting
  a mode with an empty set shows the existing blue hint ("Add destination IPs or CIDRs below
  to enable." / "Enable a section below to activate destination filtering.") and enforcement
  stays off (`enforceDestinationFiltering` auto-off) until that mode has an enabled entry —
  the current `hasAnyDestinations` behavior, evaluated per mode.
- **Tunnel all destinations:** sections show the last-viewed mode's lists dimmed and
  read-only (editing requires selecting a specific mode).
- **Warning banner:** keeps its existing per-mode wording (include: "IPs not matching any
  list here will bypass the tunnel."; exclude: "IPs matching a list here will bypass the
  tunnel; everything else is tunneled.").
- Editing lock while viewing the connected profile (`destinationRoutingEditingLocked`) is
  unchanged and applies to whichever mode is displayed.
- Tooltips stay short, use the questionmark + instantTooltip idiom, and contain no em dashes.

## Testing

- Store: per-mode isolation (adding/importing/removing in one mode leaves the other
  untouched), per-mode duplicate scoping, domain-resolution never-remove merge per mode,
  persistence round-trip of the two-set payload.
- Connect path: flattened CIDRs/domains come from the active mode only; switching mode and
  reconnecting switches the payload.
- Snapshot: profile save/load round-trips both modes' sets and toggles; active mode restored.
- Existing `DestinationRoutingModeTests` updated for the new store shape.

## Out of Scope

- Any migration or tolerant decoding of the old single-set payload.
- Changes to proxy-side matching, DNS redirect behavior, or the app-rules (signing ID) system.
- The SSH remote DNS work (separate plan).
