# SSH Remote DNS (SNI-based server-side resolution) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In SSH transport mode, resolve destination hostnames on the **SSH server** (like `ssh -D` SOCKS with remote DNS) instead of locally, so DNS-hijacking/sinkholing networks no longer break tunneled sites.

**Architecture:** The transparent proxy already peeks each flow's TLS ClientHello to make a routing decision (`routeDecider`), and a pure SNI extractor (`TLSClientHelloSNI.serverName`) already exists. Today the proxy discards the SNI and reconnects the SSH `direct-tcpip` channel to the **resolved IP** (`flow.remoteEndpoint`'s hostname, which is an IP the app already resolved locally — and which a hijacking resolver has sinkholed). This plan: in SSH mode, always peek routed-app TCP, and when an SNI name is recovered, hand that **name** (not the IP) to `openFlow → openTCP → direct-tcpip` so the server resolves it. Non-SNI/non-TLS traffic falls back to the current IP path (documented limitation, addressed by a future DNS-over-SSH task).

**Tech Stack:** Swift, Network Extension (`NETransparentProxyProvider`, `NEPacketTunnelProvider`), SwiftNIO SSH (`NIOSSH` `direct-tcpip`), XPC relay between the two extensions.

## Global Constraints

- **No test target.** The repo has no unit-test target and will not add one. Pure-Swift logic is verified with `#if DEBUG` self-checks in `TunnelBahn/DebugSelfChecks.swift` that `assert` at launch; datapath behavior is verified with scenario probes. (Copied from `docs/superpowers/plans/2026-07-23-ssh-transport.md`.)
- **No builds unless the user explicitly asks in that turn** (standing rule). Extension behavior is verified via the S-SSH scenario-probe workflow (set toggles + start the tunnel via the `tunnelbahn://test` URL scheme, then STOP — the user runs the probes), NOT `xcodebuild`.
- **SSH-only behavior change.** Every change here must be gated so WireGuard-mode routing is byte-for-byte unchanged. The WG relay egress (`SmoltcpRelayBridge.openTCP`) expects a numeric IP; it must never be handed a hostname.
- **Fail-closed on drop.** A matched app's traffic must never silently egress on the real interface when the tunnel is up. If a name cannot be resolved server-side, the flow fails, it does not leak.
- **Host-key TOFU is unchanged.** This task does not touch `HostKeyValidator`.

---

## Background: the confirmed root cause

Observed on `2026-07-29` while testing profile `New SSH Profile` (`ec2-user@3.139.146.5:22`, App-Tunnel, apps = Terminal + Chrome):

- SSH transport works: Terminal and Chrome egress `3.139.146.5`; host key TOFU-pinned (`SHA256:QitNkjWc1sAkevLOcqv8RZ+ZQFzPhQqdtI4/qCtxDAE`).
- `youtube.com` fails. From an **untunneled** shell: `dig youtube.com → 10.10.34.36`, and `dig @1.1.1.1 youtube.com → 10.10.34.36` and `dig @8.8.8.8 youtube.com → 10.10.34.36`. The network (`192.168.117.41`) transparently intercepts all DNS and sinkholes `youtube.com` to a private `10.10.34.36`.
- Because SSH mode resolves DNS **locally** (see `docs/superpowers/plans/2026-07-23-ssh-transport.md` Task 7 findings — "DNS-over-TCP is NOT built"), the app connects to the sinkhole IP and the proxy tunnels a connection to `10.10.34.36`, which resolves to nothing server-side. `shouldBypassLocal` additionally treats `10.10.34.36` as LAN (`10.0.0.0/8`) and bypasses it to the real interface.
- The user's working `ssh -D 1080` + Firefox setup succeeds because SOCKS with remote DNS hands the **hostname** to the server. This plan brings that behavior to the app.

## File Structure

- `TransparentProxyExtension/TCPFlowRelay.swift` — **modify.** Capture the SNI during the existing peek; when in SSH remote-DNS mode and an SNI is present, use it as the `openFlow` `remoteHost`. Add a stored `remoteDNS` flag and an `sniName` field.
- `TransparentProxyExtension/TransparentProxyProvider.swift` — **modify.** Enter the peek path for **all** routed-app TCP when SSH remote-DNS is active (today the peek path is entered only in domain-rule "SNI mode"). Thread a `remoteDNSResolution` flag from provider configuration into each `TCPFlowRelay`. Ensure routed-app TCP is not short-circuited by `shouldBypassLocal` before the peek when remote-DNS is active.
- `Shared/RuntimeState.swift` (or wherever `providerConfiguration` runtime state is modeled — confirm in Task 1) — **modify.** Add a `remoteDNSResolution: Bool` field set true when `transport == .ssh`, carried in the provider configuration the proxy reads.
- `TunnelBahn/Services/VPNManager.swift` — **modify.** Populate the new `remoteDNSResolution` flag when building the transparent-proxy provider configuration for an SSH profile.
- `TunnelBahn/DebugSelfChecks.swift` — **modify.** Add `#if DEBUG` self-checks for the SNI-vs-IP target selection helper (pure function), reusing the existing `TLSClientHelloSNI` extractor.
- `docs/superpowers/specs/2026-07-23-ssh-transport-design.md` — **modify.** Add an "as-built" note that SSH mode does server-side DNS via SNI, with the non-TLS limitation and the DNS-over-SSH follow-on.

## Interfaces (shared across tasks)

- Existing, unchanged: `TLSClientHelloSNI.serverName(from data: Data) -> String?` (`TransparentProxyExtension/TCPFlowRelay.swift`). Returns a lowercased hostname or `nil` for non-TLS / truncated / no-SNI / ECH.
- Existing, unchanged: `TransparentProxyRelayClient.shared.openFlow(flowID:remoteHost:remotePort:isTCP:onReceive:onClose:completion:)` — the XPC call that carries the destination to the packet-tunnel extension. `remoteHost` is already a `String`; today it is always an IP.
- Existing, unchanged: `SSHFlowTransport.openTCP(flowID:remoteHost:remotePort:) -> Bool` — opens a `direct-tcpip` channel whose `targetHost` is `remoteHost`. Passing a hostname makes the **server** resolve it.
- New, produced by Task 2, consumed by Task 3: `TCPFlowRelay.remoteDNSTarget(sni: String?, endpoint: NWHostEndpoint) -> String` — returns `sni` when non-nil and non-empty, else `endpoint.hostname` (the IP). Pure and self-check-tested.

---

### Task 1: Carry a `remoteDNSResolution` flag from the app into the transparent-proxy provider configuration

**Files:**
- Modify: the runtime-state / provider-configuration model read by the proxy (confirm exact file: `grep -rn "providerConfiguration" TransparentProxyExtension Shared TunnelBahn`; the SSH transport already stores runtime state there per commit `90d8c3a`).
- Modify: `TunnelBahn/Services/VPNManager.swift` (where the transparent-proxy `providerConfiguration` dictionary is assembled for a connect).

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a `Bool` value in the proxy provider configuration under key `"remoteDNSResolution"`, and a decoded `remoteDNSResolution: Bool` the provider can read in Task 2. Defaults to `false` for WireGuard and legacy configs.

- [ ] **Step 1: Locate the provider-configuration assembly and the proxy-side decode**

Run: `grep -rn "providerConfiguration\|refreshRoutedSigningIdentifiers\|source=providerConfiguration" TransparentProxyExtension TunnelBahn/Services/VPNManager.swift`
Read the write site (app side, `VPNManager`) and the read site (`TransparentProxyProvider.startProxy` / config refresh). Note the exact type used (raw `[String: Any]` dictionary vs a Codable struct).

- [ ] **Step 2: Add the flag on the app side (write)**

In `VPNManager.swift`, where the transparent-proxy provider configuration dictionary is built for a connect, set:

```swift
// Server-side DNS: only SSH mode can resolve names on the far end (via direct-tcpip).
// WireGuard mode must keep local resolution + numeric-IP relay, so gate strictly on transport.
config["remoteDNSResolution"] = (profile.transport == .ssh)
```

(Match the surrounding dictionary-building style; if a Codable struct is used instead, add `var remoteDNSResolution: Bool = false` and set it the same way.)

- [ ] **Step 3: Decode the flag on the proxy side (read)**

In the proxy's configuration read path (where `refreshRoutedSigningIdentifiers` logs `source=providerConfiguration`), decode:

```swift
let remoteDNSResolution = (providerConfiguration["remoteDNSResolution"] as? Bool) ?? false
```

Store it on the provider (add `private var remoteDNSResolution = false`) so Task 2 can read it per flow. Add it to the existing `[FIRSTRUN-DIAG]` log line, e.g. `remoteDNS=\(remoteDNSResolution)`.

- [ ] **Step 4: Read-verify WG is unaffected**

Confirm by reading that the flag defaults to `false` for WireGuard connects (the `profile.transport == .ssh` guard) and that nothing consumes it yet. No behavior change this task.

- [ ] **Step 5: Commit**

```bash
git add TransparentProxyExtension TunnelBahn/Services/VPNManager.swift Shared
git commit -m "feat(ne): carry remoteDNSResolution flag (SSH-only) into transparent-proxy config"
```

---

### Task 2: Add the pure SNI-vs-IP target selector and capture the SNI during the peek

**Files:**
- Modify: `TransparentProxyExtension/TCPFlowRelay.swift` (add `remoteDNS` stored flag, `sniName` field, `remoteDNSTarget` helper; set `sniName` inside `peekFirstChunk`).
- Modify: `TunnelBahn/DebugSelfChecks.swift` (self-checks for `remoteDNSTarget`).

**Interfaces:**
- Consumes: the `remoteDNSResolution` flag (Task 1), passed into `TCPFlowRelay.init` by Task 3.
- Produces: `static func remoteDNSTarget(sni: String?, endpointHostname: String) -> String` and a populated `self.sniName` after the peek, both consumed by Task 3.

- [ ] **Step 1: Add the pure selector helper**

In `TCPFlowRelay.swift`, add:

```swift
/// Server-side-DNS target selection. In SSH remote-DNS mode we prefer the SNI hostname
/// (resolved on the SSH server) over the app-resolved IP, which a hijacking local resolver
/// may have sinkholed. Falls back to the IP when there is no usable SNI (non-TLS, ECH,
/// truncated ClientHello) — that flow keeps today's behavior.
static func remoteDNSTarget(sni: String?, endpointHostname: String) -> String {
    if let sni, !sni.isEmpty { return sni }
    return endpointHostname
}
```

- [ ] **Step 2: Add DEBUG self-checks (this repo's substitute for unit tests)**

In `TunnelBahn/DebugSelfChecks.swift`, add (inside the existing debug self-check runner):

```swift
// SSH remote-DNS target selection.
assert(TCPFlowRelay.remoteDNSTarget(sni: "www.youtube.com", endpointHostname: "10.10.34.36") == "www.youtube.com")
assert(TCPFlowRelay.remoteDNSTarget(sni: nil, endpointHostname: "1.2.3.4") == "1.2.3.4")
assert(TCPFlowRelay.remoteDNSTarget(sni: "", endpointHostname: "1.2.3.4") == "1.2.3.4")
```

- [ ] **Step 3: Store the flag and captured SNI on the relay**

Add stored properties near `routeDecider`:

```swift
/// When true (SSH mode), a recovered SNI name is used as the outbound target so the SSH
/// server resolves it. WG mode leaves this false and always targets the numeric IP.
private let remoteDNS: Bool
/// SNI recovered during the peek (lowercased) or nil. Set once in `peekFirstChunk`.
private var sniName: String?
```

Add `remoteDNS: Bool = false` to `init(...)` and assign `self.remoteDNS = remoteDNS`. (Default `false` keeps every existing call site — including WG — unchanged until Task 3 passes it.)

- [ ] **Step 4: Capture the SNI inside the existing peek**

In `peekFirstChunk(endpoint:)`, immediately after `self.pendingFirstChunk = data`, add:

```swift
if self.remoteDNS {
    self.sniName = TLSClientHelloSNI.serverName(from: data)
    Self.log.debug("SSH remote-DNS peek sni=\(self.sniName ?? "nil") destIP=\(endpoint.hostname) signingID=\(self.signingID)")
}
```

Do not change the existing `routeDecider` call or the tunnel/direct decision here; Task 3 consumes `sniName` at connect time.

- [ ] **Step 5: Read-verify no behavior change yet**

Confirm `remoteDNS` defaults to `false`, `sniName` is only written under `if self.remoteDNS`, and nothing reads `sniName` yet. WG and legacy SSH paths are untouched.

- [ ] **Step 6: Commit**

```bash
git add TransparentProxyExtension/TCPFlowRelay.swift TunnelBahn/DebugSelfChecks.swift
git commit -m "feat(proxy): capture SNI during peek + pure remoteDNSTarget selector (inert)"
```

---

### Task 3: Use the SNI name as the SSH `direct-tcpip` target on the tunnel path

**Files:**
- Modify: `TransparentProxyExtension/TCPFlowRelay.swift` (`connectTunnelAfterPeek`).

**Interfaces:**
- Consumes: `remoteDNSTarget(sni:endpointHostname:)` and `self.sniName` (Task 2).
- Produces: an `openFlow` call whose `remoteHost` is the SNI name when available — the behavior that makes the SSH server resolve remotely.

- [ ] **Step 1: Select the target host in `connectTunnelAfterPeek`**

In `connectTunnelAfterPeek(to endpoint:)`, replace the `remoteHost: endpoint.hostname` argument of the `TransparentProxyRelayClient.shared.openFlow(...)` call with:

```swift
let targetHost = remoteDNS
    ? Self.remoteDNSTarget(sni: sniName, endpointHostname: endpoint.hostname)
    : endpoint.hostname
Self.log.notice("SSH tunnel target signingID=\(self.signingID) host=\(targetHost) port=\(endpoint.port) sni=\(self.sniName ?? "nil") destIP=\(endpoint.hostname)")
```

and pass `remoteHost: targetHost`.

- [ ] **Step 2: Confirm only the SSH tunnel path is affected**

Read-verify: `remoteDNS` is only ever `true` for SSH (Task 1 gate). `connectTunnelAfterPeek` is the SSH/XPC tunnel path (`TransparentProxyRelayClient.openFlow → PacketTunnelRelayServer → SSHFlowTransport.openTCP → direct-tcpip`). The `connectDirectAfterPeek` (bypass) path is NOT modified, so LAN/bypass still uses the IP. `startTunnelConnection` (legacy non-peek WG tunnel path) is NOT modified.

- [ ] **Step 3: Commit**

```bash
git add TransparentProxyExtension/TCPFlowRelay.swift
git commit -m "feat(proxy): use SNI as SSH direct-tcpip target so the server resolves DNS"
```

---

### Task 4: Force the peek path for all routed-app TCP in SSH remote-DNS mode, and don't LAN-bypass hijacked destinations

**Files:**
- Modify: `TransparentProxyExtension/TransparentProxyProvider.swift` (flow-handling entry: construct `TCPFlowRelay` with `routeDecider` + `remoteDNS: true` for routed apps when SSH remote-DNS is active; skip the `shouldBypassLocal` short-circuit for those flows).

**Interfaces:**
- Consumes: `remoteDNSResolution` (Task 1), `TCPFlowRelay(remoteDNS:routeDecider:)` (Tasks 2–3).
- Produces: routed-app TCP flows that always peek in SSH mode, so `sniName` is available at connect.

- [ ] **Step 1: Read the current flow-handling / bypass decision**

Run: `grep -n "shouldBypassLocal\|routeDecider\|TCPFlowRelay(\|handleNewFlow\|sniMode\|domainRuleNames" TransparentProxyExtension/TransparentProxyProvider.swift`
Identify (a) where `TCPFlowRelay` is constructed and whether `routeDecider` is passed, and (b) where a flow is decided to bypass via `shouldBypassLocal`.

- [ ] **Step 2: Always peek routed-app TCP under SSH remote-DNS**

Where the relay is built for a routed-app TCP flow, when `remoteDNSResolution == true`, pass a `routeDecider` (reuse the existing SNI-mode decider; if none applies, a decider that returns `true` so the flow tunnels) AND `remoteDNS: true`:

```swift
let relay = TCPFlowRelay(
    flow: tcpFlow,
    signingID: signingID,
    // Force peek so the ClientHello/SNI is captured even without domain rules.
    routeDecider: remoteDNSResolution ? (existingSNIDecider ?? { _ in true }) : existingSNIDecider,
    remoteDNS: remoteDNSResolution,
    // …existing args unchanged…
)
```

- [ ] **Step 3: Do not bypass a routed app's hijacked destination as "local"**

Where `shouldBypassLocal(...)` would send a **routed-app** TCP flow direct, add a guard so that under `remoteDNSResolution` the flow is peeked+tunneled instead of bypassed. A private-range destination IP for a routed app in SSH mode is most likely a DNS sinkhole, not real LAN:

```swift
// In SSH remote-DNS mode, a routed app hitting an RFC1918 IP is almost always a hijacked/
// sinkholed public host. Peek it and route by SNI; only bypass when there is genuinely no SNI.
if remoteDNSResolution, isRoutedApp {
    // fall through to peek path (do NOT early-return via shouldBypassLocal)
} else if IPCIDRMatcher.shouldBypassLocal(/* existing args */) {
    // existing bypass behavior
}
```

If `TCPFlowRelay` later finds no SNI on such a flow, `remoteDNSTarget` returns the IP and the existing tunnel connect to that private IP fails **closed** (no real-interface leak) — acceptable and preferable to leaking. Genuine LAN access from routed apps over SSH is a known limitation; note it in Task 5 docs.

- [ ] **Step 4: Read-verify WG and non-routed flows unchanged**

Confirm: when `remoteDNSResolution == false` (all WG connects, legacy configs) the construction and the `shouldBypassLocal` decision are byte-for-byte the prior behavior. Non-routed (bypassed-by-app) flows are untouched.

- [ ] **Step 5: Commit**

```bash
git add TransparentProxyExtension/TransparentProxyProvider.swift
git commit -m "feat(proxy): SSH mode peeks all routed-app TCP + routes hijacked dests by SNI"
```

---

### Task 5: Scenario verification + as-built docs

**Files:**
- Modify: `docs/superpowers/specs/2026-07-23-ssh-transport-design.md` (as-built note + limitations).

**Interfaces:** none.

- [ ] **Step 1: Prepare the scenario run (app-side toggles + start via URL scheme, then STOP)**

With profile `New SSH Profile` (SSH, App-Tunnel, apps include `com.apple.Terminal`), the operator runs:

```
open "tunnelbahn://test?connect=New%20SSH%20Profile&routingMode=app_tunnel"
```

Then STOP and hand the probe list to the user (do not build unless the user asks).

- [ ] **Step 2: Probe list (run inside a matched app — e.g. Terminal.app)**

- **S-RDNS-1 (hijacked TLS host now works):** `curl -sSI https://www.youtube.com | head -1` → `HTTP/2 200` (or a 3xx), NOT `Couldn't connect to 10.10.34.36`. Egress via SSH server.
- **S-RDNS-2 (SNI actually used):** extension log shows `SSH tunnel target … host=www.youtube.com … destIP=10.10.34.36`.
- **S-RDNS-3 (control, unhijacked host still fine):** `curl -s https://api.ipify.org` → `3.139.146.5`.
- **S-RDNS-4 (no-SNI fallback fails closed, no leak):** a plain-`http://` request to a sinkholed host does NOT egress on the real interface (packet check: no direct connection to the real resolver's answer). Documented limitation, not a leak.
- **S-SSH regression:** re-run the existing Task 6 S-SSH probes to confirm normal SSH tunneling is unchanged.
- **WG regression:** connect a WireGuard profile; confirm `remoteDNS=false` in `[FIRSTRUN-DIAG]` and that a normal site loads (no SNI target logging on the WG path).

- [ ] **Step 3: Document as-built + limitations**

In `docs/superpowers/specs/2026-07-23-ssh-transport-design.md`, add a section:

```markdown
## As-built: SSH server-side DNS (SNI-based)

SSH mode resolves destination hostnames on the SSH server by using the TLS SNI
recovered from each routed-app flow's ClientHello as the `direct-tcpip` target,
instead of the app's locally-resolved IP. This defeats local DNS hijacking/
sinkholing for TLS traffic and matches `ssh -D` SOCKS remote-DNS behavior.

Limitations (future work — DNS-over-SSH task):
- Non-TLS (plain HTTP), non-SNI TLS, and ECH have no recoverable name → they fall
  back to the app-resolved IP and therefore remain subject to local DNS. They fail
  closed (no real-interface leak), they do not bypass the tunnel.
- Genuine RFC1918 LAN access from a routed app is not distinguished from a private-
  range sinkhole while remote-DNS is active; such flows are peeked and, absent SNI,
  fail closed rather than reaching the LAN.
- Full parity (covering non-TLS + making local `getaddrinfo` return real answers)
  requires an in-extension DNS resolver that forwards queries over the SSH
  connection. Tracked as the DNS-over-SSH follow-on.
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-07-23-ssh-transport-design.md
git commit -m "docs(ssh): as-built server-side DNS via SNI + non-TLS limitations"
```

---

## Self-Review

**1. Spec coverage:**
- Carry SSH-only flag → Task 1. ✓
- Recover hostname from ClientHello → Task 2 (reuses `TLSClientHelloSNI.serverName`). ✓
- Use hostname as `direct-tcpip` target → Task 3. ✓
- Ensure the flow is peeked at all in SSH mode + don't bypass sinkholed private IPs → Task 4. ✓
- Verify + document + limitations → Task 5. ✓
- WG-unchanged constraint → gated in Tasks 1–4, regression-checked in Task 5. ✓

**2. Placeholder scan:** Task 1 and Task 4 include a `grep`-first locate step because the exact provider-configuration container and the precise `shouldBypassLocal` call site must be read in-repo before editing; the edits themselves are shown concretely. No "TBD"/"add error handling" placeholders.

**3. Type consistency:** `remoteDNSResolution: Bool` (config/provider) vs `remoteDNS: Bool` (per-relay) are deliberately distinct names for distinct scopes; `remoteDNSTarget(sni:endpointHostname:)` signature is identical in Task 2 (definition), Task 2 self-checks, and Task 3 (call). `sniName` field name consistent across Tasks 2–3. `TLSClientHelloSNI.serverName(from:)` used as it exists in the tree.

## Known follow-on (out of scope, separate plan)

**DNS-over-SSH resolver** for full `ssh -D` parity: run a minimal resolver inside the packet-tunnel extension, point the tunnel/proxy DNS settings at it, and forward queries over the SSH connection (e.g. a `direct-tcpip` channel to a resolver reachable from the server, or the server's own resolver). Covers plain HTTP, non-SNI, ECH, and makes local `getaddrinfo` return real answers so private-range LAN vs sinkhole ambiguity disappears. Note the existing `DestinationRouting.swift:309` comment already anticipates a tunnel resolver inside `10/8`.
