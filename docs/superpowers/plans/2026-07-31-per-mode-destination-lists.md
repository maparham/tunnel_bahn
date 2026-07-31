# Per-Mode Destination Lists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each destination-filtering mode ("Tunnel only selected destinations" / "Tunnel all except selected") its own independent bulk lists, custom ranges, domain names, and section toggles, with an Option-A UI where the mode radios swap the sections in place and a tinted glyph identifies the mode.

**Architecture:** `DestinationRuleStore` becomes mode-keyed (two `DestinationModeRuleSet`s; the published arrays always surface the currently edited mode). `AppSettings` holds per-mode section toggles. `ProfileRoutingSnapshot` carries both modes' sets and toggles. The connect path flattens only the active mode's set. UI stays a single stack; radios select the mode, glyphs (blue `plus.circle` / orange `minus.circle`) mark whose lists are shown.

**Tech Stack:** Swift 5.10, SwiftUI, Combine, XCTest. Project generated with `xcodegen generate` from `project.yml`. Unit tests: `xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests`.

**Spec:** `docs/superpowers/specs/2026-07-31-per-mode-destination-lists-design.md`

## Global Constraints

- **No legacy code / no migrations** (repo policy): the old `destinationCidrRules` UserDefaults key and old snapshot shape are abandoned, not migrated. Both modes start empty. No tolerant decoding, no schemaVersion fields.
- **UI strings:** never use em dashes. Tooltips: one or two short sentences, via the `Image(systemName: "questionmark.circle")` + `.instantTooltip(...)` idiom, never inline footnote text.
- **Standing repo rule:** ask the user before the FIRST `xcodebuild` invocation of the session. Once they approve, run the test commands in the steps normally. `xcodebuild test -only-testing:TunnelBahnUnitTests` builds only the app target + test bundle; it does not deploy the system extension.
- After ANY edit to `project.yml`, run `xcodegen generate` before building.
- Renamed UI copy: "Tunnel selected destinations" becomes "Tunnel only selected destinations".

---

### Task 1: Models — `DestinationModeRuleSet`, `DestinationSectionToggles`, new `ProfileRoutingSnapshot` shape

**Files:**
- Create: `TunnelBahn/Models/DestinationModeRuleSet.swift`
- Create: `TunnelBahn/Models/DestinationSectionToggles.swift`
- Rewrite: `TunnelBahn/Models/ProfileRoutingSnapshot.swift`
- Modify: `project.yml` (add the two new model files to `TunnelBahnUnitTests.sources`)
- Test: `Tests/Unit/ProfileRoutingSnapshotCodecTests.swift`

**Interfaces:**
- Produces: `struct DestinationModeRuleSet: Codable, Equatable { var customRules: [DestinationCidrRule]; var bulkGroups: [DestinationCidrBulkGroup]; var domainRules: [DestinationDomainRule] }` (all default `[]`).
- Produces: `struct DestinationSectionToggles: Codable, Equatable { var bulkLists: Bool; var customRanges: Bool; var domainNames: Bool }` (all default `true`).
- Produces: `ProfileRoutingSnapshot` with fields `routingMode`, `enforceDestinationFiltering`, `appRules`, `include: DestinationModeRuleSet`, `exclude: DestinationModeRuleSet`, `includeToggles: DestinationSectionToggles`, `excludeToggles: DestinationSectionToggles`, `filterMode: DestinationFilterMode`, `resolveDNSLocally: Bool`, and `static var default`. The old fields (`customCidrRules`, `bulkGroups`, `domainRules`, `bulkListsEnabled`, `customRangesEnabled`, `domainNamesEnabled`) are GONE.
- **Build note:** reshaping the snapshot breaks compilation at old call sites (AppState, BackupService, RoutingView) until Tasks 2–3 land. That is expected: Tasks 1–3 are one build-restoring sequence, each commit scoped for review. Do NOT run xcodebuild in this task; the first test run happens in Task 2/3.

- [ ] **Step 1: Write the new model files**

`TunnelBahn/Models/DestinationModeRuleSet.swift`:

```swift
import Foundation

/// One filtering mode's complete destination rule set. Each `DestinationFilterMode`
/// (include / exclude) owns an independent instance; they never share entries.
struct DestinationModeRuleSet: Codable, Equatable {
    var customRules: [DestinationCidrRule] = []
    var bulkGroups: [DestinationCidrBulkGroup] = []
    var domainRules: [DestinationDomainRule] = []
}
```

`TunnelBahn/Models/DestinationSectionToggles.swift`:

```swift
import Foundation

/// Per-mode enable/disable state of the three destination sections in RoutingView.
/// Stored per `DestinationFilterMode` alongside that mode's rule set.
struct DestinationSectionToggles: Codable, Equatable {
    var bulkLists = true
    var customRanges = true
    var domainNames = true
}
```

- [ ] **Step 2: Rewrite `ProfileRoutingSnapshot.swift`**

Replace the whole file body with:

```swift
import Foundation

struct ProfileRoutingSnapshot: Codable {
    var routingMode: RoutingMode
    var enforceDestinationFiltering: Bool
    var appRules: [AppRule]
    /// "Tunnel only selected destinations" rule set.
    var include: DestinationModeRuleSet
    /// "Tunnel all except selected" rule set.
    var exclude: DestinationModeRuleSet
    var includeToggles: DestinationSectionToggles
    var excludeToggles: DestinationSectionToggles
    var filterMode: DestinationFilterMode
    /// Profile-wide: suppress the tunnel-DNS redirect so routed apps resolve via the
    /// local resolver (better direct/domestic CDN steering; local DNS filtering applies).
    var resolveDNSLocally: Bool

    static var `default`: ProfileRoutingSnapshot {
        ProfileRoutingSnapshot(
            routingMode: .fullTunnel,
            enforceDestinationFiltering: false,
            appRules: [],
            include: DestinationModeRuleSet(),
            exclude: DestinationModeRuleSet(),
            includeToggles: DestinationSectionToggles(),
            excludeToggles: DestinationSectionToggles(),
            filterMode: .include,
            resolveDNSLocally: false
        )
    }
}
```

(The memberwise initializer replaces the old hand-written one; all call sites use labels and are updated in Task 3.)

- [ ] **Step 3: Add the new model files to the unit-test target in `project.yml`**

In `TunnelBahnUnitTests.sources` (currently ends at `TunnelBahn/Models/DestinationDomainRule.swift`), append:

```yaml
      - path: TunnelBahn/Models/DestinationModeRuleSet.swift
      - path: TunnelBahn/Models/DestinationSectionToggles.swift
```

Then run: `xcodegen generate`

- [ ] **Step 4: Update the snapshot codec tests**

Replace the body of `Tests/Unit/ProfileRoutingSnapshotCodecTests.swift` with:

```swift
import XCTest

final class ProfileRoutingSnapshotCodecTests: XCTestCase {
    func testDefaultSnapshotIsIncludeWithTunnelDNSAndEmptySets() {
        let s = ProfileRoutingSnapshot.default
        XCTAssertEqual(s.filterMode, .include)
        XCTAssertFalse(s.resolveDNSLocally)
        XCTAssertEqual(s.include, DestinationModeRuleSet())
        XCTAssertEqual(s.exclude, DestinationModeRuleSet())
        XCTAssertEqual(s.includeToggles, DestinationSectionToggles())
        XCTAssertEqual(s.excludeToggles, DestinationSectionToggles())
    }

    func testSnapshotRoundTripsBothModeSetsAndToggles() throws {
        var s = ProfileRoutingSnapshot.default
        s.filterMode = .exclude
        s.resolveDNSLocally = true
        s.include.customRules = [DestinationCidrRule(cidr: "10.66.0.0/16")]
        s.exclude.bulkGroups = [DestinationCidrBulkGroup(title: "country-ir", cidrs: ["5.22.0.0/16"])]
        s.exclude.domainRules = [DestinationDomainRule(domain: "digikala.com")]
        s.includeToggles.domainNames = false
        s.excludeToggles.bulkLists = false
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(ProfileRoutingSnapshot.self, from: data)
        XCTAssertEqual(decoded.filterMode, .exclude)
        XCTAssertTrue(decoded.resolveDNSLocally)
        XCTAssertEqual(decoded.include, s.include)
        XCTAssertEqual(decoded.exclude, s.exclude)
        XCTAssertEqual(decoded.includeToggles, s.includeToggles)
        XCTAssertEqual(decoded.excludeToggles, s.excludeToggles)
    }
}
```

Note: `DestinationDomainRule`'s Codable omits ephemeral `status`; `Equatable` compares it, and both sides decode to `.pending` or recomputed state. If the round-trip equality fails on `status`, compare fields individually (`domain`, `resolvedCidrs`, `isEnabled`) instead of whole-struct equality.

- [ ] **Step 5: Commit**

```bash
git add TunnelBahn/Models/DestinationModeRuleSet.swift TunnelBahn/Models/DestinationSectionToggles.swift TunnelBahn/Models/ProfileRoutingSnapshot.swift project.yml Tests/Unit/ProfileRoutingSnapshotCodecTests.swift TunnelBahn.xcodeproj
git commit -m "feat(routing): per-mode rule set and toggle models; reshape ProfileRoutingSnapshot"
```

(The tree does not build yet; Tasks 2–3 restore it. Do not run tests in this task.)

---

### Task 2: Mode-keyed `DestinationRuleStore` + unit tests

**Files:**
- Rewrite (in place): `TunnelBahn/Services/DestinationRuleStore.swift`
- Modify: `project.yml` (add store + parser + AppGroup to `TunnelBahnUnitTests.sources`)
- Create: `Tests/Unit/DestinationRuleStorePerModeTests.swift`

**Interfaces:**
- Consumes: `DestinationModeRuleSet`, `DestinationSectionToggles` (Task 1).
- Produces (new/changed API on `DestinationRuleStore`):
  - `init(defaults: UserDefaults = AppGroupStore.defaults)`
  - `@Published private(set) var editedMode: DestinationFilterMode` (starts `.include`)
  - `func setEditedMode(_ mode: DestinationFilterMode)`
  - `func ruleSet(for mode: DestinationFilterMode) -> DestinationModeRuleSet`
  - `func replaceAll(include: DestinationModeRuleSet, exclude: DestinationModeRuleSet)` (domain-rule union merge per mode; replaces old `replaceAll(customRules:bulkGroups:domainRules:)`)
  - `func replaceRules(for mode: DestinationFilterMode, customRules: [DestinationCidrRule], bulkGroups: [DestinationCidrBulkGroup], domainRules: [DestinationDomainRule])` (no merge; used by test-URL handlers)
  - `func enabledFlattenedCidrs(for mode: DestinationFilterMode, toggles: DestinationSectionToggles) -> [String]`
  - `func enabledDomainNames(for mode: DestinationFilterMode, toggles: DestinationSectionToggles) -> [String]`
  - Everything else (`addRule`, `importCidrLines`, `removeRule`, `removeBulkGroup`, `renameBulkGroup`, `setEnabled`, `setBulkGroupEnabled`, domain mutators, resolution mutators, `updateCidr`, `matchingDestinationListLabels`) keeps its signature and operates on the edited mode's published arrays.
- Persistence: single JSON payload `{"include": ModeRuleSet, "exclude": ModeRuleSet}` under new key `destinationRulesByMode`. The old `destinationCidrRules` key is never read or written.

- [ ] **Step 1: Add store dependencies to the unit-test target**

In `project.yml` `TunnelBahnUnitTests.sources`, append:

```yaml
      - path: TunnelBahn/Services/DestinationRuleStore.swift
      - path: TunnelBahn/Services/DestinationCidrTextParser.swift
      - path: Shared/AppGroup.swift
```

Run: `xcodegen generate`

(`Shared/AppGroup.swift` compiles in the test bundle because `AppGroupStore.defaults` falls back to `.standard` when the App Group container is unavailable, and its `SharedPaths`/`AppConstants` references live in `Shared/Constants.swift`, already a test source.)

- [ ] **Step 2: Write the failing tests**

Create `Tests/Unit/DestinationRuleStorePerModeTests.swift`:

```swift
import XCTest

@MainActor
final class DestinationRuleStorePerModeTests: XCTestCase {
    private static let suiteName = "DestinationRuleStorePerModeTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func makeStore() -> DestinationRuleStore {
        DestinationRuleStore(defaults: defaults)
    }

    func testStoreStartsEmptyInIncludeMode() {
        let store = makeStore()
        XCTAssertEqual(store.editedMode, .include)
        XCTAssertTrue(store.customRules.isEmpty)
        XCTAssertTrue(store.bulkGroups.isEmpty)
        XCTAssertTrue(store.domainRules.isEmpty)
    }

    func testAddRuleIsScopedToEditedMode() {
        let store = makeStore()
        XCTAssertTrue(store.addRule(cidr: "10.0.0.0/8"))
        store.setEditedMode(.exclude)
        XCTAssertTrue(store.customRules.isEmpty, "exclude set must not see include's rule")
        store.setEditedMode(.include)
        XCTAssertEqual(store.customRules.map(\.cidr), ["10.0.0.0/8"])
    }

    func testSameCidrAllowedInBothModes() {
        let store = makeStore()
        XCTAssertTrue(store.addRule(cidr: "10.0.0.0/8"))
        store.setEditedMode(.exclude)
        XCTAssertTrue(store.addRule(cidr: "10.0.0.0/8"), "dedup must be scoped per mode")
        XCTAssertFalse(store.addRule(cidr: "10.0.0.0/8"), "dedup still applies within a mode")
    }

    func testImportAndDomainScopedPerMode() {
        let store = makeStore()
        let result = store.importCidrLines(from: "1.1.1.0/24\n2.2.2.0/24", bulkTitle: "listA")
        XCTAssertEqual(result.added, 2)
        XCTAssertTrue(store.addDomainRule(domain: "x.com"))
        store.setEditedMode(.exclude)
        XCTAssertTrue(store.bulkGroups.isEmpty)
        XCTAssertTrue(store.domainRules.isEmpty)
        let result2 = store.importCidrLines(from: "1.1.1.0/24", bulkTitle: "listB")
        XCTAssertEqual(result2.added, 1, "duplicate detection must not cross modes")
        XCTAssertTrue(store.addDomainRule(domain: "x.com"), "domain dedup must not cross modes")
    }

    func testPersistenceRoundTripsBothModes() {
        let store = makeStore()
        XCTAssertTrue(store.addRule(cidr: "10.0.0.0/8"))
        store.setEditedMode(.exclude)
        _ = store.importCidrLines(from: "5.22.0.0/16", bulkTitle: "country-ir")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.editedMode, .include)
        XCTAssertEqual(reloaded.customRules.map(\.cidr), ["10.0.0.0/8"])
        reloaded.setEditedMode(.exclude)
        XCTAssertEqual(reloaded.bulkGroups.map(\.title), ["country-ir"])
        XCTAssertTrue(reloaded.customRules.isEmpty)
    }

    func testEnabledFlattenedCidrsReadsRequestedModeOnly() {
        let store = makeStore()
        XCTAssertTrue(store.addRule(cidr: "10.0.0.0/8"))
        store.setEditedMode(.exclude)
        XCTAssertTrue(store.addRule(cidr: "5.22.0.0/16"))

        let toggles = DestinationSectionToggles()
        XCTAssertEqual(store.enabledFlattenedCidrs(for: .include, toggles: toggles), ["10.0.0.0/8"])
        XCTAssertEqual(store.enabledFlattenedCidrs(for: .exclude, toggles: toggles), ["5.22.0.0/16"])

        var noCustom = toggles
        noCustom.customRanges = false
        XCTAssertEqual(store.enabledFlattenedCidrs(for: .include, toggles: noCustom), [])
    }

    func testReplaceAllMergesDomainResolvedCidrsPerMode() {
        let store = makeStore()
        XCTAssertTrue(store.addDomainRule(domain: "x.com"))
        let id = store.domainRules[0].id
        store.applyResolution(id: id, cidrs: ["1.2.3.4/32"], ttl: 30)

        // Incoming snapshot copy of the same rule with a DIFFERENT resolved IP: union, never shrink.
        var incoming = DestinationModeRuleSet()
        var rule = DestinationDomainRule(id: id, domain: "x.com")
        rule.resolvedCidrs = ["5.6.7.8/32"]
        incoming.domainRules = [rule]
        store.replaceAll(include: incoming, exclude: DestinationModeRuleSet())

        XCTAssertEqual(Set(store.domainRules[0].resolvedCidrs), ["1.2.3.4/32", "5.6.7.8/32"])
        store.setEditedMode(.exclude)
        XCTAssertTrue(store.domainRules.isEmpty)
    }

    func testReplaceRulesTargetsRequestedMode() {
        let store = makeStore()
        store.replaceRules(
            for: .exclude,
            customRules: [DestinationCidrRule(cidr: "5.22.0.0/16")],
            bulkGroups: [],
            domainRules: []
        )
        XCTAssertTrue(store.customRules.isEmpty, "include (edited) set untouched")
        store.setEditedMode(.exclude)
        XCTAssertEqual(store.customRules.map(\.cidr), ["5.22.0.0/16"])
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/DestinationRuleStorePerModeTests 2>&1 | tail -20`
Expected: compile failure (`DestinationRuleStore` has no `defaults:` initializer, no `setEditedMode`). That is the failing state for a rework task.

- [ ] **Step 4: Rework `DestinationRuleStore.swift`**

Keep the file's existing structure and comments where untouched; the changes are:

Replace the persisted payload struct and stored properties:

```swift
private struct DestinationRulesByModePersisted: Codable {
    var include: DestinationModeRuleSet
    var exclude: DestinationModeRuleSet
}

@MainActor
final class DestinationRuleStore: ObservableObject {
    /// The currently edited mode's rules. All published arrays and every mutator refer to
    /// `editedMode`'s set; the other mode's set is parked in `offModeSet`.
    @Published private(set) var customRules: [DestinationCidrRule] = []
    @Published private(set) var bulkGroups: [DestinationCidrBulkGroup] = []
    @Published private(set) var domainRules: [DestinationDomainRule] = []
    @Published private(set) var editedMode: DestinationFilterMode = .include

    /// The not-currently-edited mode's complete rule set.
    private var offModeSet = DestinationModeRuleSet()

    private let defaultsKey = "destinationRulesByMode"
    private let defaults: UserDefaults

    // (keep the existing cachedRulesFingerprint / cachedBulkFingerprint / cachedCustomPrepared /
    //  cachedBulkPrepared properties unchanged — they key off the published arrays, which now
    //  means "the edited mode's arrays", exactly what matchingDestinationListLabels wants.)

    init(defaults: UserDefaults = AppGroupStore.defaults) {
        self.defaults = defaults
        load()
    }
```

Add mode plumbing:

```swift
    /// Swap the published arrays to `mode`'s set. Pure view-of-data switch; content unchanged, no save().
    func setEditedMode(_ mode: DestinationFilterMode) {
        guard mode != editedMode else { return }
        let outgoing = DestinationModeRuleSet(customRules: customRules, bulkGroups: bulkGroups, domainRules: domainRules)
        let incoming = offModeSet
        offModeSet = outgoing
        editedMode = mode
        customRules = incoming.customRules
        bulkGroups = incoming.bulkGroups
        domainRules = incoming.domainRules
    }

    func ruleSet(for mode: DestinationFilterMode) -> DestinationModeRuleSet {
        mode == editedMode
            ? DestinationModeRuleSet(customRules: customRules, bulkGroups: bulkGroups, domainRules: domainRules)
            : offModeSet
    }
```

Replace `replaceAll` (keep the never-remove domain-merge comment, now applied per mode):

```swift
    func replaceAll(include: DestinationModeRuleSet, exclude: DestinationModeRuleSet) {
        var mergedInclude = include
        mergedInclude.domainRules = Self.mergedDomainRules(
            incoming: include.domainRules, existing: ruleSet(for: .include).domainRules
        )
        var mergedExclude = exclude
        mergedExclude.domainRules = Self.mergedDomainRules(
            incoming: exclude.domainRules, existing: ruleSet(for: .exclude).domainRules
        )
        let surfaced = editedMode == .include ? mergedInclude : mergedExclude
        offModeSet = editedMode == .include ? mergedExclude : mergedInclude
        customRules = surfaced.customRules
        bulkGroups = surfaced.bulkGroups
        domainRules = surfaced.domainRules
        save()
    }

    /// Replaces one mode's set verbatim (no domain merge). Test-URL and reset path.
    func replaceRules(
        for mode: DestinationFilterMode,
        customRules: [DestinationCidrRule],
        bulkGroups: [DestinationCidrBulkGroup],
        domainRules: [DestinationDomainRule]
    ) {
        if mode == editedMode {
            self.customRules = customRules
            self.bulkGroups = bulkGroups
            self.domainRules = domainRules
        } else {
            offModeSet = DestinationModeRuleSet(customRules: customRules, bulkGroups: bulkGroups, domainRules: domainRules)
        }
        save()
    }

    private static func mergedDomainRules(
        incoming: [DestinationDomainRule], existing: [DestinationDomainRule]
    ) -> [DestinationDomainRule] {
        incoming.map { incomingRule in
            guard let match = existing.first(where: { $0.id == incomingRule.id || $0.domain == incomingRule.domain }) else {
                return incomingRule
            }
            var merged = incomingRule
            var combined = match.resolvedCidrs
            for cidr in incomingRule.resolvedCidrs where !combined.contains(cidr) {
                combined.append(cidr)
            }
            merged.resolvedCidrs = combined
            merged.resolvedAt = match.resolvedAt ?? incomingRule.resolvedAt
            merged.resolvedTTL = match.resolvedTTL > 0 ? match.resolvedTTL : incomingRule.resolvedTTL
            merged.status = combined.isEmpty ? incomingRule.status : .resolved(cidrCount: combined.count)
            return merged
        }
    }
```

Convert the flatten/domain readers to mode + toggles (delete the old three-Bool-parameter versions):

```swift
    func enabledFlattenedCidrs(for mode: DestinationFilterMode, toggles: DestinationSectionToggles) -> [String] {
        let set = ruleSet(for: mode)
        var seen = Set<String>()
        var out: [String] = []
        func append(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t).inserted else { return }
            out.append(t)
        }
        if toggles.customRanges {
            for rule in set.customRules where rule.isEnabled { append(rule.cidr) }
        }
        if toggles.bulkLists {
            for group in set.bulkGroups where group.isEnabled {
                for c in group.cidrs { append(c) }
            }
        }
        if toggles.domainNames {
            // Include accumulated IPs regardless of transient status (never-remove).
            for rule in set.domainRules where rule.isEnabled {
                for cidr in rule.resolvedCidrs { append(cidr) }
            }
        }
        return out
    }

    func enabledDomainNames(for mode: DestinationFilterMode, toggles: DestinationSectionToggles) -> [String] {
        guard toggles.domainNames else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for rule in ruleSet(for: mode).domainRules where rule.isEnabled {
            let name = rule.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out
    }
```

Replace `save()`/`load()`:

```swift
    private func save() {
        let payload = DestinationRulesByModePersisted(
            include: ruleSet(for: .include),
            exclude: ruleSet(for: .exclude)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let persisted = try? JSONDecoder().decode(DestinationRulesByModePersisted.self, from: data)
        else { return }
        // editedMode is .include at init.
        customRules = persisted.include.customRules
        bulkGroups = persisted.include.bulkGroups
        domainRules = persisted.include.domainRules
        offModeSet = persisted.exclude
    }
```

All other members (`addRule`, `importCidrLines`, `removeRule`, `removeBulkGroup`, `setEnabled`, `setBulkGroupEnabled`, `renameBulkGroup`, domain mutators, resolution mutators, `updateCidr`, `matchingDestinationListLabels`, `refreshPreparedCachesIfNeeded`, `allExistingCidrsTrimmed`) stay byte-identical: they already operate on the published arrays, which are now per-mode by construction.

- [ ] **Step 5: Run the store tests**

Run: `xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/DestinationRuleStorePerModeTests 2>&1 | tail -20`
Expected: note the app target itself still fails to compile (AppState references the old API) — if the test bundle cannot build because the SCHEME builds the app first, defer this run to the end of Task 3 and rely on review; otherwise expect PASS. (The test target lists its own copies of the source files, but it also declares a dependency on the TunnelBahn target, so a broken app target blocks the run. In that case proceed to Task 3 and run both test classes there.)

- [ ] **Step 6: Commit**

```bash
git add TunnelBahn/Services/DestinationRuleStore.swift project.yml TunnelBahn.xcodeproj Tests/Unit/DestinationRuleStorePerModeTests.swift
git commit -m "feat(routing): mode-keyed DestinationRuleStore with per-mode persistence"
```

---

### Task 3: Host wiring — AppSettings, AppState, TunnelBahnApp, BackupService

**Files:**
- Modify: `TunnelBahn/Services/AppSettings.swift:42-52`
- Modify: `TunnelBahn/AppState.swift` (bindings ~130-175, `installRoutingSnapshot` ~210-230, `saveSnapshot` ~241-269, connect paths ~293-353, `logDomainResolutionForConnect` ~362, `resetAll` ~396-401, `syncDestinationRoutingFileWithPreferences` ~434-444, `pushDestinationRangesToProxyIfConnected` ~479-483)
- Modify: `TunnelBahn/TunnelBahnApp.swift:41-45, 372-392, 458-460`
- Modify: `TunnelBahn/Services/BackupService.swift:106-127, 315-329`
- Test: existing suites (`TunnelBahnUnitTests` all)

**Interfaces:**
- Consumes: Task 1 models, Task 2 store API.
- Produces on `AppSettings` (replacing `destinationBulkListsEnabled` / `destinationCustomRangesEnabled` / `destinationDomainNamesEnabled`):
  - `@Published var includeSectionToggles = DestinationSectionToggles()`
  - `@Published var excludeSectionToggles = DestinationSectionToggles()`
  - `func sectionToggles(for mode: DestinationFilterMode) -> DestinationSectionToggles`
  - `func setSectionToggles(_ toggles: DestinationSectionToggles, for mode: DestinationFilterMode)`
  - `var activeSectionToggles: DestinationSectionToggles { get set }` (keyed by `destinationFilterMode`)

- [ ] **Step 1: AppSettings per-mode toggles**

Replace the three toggle properties (lines 42-49) with:

```swift
    /// Per-mode section toggles. Set by AppState when a profile is selected; not persisted independently.
    @Published var includeSectionToggles = DestinationSectionToggles()
    @Published var excludeSectionToggles = DestinationSectionToggles()
```

Append below `resolveDNSLocally`:

```swift
    func sectionToggles(for mode: DestinationFilterMode) -> DestinationSectionToggles {
        mode == .exclude ? excludeSectionToggles : includeSectionToggles
    }

    func setSectionToggles(_ toggles: DestinationSectionToggles, for mode: DestinationFilterMode) {
        if mode == .exclude { excludeSectionToggles = toggles } else { includeSectionToggles = toggles }
    }

    /// The section toggles of the mode currently selected in `destinationFilterMode`.
    var activeSectionToggles: DestinationSectionToggles {
        get { sectionToggles(for: destinationFilterMode) }
        set { setSectionToggles(newValue, for: destinationFilterMode) }
    }
```

- [ ] **Step 2: AppState — keep store's edited mode in lockstep with the filter mode**

In `bindChildStores()`, add (near the other settings sinks):

```swift
        // The store's published arrays must always show the selected mode's rule set.
        settings.$destinationFilterMode
            .removeDuplicates()
            .sink { [weak self] mode in self?.destinationRuleStore.setEditedMode(mode) }
            .store(in: &cancellables)
```

In the debounced save publisher (lines 134-136), replace the three toggle merges with:

```swift
            .merge(with: settings.$includeSectionToggles.dropFirst().map { _ in () }.eraseToAnyPublisher())
            .merge(with: settings.$excludeSectionToggles.dropFirst().map { _ in () }.eraseToAnyPublisher())
```

- [ ] **Step 3: AppState — snapshot install/save**

`installRoutingSnapshot` (order matters — set the mode before replacing sets so `replaceAll` surfaces the right arrays):

```swift
        settings.routingMode = snapshot.routingMode
        appRuleStore.replaceAll(snapshot.appRules)
        settings.destinationFilterMode = snapshot.filterMode
        destinationRuleStore.setEditedMode(snapshot.filterMode)
        destinationRuleStore.replaceAll(include: snapshot.include, exclude: snapshot.exclude)
        settings.enforceDestinationFiltering = snapshot.enforceDestinationFiltering
        settings.includeSectionToggles = snapshot.includeToggles
        settings.excludeSectionToggles = snapshot.excludeToggles
        settings.resolveDNSLocally = snapshot.resolveDNSLocally
```

`saveSnapshot(for:)` — effective-destination check runs against the ACTIVE mode's set and toggles:

```swift
        let activeToggles = settings.activeSectionToggles
        let activeSet = destinationRuleStore.ruleSet(for: settings.destinationFilterMode)
        let hasEffectiveDestinations =
            (activeToggles.customRanges && activeSet.customRules.contains(where: \.isEnabled))
            || (activeToggles.bulkLists && activeSet.bulkGroups.contains(where: \.isEnabled))
            || (activeToggles.domainNames && activeSet.domainRules.contains(where: \.isEnabled))
        // Never persist enforceDestinationFiltering=true with an empty effective CIDR set —
        // that would silently activate filtering against an empty list on the next connect.
        let enforceFiltering = settings.enforceDestinationFiltering && hasEffectiveDestinations
        let snapshot = ProfileRoutingSnapshot(
            routingMode: settings.routingMode,
            enforceDestinationFiltering: enforceFiltering,
            appRules: appRuleStore.rules,
            include: destinationRuleStore.ruleSet(for: .include),
            exclude: destinationRuleStore.ruleSet(for: .exclude),
            includeToggles: settings.includeSectionToggles,
            excludeToggles: settings.excludeSectionToggles,
            filterMode: settings.destinationFilterMode,
            resolveDNSLocally: settings.resolveDNSLocally
        )
```

- [ ] **Step 4: AppState — connect/sync/push/reset/log call sites**

Every `enabledFlattenedCidrs(customRangesEnabled:bulkListsEnabled:domainNamesEnabled:)` call (in `connectProfile`, `connectProfileForTest`, `syncDestinationRoutingFileWithPreferences`, `pushDestinationRangesToProxyIfConnected`) becomes:

```swift
                destinationCidrStrings: destinationRuleStore.enabledFlattenedCidrs(
                    for: settings.destinationFilterMode,
                    toggles: settings.activeSectionToggles
                ),
```

Every `enabledDomainNames(domainNamesEnabled:)` call becomes:

```swift
                    ? destinationRuleStore.enabledDomainNames(
                        for: settings.destinationFilterMode,
                        toggles: settings.activeSectionToggles
                    )
```

`logDomainResolutionForConnect` guard becomes `guard settings.activeSectionToggles.domainNames else {`.

`resetAll` — replace the store wipe and toggle resets:

```swift
        destinationRuleStore.replaceAll(include: DestinationModeRuleSet(), exclude: DestinationModeRuleSet())
        settings.routingMode = .fullTunnel
        settings.enforceDestinationFiltering = false
        settings.destinationFilterMode = .include
        settings.includeSectionToggles = DestinationSectionToggles()
        settings.excludeSectionToggles = DestinationSectionToggles()
```

- [ ] **Step 5: TunnelBahnApp**

Menu summary (lines 41-45):

```swift
        let cidrs = appState.destinationRuleStore.enabledFlattenedCidrs(
                for: appState.settings.destinationFilterMode,
                toggles: appState.settings.activeSectionToggles
            )
```

Test-URL handlers (372-392) — scope to the active mode via `replaceRules(for:)`:

```swift
        if let rawCidrs = param("setDestinationCIDRs") {
            let cidrs = rawCidrs.split(separator: ",").map(String.init)
            let rules = cidrs.map { DestinationCidrRule(cidr: $0.trimmingCharacters(in: .whitespaces), isEnabled: true) }
            let mode = appState.settings.destinationFilterMode
            let current = appState.destinationRuleStore.ruleSet(for: mode)
            appState.destinationRuleStore.replaceRules(
                for: mode,
                customRules: rules,
                bulkGroups: current.bulkGroups,
                domainRules: current.domainRules
            )
            Self.testURLLog.notice("[APPSPLIT_TEST_URL] set \(rules.count) destination CIDRs")
        }

        if flag("clearDestinationCIDRs") {
            let mode = appState.settings.destinationFilterMode
            let current = appState.destinationRuleStore.ruleSet(for: mode)
            appState.destinationRuleStore.replaceRules(
                for: mode,
                customRules: [],
                bulkGroups: current.bulkGroups,
                domainRules: current.domainRules
            )
            Self.testURLLog.notice("[APPSPLIT_TEST_URL] cleared destination CIDRs")
        }
```

Debug dict (458-460):

```swift
                "destinationCidrCount": appState.destinationRuleStore.customRules.count,
                "destinationBulkListsEnabled": appState.settings.activeSectionToggles.bulkLists,
                "destinationCustomRangesEnabled": appState.settings.activeSectionToggles.customRanges
```

- [ ] **Step 6: BackupService strip logic**

Export path (lines 108-119):

```swift
                    if !options.includeAppRouting {
                        raw.appRules = []
                    }
                    if !options.includeDestinationRouting {
                        raw.include = DestinationModeRuleSet()
                        raw.exclude = DestinationModeRuleSet()
                        raw.enforceDestinationFiltering = false
                        raw.includeToggles = DestinationSectionToggles()
                        raw.excludeToggles = DestinationSectionToggles()
                    }
```

Import path (`buildImportSnapshot`, lines 321-326): same replacement for the `!options.includeDestinationRouting` branch (keep `snapshot.appRules = []` handling as is).

- [ ] **Step 7: Minimal RoutingView rename (compile fix only)**

`RoutingView.swift` still references the deleted `destinationBulkListsEnabled` / `destinationCustomRangesEnabled` / `destinationDomainNamesEnabled` and would fail the build. To keep Task 3 independently verifiable, apply ONLY the rename here (all layout changes wait for Task 4): replace the three computed vars and three bindings at `RoutingView.swift:16-46` and the three assignments at `:171-173` with `activeSectionToggles` field access, i.e. read/write `appState.settings.activeSectionToggles.bulkLists` / `.customRanges` / `.domainNames` (the binding setters keep their existing "auto-enable enforcement when re-enabling a section with enabled rules" bodies).

- [ ] **Step 8: Full unit-test run**

Run: `xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests 2>&1 | tail -30`
Expected: BUILD + TEST PASS (all suites, including the Task 1 codec tests and Task 2 store tests).

- [ ] **Step 9: Commit**

```bash
git add TunnelBahn/Services/AppSettings.swift TunnelBahn/AppState.swift TunnelBahn/TunnelBahnApp.swift TunnelBahn/Services/BackupService.swift TunnelBahn/Views/RoutingView.swift
git commit -m "feat(routing): wire per-mode rule sets and toggles through settings, snapshots, connect path"
```

---

### Task 4: RoutingView — Option A layout with mode glyphs

**Files:**
- Modify: `TunnelBahn/Views/RoutingView.swift`

**Interfaces:**
- Consumes: `settings.activeSectionToggles`, `settings.destinationFilterMode`, `destinationRuleStore.ruleSet(for:)` (mode swap of published arrays happens automatically via the AppState sink from Task 3).
- Produces: UI only. Mode glyph convention used app-wide from now on: include = `plus.circle` tinted `.blue`, exclude = `minus.circle` tinted `.orange`.

Behavior contract (from spec + mockup):
1. Radio label rename: "Tunnel only selected destinations".
2. Include/exclude radios are always clickable (not gated on `hasAnyDestinations`); exclude still disabled in full-tunnel routing mode and while editing is locked.
3. Selecting a mode whose set is empty: lists swap, the blue hint shows, `enforceDestinationFiltering` stays/turns off. When the first effective destination appears while that mode is selected, enforcement turns on automatically.
4. Selecting "Tunnel all destinations": enforcement off; sections stay visible showing the last-selected mode's lists, dimmed and read-only.
5. Every section header (Bulk lists / Custom ranges / Domain names) leads with the current mode's glyph; each mode radio label carries its glyph.
6. Warning banner keeps its per-mode wording; when "Tunnel all destinations" is selected it reads "All network traffic is tunneled. Destination lists are inactive."

- [ ] **Step 1: Selection-state model**

The chosen radio must be distinguishable from enforcement (an empty-set mode can be selected while enforcement is off). Add:

```swift
    /// A mode radio the user selected while its rule set is empty: lists are shown and editable,
    /// but enforcement stays off until the first effective destination exists. nil when the
    /// selected radio state is fully captured by enforceDestinationFiltering + filterMode.
    @State private var previewedEmptyMode: DestinationFilterMode?

    /// Which mode's lists the sections display (always follows the filter mode).
    private var displayedMode: DestinationFilterMode { appState.settings.destinationFilterMode }

    /// True when "Tunnel all destinations" is the selected radio: sections dim and lock.
    private var destinationSectionsInactive: Bool {
        !appState.settings.enforceDestinationFiltering && previewedEmptyMode == nil
    }
```

Radio `isOn` states:

```swift
    // Tunnel all destinations:
    isOn: !appState.settings.enforceDestinationFiltering && previewedEmptyMode == nil
    // Tunnel only selected destinations:
    isOn: (appState.settings.enforceDestinationFiltering && displayedMode == .include) || previewedEmptyMode == .include
    // Tunnel all except selected (keep the fullTunnel clause):
    isOn: ((appState.settings.enforceDestinationFiltering && displayedMode == .exclude) || previewedEmptyMode == .exclude)
        && appState.settings.routingMode != .fullTunnel
```

Radio actions:

```swift
    private func selectTunnelAll() {
        previewedEmptyMode = nil
        appState.settings.enforceDestinationFiltering = false
        appState.settings.activeSectionToggles = DestinationSectionToggles(
            bulkLists: false, customRanges: false, domainNames: false
        )  // preserves the existing "deselecting filtering turns sections off" behavior, per mode
    }

    private func selectMode(_ mode: DestinationFilterMode) {
        appState.settings.destinationFilterMode = mode  // AppState sink swaps the store's arrays
        if hasAnyDestinations {  // now evaluates against the newly displayed mode
            appState.settings.enforceDestinationFiltering = true
            previewedEmptyMode = nil
        } else {
            appState.settings.enforceDestinationFiltering = false
            previewedEmptyMode = mode
        }
    }
```

And auto-arm on first entry — extend the existing `.onChange(of: hasAnyDestinations)`:

```swift
        .onChange(of: hasAnyDestinations) { _, hasAny in
            if !hasAny {
                appState.settings.enforceDestinationFiltering = false
            } else if previewedEmptyMode == displayedMode {
                appState.settings.enforceDestinationFiltering = true
                previewedEmptyMode = nil
            }
        }
```

(Keep the `.onAppear` enforcement auto-off; also clear `previewedEmptyMode` in `normalizeExcludeModeForRoutingMode()` when it collapses `.exclude` to `.include`.)

`hasAnyDestinations` / `hasAnyRulesIgnoringSectionToggles` now read `appState.settings.activeSectionToggles` fields plus the store's published arrays (which are the displayed mode's — unchanged code otherwise). The old `destinationFilteringBinding` is replaced by the two action funcs above (delete it and inline `enforceDestinationFiltering` writes).

- [ ] **Step 2: Glyphs and labels**

Add a helper:

```swift
    private func modeGlyph(_ mode: DestinationFilterMode) -> some View {
        Image(systemName: mode == .include ? "plus.circle" : "minus.circle")
            .foregroundStyle(mode == .include ? Color.blue : Color.orange)
            .imageScale(.medium)
            .accessibilityLabel(mode == .include ? "Tunnel only selected" : "Tunnel all except selected")
    }
```

- In `restrictProxySection()`: rename the include radio's label to `"Tunnel only selected destinations"`; insert `modeGlyph(.include)` directly after the include radio's label (before the questionmark icon) and `modeGlyph(.exclude)` after the exclude radio's label. Radios call `selectTunnelAll()` / `selectMode(.include)` / `selectMode(.exclude)`. Remove `|| !hasAnyDestinations` from both mode radios' `disabled:`.
- The blue hint moves below the radio row and shows when `previewedEmptyMode != nil` (same two strings as today, chosen by `hasAnyRulesIgnoringSectionToggles`).
- In `bulkListsStandaloneSection()`, `customRangesStandaloneSection()`, `domainNamesSection()`: insert `modeGlyph(displayedMode)` as the first element of the header `HStack`, before the section title.

- [ ] **Step 3: Dim/lock sections and banner for "Tunnel all destinations"**

- Where sections compute `controlsDisabled:`/`disabled:` from `destinationRoutingEditingLocked || !<toggle>`, add `|| destinationSectionsInactive`. Apply `.opacity(destinationSectionsInactive ? 0.5 : 1)` to the sections `VStack` (the one wrapping the three sections + banner).
- Banner text:

```swift
                        Text(destinationSectionsInactive
                            ? "All network traffic is tunneled. Destination lists are inactive."
                            : (displayedMode == .exclude
                                ? "IPs matching a list here will **bypass the tunnel**; everything else is tunneled."
                                : "IPs not matching any list here will **bypass the tunnel**."))
```

  (Note the existing exclude condition `appState.settings.enforceDestinationFiltering && ... == .exclude` simplifies to `displayedMode == .exclude` since the inactive case is handled first.)
- Tooltip `selectedDestinationsTooltip` keeps its text; check all touched tooltips for em dashes (none may be introduced).

- [ ] **Step 4: Build and behavior check**

Run: `xcodebuild build -scheme TunnelBahn -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

Manual smoke (app run, no tunnel needed): add a CIDR in include mode; click "Tunnel all except selected" — sections must swap to empty exclude lists with orange minus glyphs, hint visible, enforcement off; add a CIDR — enforcement arms; click "Tunnel only selected destinations" — blue plus glyphs and the include list return; click "Tunnel all destinations" — sections dim and lock.

- [ ] **Step 5: Commit**

```bash
git add TunnelBahn/Views/RoutingView.swift
git commit -m "feat(ui): per-mode destination sections with mode glyphs; always-selectable mode radios"
```

---

### Task 5: Final verification sweep

**Files:**
- Test: full `TunnelBahnUnitTests`
- Read-only cross-check against the spec

- [ ] **Step 1: Full unit-test run**

Run: `xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests 2>&1 | tail -30`
Expected: PASS (DestinationRoutingModeTests, ProfileRoutingSnapshotCodecTests, DestinationRuleStorePerModeTests, and the untouched WG/TCP suites).

- [ ] **Step 2: Spec conformance checklist** (verify in code, fix anything missing)

- Old `destinationCidrRules` key: `grep -rn "destinationCidrRules" TunnelBahn Shared` returns nothing.
- Old snapshot fields: `grep -rn "customCidrRules\|bulkListsEnabled\|customRangesEnabled\|domainNamesEnabled" TunnelBahn Shared Tests` returns nothing.
- Connect path passes `for: settings.destinationFilterMode` everywhere flattening happens (4 call sites in AppState, 1 in TunnelBahnApp).
- `saveSnapshot` writes `include:`/`exclude:` from `ruleSet(for:)`, not the published arrays.
- No em dashes in any added UI string: `grep -n "—" TunnelBahn/Views/RoutingView.swift` returns nothing.

- [ ] **Step 3: Runtime verification via the project verify skill**

Invoke the `verify` skill for the RoutingView flow (drive the app: mode switch, add rules per mode, profile switch round-trip). If a tunnel connect is possible, confirm the `destination-routing.json` trace log (`grep "destination routing file written"`) shows only the active mode's range count after switching modes and reconnecting.

- [ ] **Step 4: Commit any fixes**

```bash
git add -A && git commit -m "fix(routing): final sweep fixes from per-mode destination lists verification"
```

(Skip the commit if the sweep found nothing.)
