# WireGuard-over-TCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a wstunnel-v10-compatible WebSocket/TLS wrapper mode to WireGuard profiles so WG can connect on UDP-blocked networks, carrying WG's encapsulated UDP inside a persistent TLS WebSocket to a `wstunnel` server.

**Architecture:** An optional obfuscation sub-mode on `WireGuardProfile` (not a new transport). An in-process Swift relay (`URLSessionWebSocketTask` + a local UDP `NWListener`) reimplements the wstunnel v10 UDP-over-WebSocket client; BoringTun's effective endpoint is repointed at the relay's loopback UDP port, leaving the entire WG data plane untouched.

**Tech Stack:** Swift 5.10, Network.framework (`NWListener` UDP), Foundation `URLSessionWebSocketTask`, CryptoKit (HMAC-SHA256 for the JWT), XCTest. Zero new third-party dependencies. Build via `xcodegen generate` + `xcodebuild`.

## Global Constraints

- **Wire-compatible with `wstunnel` v10.** Upgrade path `/<pathPrefix>/events`; tunnel request carried as `Sec-WebSocket-Protocol: v1, authorization.bearer.<JWT>`; JWT HS256 with claims `{"id":"<uuid>","p":{"Udp":{"timeout":{"secs":30,"nanos":0}}},"r":"<forwardHost>","rp":<forwardPort>}`; each UDP datagram is one WebSocket **binary** frame (no length prefix). The server does **not** verify the JWT signature — sign with locally-generated random bytes.
- **Plain WireGuard and the SSH transport must be byte-for-byte unchanged.** All new behavior is gated on `profile.tcpWrapper != nil` (WG path) and never touches the `.ssh` path.
- **`tcpWrapper` MUST be added to `WireGuardProfile.CodingKeys`.** The struct uses a hand-written `init(from:)` + synthesized `encode`; a stored property missing from `CodingKeys` is silently dropped from persistence (see the file's own comment, WireGuardProfile.swift:72-79).
- **In-process only.** No spawning a CLI. The relay runs inside the packet-tunnel extension.
- **Deployment target macOS 14.0**, Swift version 5.10 (from `project.yml`).
- **Cert verification defaults OFF** (`verifyCert = false`), matching wstunnel's default; the reference server presents a Cloudflare-origin cert that will not validate against a bare IP.
- **Files under test stay pure** (no Keychain, AppKit, or NetworkExtension-only APIs) so the logic-test bundle compiles them directly.
- New Swift files that must be visible to the packet-tunnel extension go in `Shared/` or `TunnelBahn/Models/` (both are compiled into `PacketTunnelExtension` per `project.yml`). UI files go in `TunnelBahn/Views/` (app target only).

---

### Task 1: Model + test target + persistence round-trip

Introduces `WireGuardTCPWrapper`, wires it onto `WireGuardProfile` (including `CodingKeys`), and stands up the project's first unit-test bundle to prove the Codable round-trip.

**Files:**
- Create: `TunnelBahn/Models/WireGuardTCPWrapper.swift`
- Create: `Tests/Unit/WireGuardProfileTCPWrapperTests.swift`
- Modify: `TunnelBahn/Models/WireGuardProfile.swift` (add property, `CodingKeys` case, decode)
- Modify: `project.yml` (add `TunnelBahnUnitTests` target + add it to the TunnelBahn scheme's `test:` block)

**Interfaces:**
- Produces: `struct WireGuardTCPWrapper: Codable, Hashable { var serverHost: String; var serverPort: UInt16; var tls: Bool; var verifyCert: Bool; var pathPrefix: String; var forwardHost: String; var forwardPort: UInt16 }`
- Produces: `WireGuardProfile.tcpWrapper: WireGuardTCPWrapper?` (nil ⇒ plain WG)

- [ ] **Step 1: Write the model**

Create `TunnelBahn/Models/WireGuardTCPWrapper.swift`:

```swift
import Foundation

/// Optional obfuscation sub-mode on a WireGuard profile: carry the peer's encapsulated
/// UDP inside a wstunnel-v10 WebSocket/TLS connection so WG works on UDP-blocked networks.
/// nil on the profile means plain WireGuard (unchanged behavior). Carries no secrets, so it
/// travels to the extension inside the profile JSON with no Keychain round-trip.
struct WireGuardTCPWrapper: Codable, Hashable {
    /// TLS/WebSocket connect target — where the relay dials (e.g. 3.139.146.5).
    var serverHost: String
    /// TCP port for the connect target (typically 443).
    var serverPort: UInt16
    /// true ⇒ wss (TLS); false ⇒ ws (plaintext, for a standalone non-TLS wstunnel server).
    var tls: Bool
    /// false (default) skips TLS cert validation, matching wstunnel's default. Required for the
    /// reference bare-IP server whose cert will not validate against the IP.
    var verifyCert: Bool
    /// Secret WebSocket path prefix the server routes on (no leading/trailing slash), e.g.
    /// tun74fd08a683078a3e0439. The upgrade path is "/<pathPrefix>/events".
    var pathPrefix: String
    /// Server-side UDP forward target the unwrapper hands datagrams to (JWT "r"), e.g. 127.0.0.1.
    var forwardHost: String
    /// Server-side UDP forward port (JWT "rp"), e.g. 51840.
    var forwardPort: UInt16
}
```

- [ ] **Step 2: Wire onto `WireGuardProfile`**

In `TunnelBahn/Models/WireGuardProfile.swift`:

Add the stored property (after `ssh`):
```swift
    /// Present only when this WG profile uses the TCP (WebSocket/TLS) wrapper sub-mode.
    var tcpWrapper: WireGuardTCPWrapper?
```

Add the init parameter (after `ssh: SSHProfile? = nil`) and assignment:
```swift
        tcpWrapper: WireGuardTCPWrapper? = nil,
```
```swift
        self.tcpWrapper = tcpWrapper
```

Add the `CodingKeys` case:
```swift
        case id, name, interface, peers, createdAt, updatedAt, transport, ssh, tcpWrapper
```

Add to `init(from:)` (after the `ssh` decode):
```swift
        tcpWrapper = try container.decodeIfPresent(WireGuardTCPWrapper.self, forKey: .tcpWrapper)
```

- [ ] **Step 3: Write the failing test**

Create `Tests/Unit/WireGuardProfileTCPWrapperTests.swift`:

```swift
import XCTest

final class WireGuardProfileTCPWrapperTests: XCTestCase {
    private func sampleProfile(wrapper: WireGuardTCPWrapper?) -> WireGuardProfile {
        WireGuardProfile(
            name: "wg-tcp",
            interface: WireGuardInterface(privateKeyRef: "ref", addresses: ["10.9.0.2/32"], dnsServers: ["1.1.1.1"], mtu: nil),
            peers: [WireGuardPeer(publicKey: "cHVia2V5cHVia2V5cHVia2V5cHVia2V5cHVia2V5MDA=", endpoint: "127.0.0.1:51840", allowedIPs: ["0.0.0.0/0"])],
            tcpWrapper: wrapper
        )
    }

    func testCodableRoundTripPreservesWrapper() throws {
        let wrapper = WireGuardTCPWrapper(
            serverHost: "3.139.146.5", serverPort: 443, tls: true, verifyCert: false,
            pathPrefix: "tun74fd08a683078a3e0439", forwardHost: "127.0.0.1", forwardPort: 51840
        )
        let data = try JSONEncoder().encode(sampleProfile(wrapper: wrapper))
        let decoded = try JSONDecoder().decode(WireGuardProfile.self, from: data)
        XCTAssertEqual(decoded.tcpWrapper, wrapper)   // guards the CodingKeys hazard
    }

    func testLegacyProfileDecodesWrapperAsNil() throws {
        // A profile JSON produced before this field existed has no tcpWrapper key.
        let data = try JSONEncoder().encode(sampleProfile(wrapper: nil))
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "tcpWrapper")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(WireGuardProfile.self, from: stripped)
        XCTAssertNil(decoded.tcpWrapper)
    }
}
```

- [ ] **Step 4: Add the test target to `project.yml`**

Under `targets:` add:
```yaml
  TunnelBahnUnitTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests/Unit
      - path: TunnelBahn/Models/WireGuardProfile.swift
      - path: TunnelBahn/Models/SSHProfile.swift
      - path: TunnelBahn/Models/WireGuardTCPWrapper.swift
```

In the `schemes: TunnelBahn:` block, add a `test:` section:
```yaml
    test:
      targets:
        - TunnelBahnUnitTests
```

- [ ] **Step 5: Regenerate and run the test to verify it passes**

Run:
```bash
cd /Users/mahmoudparham/AppSplitWG
xcodegen generate
xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests 2>&1 | tail -30
```
Expected: `WireGuardProfileTCPWrapperTests` — 2 tests PASS. (If `tcpWrapper` had been left out of `CodingKeys`, `testCodableRoundTripPreservesWrapper` fails with `nil != wrapper` — that is the hazard the test exists to catch.)

- [ ] **Step 6: Commit**

```bash
git add TunnelBahn/Models/WireGuardTCPWrapper.swift TunnelBahn/Models/WireGuardProfile.swift Tests/Unit/WireGuardProfileTCPWrapperTests.swift project.yml TunnelBahn.xcodeproj
git commit -m "feat(wg-tcp): add WireGuardTCPWrapper model + unit-test target"
```

---

### Task 2: `[TCPWrapper]` config codec (pure parse/render)

A dependency-free helper that maps the `[TCPWrapper]` config section (a `[String: String]` map) to/from `WireGuardTCPWrapper`. Keeping this pure keeps the parser/renderer changes trivial and the tests Keychain-free.

**Files:**
- Create: `Shared/TCPWrapperConfigCodec.swift`
- Create: `Tests/Unit/TCPWrapperConfigCodecTests.swift`
- Modify: `project.yml` (add the codec file to `TunnelBahnUnitTests` sources)

**Interfaces:**
- Consumes: `WireGuardTCPWrapper` (Task 1)
- Produces: `enum TCPWrapperConfigCodec { static func decode(_ map: [String: String]) throws -> WireGuardTCPWrapper?; static func encodeLines(_ wrapper: WireGuardTCPWrapper) -> [String] }`
- Produces: `enum TCPWrapperConfigError: LocalizedError { case missingKey(String); case invalidPort(String) }`

- [ ] **Step 1: Write the failing test**

Create `Tests/Unit/TCPWrapperConfigCodecTests.swift`:

```swift
import XCTest

final class TCPWrapperConfigCodecTests: XCTestCase {
    private let reference = WireGuardTCPWrapper(
        serverHost: "3.139.146.5", serverPort: 443, tls: true, verifyCert: false,
        pathPrefix: "tun74fd08a683078a3e0439", forwardHost: "127.0.0.1", forwardPort: 51840
    )

    func testDecodeFromLowercasedMap() throws {
        // Parser lowercases keys and preserves values.
        let map = [
            "server": "3.139.146.5:443", "tls": "true", "verifycert": "false",
            "pathprefix": "tun74fd08a683078a3e0439", "forward": "127.0.0.1:51840",
        ]
        XCTAssertEqual(try TCPWrapperConfigCodec.decode(map), reference)
    }

    func testDecodeEmptyMapReturnsNil() throws {
        XCTAssertNil(try TCPWrapperConfigCodec.decode([:]))
    }

    func testMissingRequiredKeyThrows() {
        let map = ["tls": "true"]  // no server/pathprefix/forward
        XCTAssertThrowsError(try TCPWrapperConfigCodec.decode(map))
    }

    func testEncodeThenDecodeRoundTrips() throws {
        let lines = TCPWrapperConfigCodec.encodeLines(reference)
        // Re-parse the rendered lines into a lowercased map the way the parser would.
        var map: [String: String] = [:]
        for line in lines where line.contains("=") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            map[parts[0].lowercased()] = parts[1]
        }
        XCTAssertEqual(try TCPWrapperConfigCodec.decode(map), reference)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd /Users/mahmoudparham/AppSplitWG
xcodegen generate
xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/TCPWrapperConfigCodecTests 2>&1 | tail -20
```
Expected: FAIL — `TCPWrapperConfigCodec` is undefined (won't compile until Step 3 + the source is added to the target).

- [ ] **Step 3: Implement the codec**

Create `Shared/TCPWrapperConfigCodec.swift`:

```swift
import Foundation

enum TCPWrapperConfigError: LocalizedError {
    case missingKey(String)
    case invalidPort(String)

    var errorDescription: String? {
        switch self {
        case let .missingKey(k): return "[TCPWrapper] section is missing required key '\(k)'."
        case let .invalidPort(v): return "[TCPWrapper] has an invalid host:port value '\(v)'."
        }
    }
}

/// Maps the `[TCPWrapper]` config section (keys already lowercased by the WG parser) to and from
/// `WireGuardTCPWrapper`. Pure: no Keychain, no I/O. The section carries no secrets.
enum TCPWrapperConfigCodec {
    /// Returns nil when the map is empty (no `[TCPWrapper]` section present). Throws on a
    /// partially-specified section (missing/invalid required keys).
    static func decode(_ map: [String: String]) throws -> WireGuardTCPWrapper? {
        if map.isEmpty { return nil }
        let (serverHost, serverPort) = try splitHostPort(require(map, "server"))
        let (forwardHost, forwardPort) = try splitHostPort(require(map, "forward"))
        let pathPrefix = try require(map, "pathprefix")
        let tls = parseBool(map["tls"], default: true)
        let verifyCert = parseBool(map["verifycert"], default: false)
        return WireGuardTCPWrapper(
            serverHost: serverHost, serverPort: serverPort, tls: tls, verifyCert: verifyCert,
            pathPrefix: pathPrefix, forwardHost: forwardHost, forwardPort: forwardPort
        )
    }

    static func encodeLines(_ w: WireGuardTCPWrapper) -> [String] {
        [
            "[TCPWrapper]",
            "Server = \(w.serverHost):\(w.serverPort)",
            "TLS = \(w.tls)",
            "VerifyCert = \(w.verifyCert)",
            "PathPrefix = \(w.pathPrefix)",
            "Forward = \(w.forwardHost):\(w.forwardPort)",
        ]
    }

    private static func require(_ map: [String: String], _ key: String) throws -> String {
        guard let v = map[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else {
            throw TCPWrapperConfigError.missingKey(key)
        }
        return v
    }

    private static func parseBool(_ v: String?, default def: Bool) -> Bool {
        guard let v = v?.trimmingCharacters(in: .whitespaces).lowercased() else { return def }
        if ["true", "1", "yes", "on"].contains(v) { return true }
        if ["false", "0", "no", "off"].contains(v) { return false }
        return def
    }

    /// Splits "host:port" (IPv4 or hostname). IPv6 literals are out of scope for the wrapper target.
    private static func splitHostPort(_ value: String) throws -> (String, UInt16) {
        guard let idx = value.lastIndex(of: ":") else { throw TCPWrapperConfigError.invalidPort(value) }
        let host = String(value[..<idx])
        let portStr = String(value[value.index(after: idx)...])
        guard !host.isEmpty, let port = UInt16(portStr) else { throw TCPWrapperConfigError.invalidPort(value) }
        return (host, port)
    }
}
```

Add to `project.yml` `TunnelBahnUnitTests.sources`:
```yaml
      - path: Shared/TCPWrapperConfigCodec.swift
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd /Users/mahmoudparham/AppSplitWG
xcodegen generate
xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/TCPWrapperConfigCodecTests 2>&1 | tail -20
```
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/TCPWrapperConfigCodec.swift Tests/Unit/TCPWrapperConfigCodecTests.swift project.yml TunnelBahn.xcodeproj
git commit -m "feat(wg-tcp): pure [TCPWrapper] config codec + tests"
```

---

### Task 3: Parser + renderer integration

Wires the codec into the existing `.conf` parser and full-config renderer so a `[TCPWrapper]` section round-trips through import/export.

**Files:**
- Modify: `TunnelBahn/Services/WireGuardConfigParser.swift`
- Modify: `TunnelBahn/Services/WireGuardConfigRenderer.swift`
- Create: `Tests/Unit/WireGuardConfigTCPWrapperTests.swift`
- Modify: `project.yml` (add parser + renderer + their `Shared` deps to the test target — see Step 4)

**Interfaces:**
- Consumes: `TCPWrapperConfigCodec` (Task 2), `WireGuardTCPWrapper` (Task 1)
- Produces: `WireGuardConfigParser.parse(rawConfig:profileName:)` sets `profile.tcpWrapper` when a `[TCPWrapper]` section is present; `WireGuardConfigRenderer.renderFullConfigString(profile:)` emits it when non-nil.

- [ ] **Step 1: Parser — read the section**

In `TunnelBahn/Services/WireGuardConfigParser.swift`, `parse(rawConfig:profileName:)`, after the peers are built and before `return WireGuardProfile(...)`:

```swift
        let tcpWrapper = try TCPWrapperConfigCodec.decode(sections["tcpwrapper"]?.first ?? [:])
```

Change the final return to pass it:
```swift
        return WireGuardProfile(name: profileName, interface: interface, peers: peers, tcpWrapper: tcpWrapper)
```

(No other parser change: `parseSections` already lowercases section names and keys, so `[TCPWrapper]` arrives as `sections["tcpwrapper"]`.)

- [ ] **Step 2: Renderer — emit the section**

In `TunnelBahn/Services/WireGuardConfigRenderer.swift`, `renderFullConfigString(profile:)`, after the peer loop and before `return lines.joined(...)`:

```swift
        if let wrapper = profile.tcpWrapper {
            lines.append("")
            lines.append(contentsOf: TCPWrapperConfigCodec.encodeLines(wrapper))
        }
```

Leave the strict `render(profile:interfaceName:)` method (the `wg setconf` path) untouched — it must never emit `[TCPWrapper]`.

- [ ] **Step 3: Write the round-trip test**

Create `Tests/Unit/WireGuardConfigTCPWrapperTests.swift`:

```swift
import XCTest

final class WireGuardConfigTCPWrapperTests: XCTestCase {
    // A full wrapped config resembling ~/Downloads/AWS-over-tcp.conf plus the [TCPWrapper] section.
    private let rawConfig = """
    [Interface]
    PrivateKey = aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGwwMDA=
    Address = 10.9.0.2/32
    DNS = 1.1.1.1

    [Peer]
    PublicKey = LuOmbtLMMHwhIBUJaPebD42U0qVTvRR6Zmcs2NYXIy0=
    AllowedIPs = 0.0.0.0/0
    Endpoint = 127.0.0.1:51840
    PersistentKeepalive = 25

    [TCPWrapper]
    Server = 3.139.146.5:443
    TLS = true
    VerifyCert = false
    PathPrefix = tun74fd08a683078a3e0439
    Forward = 127.0.0.1:51840
    """

    func testParseReadsWrapperSection() throws {
        let profile = try WireGuardConfigParser().parse(rawConfig: rawConfig, profileName: "aws-tcp")
        let w = try XCTUnwrap(profile.tcpWrapper)
        XCTAssertEqual(w.serverHost, "3.139.146.5")
        XCTAssertEqual(w.serverPort, 443)
        XCTAssertFalse(w.verifyCert)
        XCTAssertEqual(w.pathPrefix, "tun74fd08a683078a3e0439")
        XCTAssertEqual(w.forwardHost, "127.0.0.1")
        XCTAssertEqual(w.forwardPort, 51840)
    }

    func testRenderThenParseRoundTrips() throws {
        let parsed = try WireGuardConfigParser().parse(rawConfig: rawConfig, profileName: "aws-tcp")
        let rendered = try WireGuardConfigRenderer().renderFullConfigString(profile: parsed)
        XCTAssertTrue(rendered.contains("[TCPWrapper]"))
        let reparsed = try WireGuardConfigParser().parse(rawConfig: rendered, profileName: "aws-tcp")
        XCTAssertEqual(reparsed.tcpWrapper, parsed.tcpWrapper)
    }

    func testPlainConfigHasNilWrapper() throws {
        let plain = rawConfig.components(separatedBy: "[TCPWrapper]").first!
        let profile = try WireGuardConfigParser().parse(rawConfig: plain, profileName: "plain")
        XCTAssertNil(profile.tcpWrapper)
    }
}
```

- [ ] **Step 4: Add parser/renderer + deps to the test target**

The parser calls `KeychainService.save` for the private key, and the renderer calls `KeychainService.read`. To keep these tests runnable on the local machine (machine-first workflow, real Keychain), add the parser, renderer, and their compile dependencies to `TunnelBahnUnitTests.sources` in `project.yml`:

```yaml
      - path: TunnelBahn/Services/WireGuardConfigParser.swift
      - path: TunnelBahn/Services/WireGuardConfigRenderer.swift
      - path: Shared/KeychainService.swift
      - path: Shared/AppLog.swift
```

> Note for the executor: if `KeychainService` pulls further compile dependencies, add those files too (compile errors will name them). Do not stub the Keychain — the round-trip assertions only touch `tcpWrapper`, and the private-key save/read exercises the real path exactly as import/export does.

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
cd /Users/mahmoudparham/AppSplitWG
xcodegen generate
xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/WireGuardConfigTCPWrapperTests 2>&1 | tail -25
```
Expected: 3 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add TunnelBahn/Services/WireGuardConfigParser.swift TunnelBahn/Services/WireGuardConfigRenderer.swift Tests/Unit/WireGuardConfigTCPWrapperTests.swift project.yml TunnelBahn.xcodeproj
git commit -m "feat(wg-tcp): parse/render [TCPWrapper] section round-trip"
```

---

### Task 4: wstunnel v10 JWT builder

Builds the exact JWT wstunnel v10 carries in the `authorization.bearer` subprotocol. Pure CryptoKit; the signature is not verified by the server, so any random signing key works.

**Files:**
- Create: `Shared/WGTunnelJWT.swift`
- Create: `Tests/Unit/WGTunnelJWTTests.swift`
- Modify: `project.yml` (add the file to the test target)

**Interfaces:**
- Produces: `enum WGTunnelJWT { static func makeUDP(forwardHost: String, forwardPort: UInt16, timeoutSecs: Int = 30, id: String = UUID().uuidString) -> String }` — returns the compact JWT string (`header.claims.signature`, all base64url unpadded).

- [ ] **Step 1: Write the failing test**

Create `Tests/Unit/WGTunnelJWTTests.swift`:

```swift
import XCTest

final class WGTunnelJWTTests: XCTestCase {
    private func b64urlDecode(_ s: Substring) -> Data {
        var str = String(s).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str)!
    }

    func testTokenShapeMatchesWstunnelReference() throws {
        let token = WGTunnelJWT.makeUDP(forwardHost: "127.0.0.1", forwardPort: 51840, id: "019fae0b-c9e2-7d22-9e50-6d71cc8482eb")
        let parts = token.split(separator: ".")
        XCTAssertEqual(parts.count, 3)

        let header = try JSONSerialization.jsonObject(with: b64urlDecode(parts[0])) as! [String: Any]
        XCTAssertEqual(header["alg"] as? String, "HS256")
        XCTAssertEqual(header["typ"] as? String, "JWT")

        let claims = try JSONSerialization.jsonObject(with: b64urlDecode(parts[1])) as! [String: Any]
        XCTAssertEqual(claims["id"] as? String, "019fae0b-c9e2-7d22-9e50-6d71cc8482eb")
        XCTAssertEqual(claims["r"] as? String, "127.0.0.1")
        XCTAssertEqual(claims["rp"] as? Int, 51840)
        let p = claims["p"] as! [String: Any]
        let udp = p["Udp"] as! [String: Any]
        let timeout = udp["timeout"] as! [String: Any]
        XCTAssertEqual(timeout["secs"] as? Int, 30)
        XCTAssertEqual(timeout["nanos"] as? Int, 0)
    }

    func testSignatureSegmentIsNonEmpty() {
        let token = WGTunnelJWT.makeUDP(forwardHost: "10.0.0.1", forwardPort: 51820)
        XCTAssertFalse(token.split(separator: ".")[2].isEmpty)  // server ignores it, but it must be present
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run:
```bash
cd /Users/mahmoudparham/AppSplitWG
xcodegen generate
xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/WGTunnelJWTTests 2>&1 | tail -20
```
Expected: FAIL — `WGTunnelJWT` undefined.

- [ ] **Step 3: Implement the builder**

Create `Shared/WGTunnelJWT.swift`:

```swift
import Foundation
import CryptoKit

/// Builds the JWT wstunnel v10 sends in the `authorization.bearer.<jwt>` WebSocket subprotocol.
/// The server decodes it with `dangerous::insecure_decode` (no signature verification) and the
/// real client signs with a random per-run secret, so we do the same: HS256 over a random key.
enum WGTunnelJWT {
    /// Claims match wstunnel's `JwtTunnelConfig` for a UDP forward:
    /// {"id":<uuid>,"p":{"Udp":{"timeout":{"secs":N,"nanos":0}}},"r":<host>,"rp":<port>}
    static func makeUDP(
        forwardHost: String,
        forwardPort: UInt16,
        timeoutSecs: Int = 30,
        id: String = UUID().uuidString
    ) -> String {
        let header = #"{"typ":"JWT","alg":"HS256"}"#
        // Hand-built to guarantee key order and integer literals (JSONEncoder is fine too, but the
        // server only reads fields by name — key order is irrelevant to it).
        let claims = "{\"id\":\"\(id)\",\"p\":{\"Udp\":{\"timeout\":{\"secs\":\(timeoutSecs),\"nanos\":0}}},\"r\":\"\(forwardHost)\",\"rp\":\(forwardPort)}"
        let signingInput = base64url(Data(header.utf8)) + "." + base64url(Data(claims.utf8))

        var keyBytes = Data(count: 32)
        keyBytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: SymmetricKey(data: keyBytes))
        return signingInput + "." + base64url(Data(mac))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

Add to `project.yml` `TunnelBahnUnitTests.sources`:
```yaml
      - path: Shared/WGTunnelJWT.swift
```

- [ ] **Step 4: Run to verify it passes**

Run:
```bash
cd /Users/mahmoudparham/AppSplitWG
xcodegen generate
xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/WGTunnelJWTTests 2>&1 | tail -20
```
Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/WGTunnelJWT.swift Tests/Unit/WGTunnelJWTTests.swift project.yml TunnelBahn.xcodeproj
git commit -m "feat(wg-tcp): wstunnel v10 UDP JWT builder + tests"
```

---

### Task 5: `WGTCPWrapperRelay` — the in-process UDP↔WebSocket relay

The heart of the feature: a local UDP listener whose datagrams are pumped over one `URLSessionWebSocketTask` to the wstunnel server, and back. Lives in `Shared/` so both the extension and the test bundle compile it.

**Files:**
- Create: `Shared/WGTCPWrapperRelay.swift`
- Create: `Tests/Unit/WGTCPWrapperRelayTests.swift`
- Modify: `project.yml` (add both to the test target)

**Interfaces:**
- Consumes: `WireGuardTCPWrapper` (Task 1), `WGTunnelJWT` (Task 4)
- Produces:
  ```swift
  final class WGTCPWrapperRelay {
      init(config: WireGuardTCPWrapper)
      func start() async throws          // binds UDP, dials WS(+TLS), throws on connect/upgrade failure
      var localUDPPort: UInt16 { get }   // valid after start() returns
      func stop()
  }
  ```

**VALIDATED against the live server (spike, 2026-07-29):** a `URLSessionWebSocketTask` opened
to `wss://3.139.146.5:443/tun74fd08a683078a3e0439/events` offering
`protocols: ["v1", "authorization.bearer.<jwt>"]` with the cert-skip delegate **completes the
handshake** — HTTP `101`, `Sec-WebSocket-Accept` returned, server selects subprotocol `"v1"`,
and `URLSessionWebSocketTask` accepts it (`didOpenWithProtocol` fires immediately). So
URLSession is wire-compatible with wstunnel v10. **Two design consequences baked into the code
below, learned from the spike:**
1. **Readiness is signaled by the `didOpenWithProtocol` delegate, NOT by `sendPing`.** In the
   spike, `sendPing` never received a pong (it timed out) even though the tunnel was up —
   wstunnel/nginx did not answer the control-frame ping. Gating `start()` on a ping would
   wrongly fail a working tunnel. Gate on `didOpen` with a timeout instead.
2. **The relay sends no client pings.** Keepalive is WireGuard's own `PersistentKeepalive`
   (the reference conf uses 25s), which keeps datagrams — and thus the WebSocket — alive.
   `URLSessionWebSocketTask` auto-answers inbound server pings with pongs, so no manual
   pong handling is needed either.

- [ ] **Step 1: Write the failing test**

Create `Tests/Unit/WGTCPWrapperRelayTests.swift`. This stands up a local plaintext WebSocket **echo** server with `NWListener` + `NWProtocolWebSocket`, points the relay at it (`tls: false`), sends a datagram into the relay's UDP port, and asserts it echoes back — exercising the full UDP→WS→UDP pump without needing the live server:

```swift
import XCTest
import Network

final class WGTCPWrapperRelayTests: XCTestCase {
    /// Minimal echo WS server: echoes every binary message back on the same connection.
    private func startEchoWSServer() throws -> (port: UInt16, listener: NWListener) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            func pump() {
                conn.receiveMessage { data, context, _, error in
                    if let data, let context {
                        conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
                    }
                    if error == nil { pump() }
                }
            }
            pump()
        }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        return (listener.port!.rawValue, listener)
    }

    func testDatagramRoundTripsThroughRelay() async throws {
        let server = try startEchoWSServer()
        defer { server.listener.cancel() }

        let config = WireGuardTCPWrapper(
            serverHost: "127.0.0.1", serverPort: server.port, tls: false, verifyCert: false,
            pathPrefix: "tuntest", forwardHost: "127.0.0.1", forwardPort: 51840
        )
        let relay = WGTCPWrapperRelay(config: config)
        try await relay.start()
        defer { relay.stop() }

        // Send a datagram into the relay's local UDP port and expect the echo back.
        let payload = Data("wg-handshake-probe".utf8)
        let udp = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: relay.localUDPPort)!, using: .udp)
        let gotEcho = expectation(description: "echo")
        udp.stateUpdateHandler = { state in
            if case .ready = state {
                udp.send(content: payload, completion: .contentProcessed { _ in })
                udp.receiveMessage { data, _, _, _ in
                    if data == payload { gotEcho.fulfill() }
                }
            }
        }
        udp.start(queue: .global())
        await fulfillment(of: [gotEcho], timeout: 8)
        udp.cancel()
    }

    func testStartThrowsWhenServerUnreachable() async {
        let config = WireGuardTCPWrapper(
            serverHost: "127.0.0.1", serverPort: 1,  // nothing listens on TCP/1
            tls: false, verifyCert: false, pathPrefix: "x", forwardHost: "127.0.0.1", forwardPort: 51840
        )
        let relay = WGTCPWrapperRelay(config: config)
        do { try await relay.start(); XCTFail("expected throw") } catch { /* expected */ }
        relay.stop()
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run:
```bash
cd /Users/mahmoudparham/AppSplitWG
xcodegen generate
xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/WGTCPWrapperRelayTests 2>&1 | tail -20
```
Expected: FAIL — `WGTCPWrapperRelay` undefined.

- [ ] **Step 3: Implement the relay**

Create `Shared/WGTCPWrapperRelay.swift`:

```swift
import Foundation
import Network

/// In-process wstunnel-v10 UDP-over-WebSocket client. Binds a loopback UDP socket (WireGuard's
/// effective endpoint) and relays each datagram to the server as one WebSocket binary frame over a
/// single TLS WebSocket connection, and back. Wire-compatible with `wstunnel` v10: path
/// `/<pathPrefix>/events`, subprotocol `v1, authorization.bearer.<jwt>`.
final class WGTCPWrapperRelay: NSObject {
    private let config: WireGuardTCPWrapper
    private let queue = DispatchQueue(label: "com.tunnelbahn.mac.wgtcp.relay")

    private var listener: NWListener?
    private var udpConnection: NWConnection?      // the single peer = BoringTun's NWUDPSession
    private var session: URLSession?
    private var wsTask: URLSessionWebSocketTask?
    private(set) var localUDPPort: UInt16 = 0

    /// Resumed exactly once by the WebSocket delegate — success on `didOpenWithProtocol`,
    /// failure on `didCompleteWithError` before open. `start()` awaits it (with a timeout).
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openResolved = false

    init(config: WireGuardTCPWrapper) {
        self.config = config
        super.init()
    }

    func start() async throws {
        try startUDPListener()
        try await startWebSocket()      // returns once the WS handshake has completed (or throws)
        receiveFromWebSocket()
    }

    func stop() {
        // Fail a still-pending start() so its continuation can't leak.
        resolveOpen(.failure(NSError(domain: "WGTCPWrapperRelay", code: 5,
                                     userInfo: [NSLocalizedDescriptionKey: "relay stopped before open"])))
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        session?.invalidateAndCancel()
        session = nil
        udpConnection?.cancel(); udpConnection = nil
        listener?.cancel(); listener = nil
    }

    // MARK: UDP side

    private func startUDPListener() throws {
        // Loopback-only: BoringTun only ever dials 127.0.0.1:<port>, and binding all interfaces
        // would let anything on the LAN inject datagrams the server would wrap toward WG. Restrict
        // ingress to loopback with an ephemeral (.any) port.
        let params = NWParameters.udp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            // BoringTun uses one source port; keep the most recent as the reply target.
            self.udpConnection = conn
            conn.start(queue: self.queue)
            self.receiveFromUDP(conn)
        }
        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case let .failed(err): startError = err; ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        ready.wait()
        if let startError { throw startError }
        guard let port = listener.port?.rawValue else {
            throw NSError(domain: "WGTCPWrapperRelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "UDP listener has no port"])
        }
        self.listener = listener
        self.localUDPPort = port
    }

    private func receiveFromUDP(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.wsTask?.send(.data(data)) { _ in }   // one datagram → one binary frame
            }
            if error == nil { self.receiveFromUDP(conn) }
        }
    }

    // MARK: WebSocket side

    private func startWebSocket() async throws {
        let scheme = config.tls ? "wss" : "ws"
        guard let url = URL(string: "\(scheme)://\(config.serverHost):\(config.serverPort)/\(config.pathPrefix)/events") else {
            throw NSError(domain: "WGTCPWrapperRelay", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad server URL"])
        }
        let jwt = WGTunnelJWT.makeUDP(forwardHost: config.forwardHost, forwardPort: config.forwardPort)
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        // URLSession sends these as `Sec-WebSocket-Protocol: v1, authorization.bearer.<jwt>` — the
        // exact header wstunnel v10 uses to carry the tunnel request. The server selects "v1",
        // which URLSession accepts (validated against the live server).
        let task = session.webSocketTask(with: url, protocols: ["v1", "authorization.bearer.\(jwt)"])
        self.session = session
        self.wsTask = task

        // Await the HTTP upgrade completing. Readiness = the `didOpenWithProtocol` delegate (NOT a
        // ping — wstunnel does not reliably pong). A single stored continuation is resolved by
        // whichever fires first: didOpen (success), didCompleteWithError (failure), the timeout, or
        // stop(). `resolveOpen` guarantees exactly-once resume, so the continuation can never leak.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.openContinuation = cont
                self.queue.asyncAfter(deadline: .now() + 10) {   // 10s upgrade timeout
                    self.resolveOpen(.failure(NSError(
                        domain: "WGTCPWrapperRelay", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "WebSocket upgrade timed out after 10s"])))
                }
                task.resume()
            }
        }
    }

    /// Resume the open continuation at most once — delegate callbacks, the timeout, and stop() can
    /// all race. First caller wins; the rest are no-ops. Must run (and only run) on `queue`.
    private func resolveOpen(_ result: Result<Void, Error>) {
        queue.async {
            guard !self.openResolved else { return }
            self.openResolved = true
            let cont = self.openContinuation
            self.openContinuation = nil
            switch result {
            case .success: cont?.resume()
            case let .failure(err): cont?.resume(throwing: err)
            }
        }
    }

    private func receiveFromWebSocket() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                switch message {
                case let .data(data):
                    self.udpConnection?.send(content: data, completion: .contentProcessed { _ in })
                case let .string(text):
                    self.udpConnection?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
                @unknown default: break
                }
                self.receiveFromWebSocket()   // keep receiving
            case .failure:
                // WS closed/errored; stop pumping. Provider observes tunnel loss. (No auto-reconnect in v1.)
                break
            }
        }
    }
}

extension WGTCPWrapperRelay: URLSessionWebSocketDelegate {
    // Readiness signal: the upgrade completed and a subprotocol was selected.
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        resolveOpen(.success(()))
    }

    // Fired on connect/TLS/upgrade failure (and on later transport errors). If it beats
    // `didOpen`, it fails `start()`; if it arrives after open, `resolveOpen` is a no-op.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let err = error ?? NSError(domain: "WGTCPWrapperRelay", code: 4,
                                   userInfo: [NSLocalizedDescriptionKey: "WebSocket closed before opening"])
        resolveOpen(.failure(err))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Skip TLS validation when verifyCert is off (wstunnel default; the reference server's
        // cert will not validate against a bare IP). When on, defer to the system default.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        if config.verifyCert {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}
```

> Note for the executor: the listener binds loopback-only via `requiredLocalEndpoint`
> (`.ipv4(.loopback)`, `.any` port). Confirm `listener.port?.rawValue` returns the assigned
> ephemeral port after `.ready`. If a given OS build won't surface the port with
> `requiredLocalEndpoint` set, fall back to `NWListener(using: .udp, on: .any)` — BoringTun only
> ever dials `127.0.0.1`, so functionality is identical; loopback binding is the security-hardening
> preference, so try it first.

Add to `project.yml` `TunnelBahnUnitTests.sources`:
```yaml
      - path: Shared/WGTCPWrapperRelay.swift
```

- [ ] **Step 4: Run to verify it passes**

Run:
```bash
cd /Users/mahmoudparham/AppSplitWG
xcodegen generate
xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests/WGTCPWrapperRelayTests 2>&1 | tail -30
```
Expected: 2 tests PASS (datagram round-trip + unreachable-server throw).

- [ ] **Step 5: Commit**

```bash
git add Shared/WGTCPWrapperRelay.swift Tests/Unit/WGTCPWrapperRelayTests.swift project.yml TunnelBahn.xcodeproj
git commit -m "feat(wg-tcp): in-process UDP<->WebSocket relay + round-trip test"
```

---

### Task 6: BoringTun endpoint override

Adds an optional effective-endpoint override to `BoringTunAdapter.start(...)` so the provider can repoint WG at the relay's loopback port without mutating the profile.

**Files:**
- Modify: `NetworkExtension/BoringTunAdapter.swift` (start signature + endpoint derivation ~line 227)

**Interfaces:**
- Produces: `BoringTunAdapter.start(with:secrets:appTunnelIncludedRoutes:effectiveEndpointOverride:)` — new trailing optional `effectiveEndpointOverride: String? = nil`. When non-nil, it replaces `peer.endpoint` for the `NWHostEndpoint` only; everything else (keys, handshake, routing) is unchanged.

- [ ] **Step 1: Add the parameter**

In `NetworkExtension/BoringTunAdapter.swift`, extend the `start` signature:
```swift
    func start(
        with profile: WireGuardProfile,
        secrets: TunnelSecrets? = nil,
        appTunnelIncludedRoutes: [String]? = nil,
        effectiveEndpointOverride: String? = nil
    ) async throws {
```

- [ ] **Step 2: Use it at endpoint derivation**

At the endpoint token line (currently `BoringTunAdapter.swift:227`):
```swift
        let endpointString = Self.endpointToken(from: effectiveEndpointOverride ?? peer.endpoint)
```

Add a log line just above it so the override is visible in extension logs:
```swift
        if let effectiveEndpointOverride {
            Self.log.notice("[APPSPLIT_WGTCP] endpoint override active local-relay=\(effectiveEndpointOverride) (peer.endpoint=\(peer.endpoint) is carried by the wrapper)")
        }
```

- [ ] **Step 3: Build the extension to verify it compiles**

Run:
```bash
cd /Users/mahmoudparham/AppSplitWG
xcodegen generate
xcodebuild build -scheme TunnelBahn -destination 'platform=macOS' -target PacketTunnelExtension 2>&1 | tail -15
```
Expected: BUILD SUCCEEDED. (Existing callers pass no override → `nil` → identical behavior.)

- [ ] **Step 4: Commit**

```bash
git add NetworkExtension/BoringTunAdapter.swift
git commit -m "feat(wg-tcp): optional effective-endpoint override in BoringTunAdapter"
```

---

### Task 7: Provider wiring + loop-guard invariant

Starts the relay before BoringTun when `tcpWrapper` is set, repoints the adapter at the relay port, and tears the relay down symmetrically. Documents the routing-loop invariant.

**Files:**
- Modify: `NetworkExtension/PacketTunnelProvider.swift` (`startWireGuard`, `stopTunnel`, add a `wgTcpRelay` property + teardown)

**Interfaces:**
- Consumes: `WGTCPWrapperRelay` (Task 5), `BoringTunAdapter.start(...effectiveEndpointOverride:)` (Task 6)

- [ ] **Step 1: Add the stored property**

Near the top of `PacketTunnelProvider` (with the other transport state, by `sshTransport`):
```swift
    /// Live WebSocket/TLS UDP relay (only when the active WG profile has `tcpWrapper` set).
    private var wgTcpRelay: WGTCPWrapperRelay?
```

- [ ] **Step 2: Start the relay in `startWireGuard`**

In `startWireGuard(_:)`, immediately after `adapter = BoringTunAdapter(provider: self)` and before the `try await adapter?.start(...)` call, insert:

```swift
        var effectiveEndpointOverride: String? = nil
        if let wrapper = runtime.profile.tcpWrapper {
            // Routing-loop invariant (verify + assert): the relay's own outbound TCP to
            // \(wrapper.serverHost) originates from THIS packet-tunnel extension process, which is
            // NOT one of the per-app-routed matched apps (per-app routing uses `sourceApplication`,
            // so the extension's own sockets are never captured). It therefore exits over the
            // physical interface and cannot recurse into its own tunnel — this is the in-app
            // equivalent of the reference .conf's `route add -host <server> <gw>` pin, which is only
            // needed because wg-quick installs a system-wide default route. If the relay ever fails
            // to connect under full-tunnel, this assumption is the first suspect.
            logger.notice("[APPSPLIT_WGTCP] starting relay server=\(wrapper.serverHost):\(wrapper.serverPort) tls=\(wrapper.tls) verifyCert=\(wrapper.verifyCert) forward=\(wrapper.forwardHost):\(wrapper.forwardPort)")
            let relay = WGTCPWrapperRelay(config: wrapper)
            do {
                try await relay.start()
            } catch {
                logger.error("[APPSPLIT_WGTCP] relay start failed: \(error.localizedDescription)")
                throw error
            }
            wgTcpRelay = relay
            effectiveEndpointOverride = "127.0.0.1:\(relay.localUDPPort)"
            logger.notice("[APPSPLIT_WGTCP] relay up; WG effective endpoint = \(effectiveEndpointOverride!)")
        }
```

Change the adapter start call to pass the override:
```swift
            try await adapter?.start(
                with: runtime.profile,
                secrets: runtime.secrets,
                appTunnelIncludedRoutes: runtime.appTunnelIncludedRoutes,
                effectiveEndpointOverride: effectiveEndpointOverride
            )
```

- [ ] **Step 3: Tear down the relay**

In `stopTunnel(with:)`, after `await adapter?.stop(); adapter = nil`, add:
```swift
        wgTcpRelay?.stop()
        wgTcpRelay = nil
```

Also add it to the error path: if `adapter?.start(...)` throws inside `startWireGuard`, the relay must not leak. In the existing `catch` block around `adapter?.start`, before `throw error`, add:
```swift
            wgTcpRelay?.stop()
            wgTcpRelay = nil
```

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
cd /Users/mahmoudparham/AppSplitWG
xcodegen generate
xcodebuild build -scheme TunnelBahn -destination 'platform=macOS' -target PacketTunnelExtension 2>&1 | tail -15
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add NetworkExtension/PacketTunnelProvider.swift
git commit -m "feat(wg-tcp): start/stop WebSocket relay + repoint WG endpoint + loop-guard invariant"
```

---

### Task 8: Profile editor UI

Adds the "TCP wrapper (WebSocket/TLS)" fields to the WireGuard profile editor and wires them into profile save/load.

**Files:**
- Create: `TunnelBahn/Views/WireGuardTCPWrapperEditorFields.swift`
- Modify: `TunnelBahn/Views/ProfileEditorSheet.swift` (state, body, `buildProfile()`)

**Interfaces:**
- Consumes: `WireGuardTCPWrapper` (Task 1)
- Produces: a `WireGuardTCPWrapperEditorFields` SwiftUI view + `ProfileEditorSheet` emitting `tcpWrapper` on saved WG profiles.

- [ ] **Step 1: Create the fields view**

Create `TunnelBahn/Views/WireGuardTCPWrapperEditorFields.swift` (mirrors `SSHProfileEditorFields` conventions — GroupBox, caption labels, `.roundedBorder`, `.instantTooltip`):

```swift
import SwiftUI

/// Editor fields for the WireGuard TCP (WebSocket/TLS) wrapper sub-mode. Shown under the WG
/// Peer section when the wrapper toggle is on. Carries no secrets, so nothing is written to the
/// Keychain — the values persist in the profile JSON.
struct WireGuardTCPWrapperEditorFields: View {
    @Binding var enabled: Bool
    @Binding var serverHost: String
    @Binding var serverPort: String
    @Binding var tls: Bool
    @Binding var verifyCert: Bool
    @Binding var pathPrefix: String
    @Binding var forwardHost: String
    @Binding var forwardPort: String

    var body: some View {
        GroupBox("TCP Wrapper (WebSocket/TLS)") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Carry WireGuard over a TCP WebSocket (for UDP-blocked networks)", isOn: $enabled)
                    .instantTooltip("Wraps WireGuard's UDP in a TLS WebSocket to a wstunnel server so it works where UDP is blocked.")

                if enabled {
                    Text("Server (host:port)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("3.139.146.5", text: $serverHost)
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        Text(":").foregroundStyle(.secondary)
                        TextField("443", text: $serverPort)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 80)
                    }
                    .instantTooltip("Where the wrapper connects (the wstunnel server). Usually port 443.")

                    Toggle("Use TLS (wss)", isOn: $tls)
                        .instantTooltip("On = wss (TLS). Off = plaintext ws for a non-TLS server.")
                    Toggle("Verify server certificate", isOn: $verifyCert)
                        .instantTooltip("Off (default) matches wstunnel and is required for the bare-IP reference server whose cert won't validate against an IP.")

                    Text("Secret path prefix").font(.caption).foregroundStyle(.secondary)
                    TextField("tun74fd08a683078a3e0439", text: $pathPrefix)
                        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        .instantTooltip("The secret WebSocket path prefix the server routes on. Upgrade path is /<prefix>/events.")

                    Text("Server-side forward target (host:port)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("127.0.0.1", text: $forwardHost)
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        Text(":").foregroundStyle(.secondary)
                        TextField("51840", text: $forwardPort)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 80)
                    }
                    .instantTooltip("Where the server unwraps UDP to — the WireGuard listener behind the wstunnel server (usually 127.0.0.1:51840).")
                }
            }
            .padding(.top, 4)
        }
    }
}
```

- [ ] **Step 2: Add editor state to `ProfileEditorSheet`**

In `ProfileEditorSheet` (after the SSH `@State` block, ~line 24):
```swift
    // TCP wrapper (WebSocket/TLS) editor state.
    @State private var wrapEnabled: Bool
    @State private var wrapServerHost: String
    @State private var wrapServerPort: String
    @State private var wrapTLS: Bool
    @State private var wrapVerifyCert: Bool
    @State private var wrapPathPrefix: String
    @State private var wrapForwardHost: String
    @State private var wrapForwardPort: String
```

In `init(original:onSave:onCancel:)`, initialize from `original.tcpWrapper`:
```swift
        let w = original.tcpWrapper
        _wrapEnabled = State(initialValue: w != nil)
        _wrapServerHost = State(initialValue: w?.serverHost ?? "")
        _wrapServerPort = State(initialValue: w.map { String($0.serverPort) } ?? "443")
        _wrapTLS = State(initialValue: w?.tls ?? true)
        _wrapVerifyCert = State(initialValue: w?.verifyCert ?? false)
        _wrapPathPrefix = State(initialValue: w?.pathPrefix ?? "")
        _wrapForwardHost = State(initialValue: w?.forwardHost ?? "127.0.0.1")
        _wrapForwardPort = State(initialValue: w.map { String($0.forwardPort) } ?? "51840")
```

- [ ] **Step 3: Show the fields in `body`**

Inside the `if transport == .wireguard` region of `body` (after the Peer GroupBox, before the WG save/QR area at ~line 161), insert:
```swift
                if transport == .wireguard {
                    WireGuardTCPWrapperEditorFields(
                        enabled: $wrapEnabled,
                        serverHost: $wrapServerHost, serverPort: $wrapServerPort,
                        tls: $wrapTLS, verifyCert: $wrapVerifyCert,
                        pathPrefix: $wrapPathPrefix,
                        forwardHost: $wrapForwardHost, forwardPort: $wrapForwardPort
                    )
                }
```

- [ ] **Step 4: Emit `tcpWrapper` in `buildProfile()`**

In `buildProfile()` (the WG branch that constructs the returned `WireGuardProfile` at ~line 284), build the wrapper and pass it. Just before the `return WireGuardProfile(...)`:
```swift
        var builtWrapper: WireGuardTCPWrapper? = nil
        if wrapEnabled {
            let host = wrapServerHost.trimmingCharacters(in: .whitespaces)
            let prefix = wrapPathPrefix.trimmingCharacters(in: .whitespaces)
            let fwdHost = wrapForwardHost.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, let sPort = UInt16(wrapServerPort.trimmingCharacters(in: .whitespaces)),
                  !prefix.isEmpty, !fwdHost.isEmpty, let fPort = UInt16(wrapForwardPort.trimmingCharacters(in: .whitespaces))
            else {
                validationMessage = "TCP wrapper needs a server host:port, a path prefix, and a forward host:port."
                return nil
            }
            builtWrapper = WireGuardTCPWrapper(
                serverHost: host, serverPort: sPort, tls: wrapTLS, verifyCert: wrapVerifyCert,
                pathPrefix: prefix, forwardHost: fwdHost, forwardPort: fPort
            )
        }
```

Add `tcpWrapper: builtWrapper` to the `return WireGuardProfile(...)` argument list.

- [ ] **Step 5: Build the app to verify it compiles**

Run:
```bash
cd /Users/mahmoudparham/AppSplitWG
xcodegen generate
xcodebuild build -scheme TunnelBahn -destination 'platform=macOS' -target TunnelBahn 2>&1 | tail -15
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add TunnelBahn/Views/WireGuardTCPWrapperEditorFields.swift TunnelBahn/Views/ProfileEditorSheet.swift
git commit -m "feat(wg-tcp): profile editor fields for the TCP wrapper mode"
```

---

### Task 9: Documentation (README + CHANGELOG)

**Files:**
- Modify: `README.md` (new subsection under the WG/SSH transport docs)
- Modify: `CHANGELOG.md` (new entry)

- [ ] **Step 1: README subsection**

Add after the "SSH transport" section in `README.md`:

```markdown
## WireGuard-over-TCP (WebSocket/TLS wrapper)

WireGuard is UDP-only, so networks that block UDP (captive portals, some censored ISPs)
stop the handshake from ever landing. A WireGuard profile can optionally carry its traffic
over a **TCP WebSocket/TLS wrapper** to a [`wstunnel`](https://github.com/erebe/wstunnel)
v10 server, which unwraps it back to UDP and forwards it to a normal WireGuard listener.

Enable it in the profile editor: **TCP Wrapper (WebSocket/TLS)** → set the server
`host:port` (usually `:443`), TLS on, the secret path prefix, and the server-side forward
target (usually `127.0.0.1:51840`). Or import a `.conf` with a `[TCPWrapper]` section:

    [TCPWrapper]
    Server = 3.139.146.5:443
    TLS = true
    VerifyCert = false
    PathPrefix = tun74fd08a683078a3e0439
    Forward = 127.0.0.1:51840

The whole WireGuard data plane is unchanged — only the encapsulated UDP's carrier changes.
The wrapper runs entirely in-process in the network extension.

As-built behavior and limitations:

- **Wire-compatible with `wstunnel` v10** (WebSocket transport). Deployed wstunnel servers
  keep working; the upgrade path is `/<prefix>/events` and each UDP datagram is one
  WebSocket binary frame.
- **Certificate verification is off by default**, matching wstunnel. The reference server
  presents a cert that will not validate against a bare IP; turning verification on
  requires connecting by a hostname with a matching certificate.
- **Single WebSocket connection** carries all of the profile's WG traffic — under heavy
  load, WebSocket/TCP head-of-line blocking can add latency versus native UDP.
- **No WebSocket auto-reconnect in this version.** If the WebSocket drops, reconnect the
  tunnel. (BoringTun's keepalive/handshake retries drive traffic while the socket is up.)
- **WebSocket transport only** — wstunnel's HTTP/2 transport is not implemented.
- **Routing-loop safe by construction:** per-app routing never captures the extension's own
  sockets, so the wrapper's TCP connection to the server does not recurse into the tunnel —
  no manual route pin is needed (unlike the `wg-quick` reference setup).
```

- [ ] **Step 2: CHANGELOG entry**

Add under the top/unreleased section of `CHANGELOG.md`:
```markdown
### Added
- **WireGuard-over-TCP (WebSocket/TLS wrapper).** WireGuard profiles can now carry traffic
  over a `wstunnel` v10-compatible TLS WebSocket for networks that block UDP. Configured in
  the profile editor or via a `[TCPWrapper]` section in imported `.conf` files. The wrapper
  runs in-process in the network extension; the WireGuard data plane is unchanged. Cert
  verification defaults off (matching wstunnel); single-connection, WebSocket-transport
  only, no auto-reconnect in this release.
```

- [ ] **Step 3: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs(wg-tcp): document WireGuard-over-TCP wrapper mode and limitations"
```

---

### Task 10: End-to-end acceptance (manual, against the live server)

Proves the acceptance criterion: a wrapped profile completes a real WG handshake through
`wss://3.139.146.5:443` and exits via the server IP.

**Files:** none (verification only).

- [ ] **Step 1: Full test-suite green**

Run:
```bash
cd /Users/mahmoudparham/AppSplitWG
xcodegen generate
xcodebuild test -scheme TunnelBahn -destination 'platform=macOS' -only-testing:TunnelBahnUnitTests 2>&1 | tail -20
```
Expected: all `TunnelBahnUnitTests` PASS.

- [ ] **Step 2: Build, install, and run the app**

Run the app (`xcodebuild build -scheme TunnelBahn ...` then launch, or via Xcode) and let the
system extension load. Import a wrapped profile — either import `~/Downloads/AWS-over-tcp.conf`
and add the wrapper fields in the editor, or paste a `.conf` that already includes the
`[TCPWrapper]` section from Task 9 (Server `3.139.146.5:443`, PathPrefix
`tun74fd08a683078a3e0439`, Forward `127.0.0.1:51840`, keep the working `[Peer]` keys from the
reference conf).

- [ ] **Step 3: Connect a routed app and verify the exit IP**

Select a routed app (e.g. Terminal), connect the profile, then from that app run:
```bash
curl https://1.1.1.1/cdn-cgi/trace
```
Expected: the `ip=` line equals `3.139.146.5`. This confirms the WG handshake completed
through the WebSocket wrapper and traffic exits via the server. Cross-check with extension
logs (`log stream --predicate 'eventMessage CONTAINS "APPSPLIT_WGTCP"'`): relay up, endpoint
override active.

- [ ] **Step 4: Confirm plain WG + SSH are unaffected**

Connect a plain WireGuard profile (no `[TCPWrapper]`) and confirm normal operation, then an
SSH-transport profile. Both must behave exactly as before (no relay started; logs show no
`APPSPLIT_WGTCP` lines for these).

- [ ] **Step 5: Rotate the reference key (operator note)**

The `~/Downloads/AWS-over-tcp.conf` private key is live and was handled during testing —
rotate the WireGuard client key on the server and in the profile, per the appendix teardown
notes. (Out of scope for the code; flagged so it is not forgotten.)

---

## Self-Review

**Spec coverage:**
- Model as WG sub-mode (not new transport) → Task 1. ✓
- Swift/Network.framework relay, wstunnel-v10 wire format → Tasks 4 (JWT), 5 (relay). ✓
- Loopback UDP socket feeding BoringTun → Tasks 6 (override), 7 (wiring). ✓
- Loop-guard invariant → Task 7 Step 2 comment. ✓
- Config surface (`[TCPWrapper]` parse/render) → Tasks 2, 3. ✓
- UI editor fields → Task 8. ✓
- CodingKeys persistence hazard → Task 1 (property + test that catches omission). ✓
- Parser/renderer round-trip + unit tests → Tasks 2, 3; JWT test Task 4; relay test Task 5. ✓
- README/CHANGELOG → Task 9. ✓
- Exit-IP acceptance → Task 10. ✓
- "Plain WG + SSH unchanged" → gated on `tcpWrapper != nil`; verified Task 10 Step 4. ✓

**Placeholder scan:** No TBD/TODO; every code and test step has concrete content.

**Type consistency:** `WireGuardTCPWrapper` fields identical across Tasks 1/2/4/5/8. Relay API
(`init(config:)`, `start() async throws`, `localUDPPort`, `stop()`) consistent across Tasks 5/7.
`makeUDP(forwardHost:forwardPort:timeoutSecs:id:)` consistent across Tasks 4/5.
`effectiveEndpointOverride` consistent across Tasks 6/7.

**Known executor caveats (called out inline, not placeholders):**
- Test target may need additional `Shared/*` files added to `sources` if `KeychainService`
  pulls more compile deps (Task 3 Step 4). Compile errors name them precisely.
- `xcodebuild -target` filtering syntax may need to be `-only-testing`/scheme-based on some
  setups; the scheme builds all three app/extension targets regardless.
