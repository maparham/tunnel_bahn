# Tunnel Sharing (Phone Relay) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Mac's TunnelBahn egress its flows through the Android phone's live tunnel session over the hotspot/tether link, with QR pairing and mutual authentication.

**Architecture:** The Mac gains a fourth `RelayFlowTransport` (`PhoneRelayFlowTransport`) that speaks the existing `RelayWireFrame` protocol over TCP+TLS to a new `share.Server` inside the phone's Go core; the phone serves each flow by dialing through its already-connected `transport.Transport`. Flows are terminated and re-dialed at each hop — no nested tunneling. Pairing = Mac-rendered QR (peerID + 32-byte secret) scanned by the phone; the handshake binds HMAC proofs to the observed TLS certificate.

**Tech Stack:** Go (android/core, gomobile), Kotlin/Compose (android/app), Swift (SwiftUI app + NetworkExtension/TransparentProxy system extensions), CryptoKit, Network.framework, x/net/dns/dnsmessage.

**Spec:** `docs/superpowers/specs/2026-08-30-tunnel-share-design.md`

## Global Constraints

- Wire protocol must match `Shared/RelayWireFrame.swift` byte-for-byte: `[uint32 length][uint8 type][body]`, big-endian, body cap `1 << 20`, payload chunk cap `(1 << 20) - 9`, types `0x01/0x02/0x03/0x81/0x82/0x83`. Malformed frame = tear down the link.
- Handshake labels are exactly `"tbshare-server"` and `"tbshare-client"`; magic `"TBSH"`; version `0x01`; default port `47600`.
- QR payload `kind` is exactly `"tunnelbahn.pair"`, `v` = 1, `id` = 16-byte hex, `secret` = 32-byte hex.
- Go: any new exported API must be re-declared in `android/core/mobile/mobile.go` (gomobile only emits proxies for the bound package). After Go changes run `cd android && ./build-core.sh` (regenerates the checked-in `android/app/libs/libtunnelbahn.aar`; no Gradle task does this).
- Swift: every new file must be added to `project.yml` (app/extension target sources AND, for anything unit-tested, the file-by-file `TunnelBahnUnitTests` sources list), then `xcodegen generate`.
- The phone's netstack engine is a process-global singleton — the share server must never create an engine; it reuses the live `transport.Transport` only (precedent: `RunTunnelSpeedTest`, `runExitProbe`).
- Secrets: Mac side in Keychain via `KeychainService` (never in profile JSON); Android side in EncryptedSharedPreferences (model: `ProfileStore.kt`).
- Test commands: Go `cd android/core && go test ./...` · Kotlin `cd android && ./gradlew :app:testDebugUnitTest` · Swift `xcodegen generate && xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' test`.

---

### Task 1: Go `relaywire` codec (port of RelayWireFrame)

**Files:**
- Create: `android/core/relaywire/relaywire.go`
- Test: `android/core/relaywire/relaywire_test.go`

**Interfaces:**
- Consumes: nothing (leaf package).
- Produces (used by Tasks 5–6):
  - `const TypeOpenFlow byte = 0x01`, `TypeSendPayload = 0x02`, `TypeCloseFlow = 0x03`, `TypeOpenReply = 0x81`, `TypeDeliver = 0x82`, `TypeFlowClosed = 0x83`
  - `const MaxFrameBody = 1 << 20`
  - `var ErrMalformed = errors.New("relaywire: malformed frame")`
  - `type Frame struct { Type byte; ReqID uint32; FlowID uint64; Host string; Port uint16; IsTCP bool; OK bool; Err string; Payload []byte }`
  - `func EncodeOpenFlow(reqID uint32, flowID uint64, host string, port uint16, isTCP bool) []byte`
  - `func EncodeSendPayload(flowID uint64, payload []byte) [][]byte` (chunked)
  - `func EncodeCloseFlow(flowID uint64) []byte`
  - `func EncodeOpenReply(reqID uint32, ok bool, errMsg string) []byte`
  - `func EncodeDeliver(flowID uint64, payload []byte) [][]byte` (chunked)
  - `func EncodeFlowClosed(flowID uint64, errMsg string) []byte`
  - `func Parse(buf []byte) (*Frame, int, error)` — `(nil, 0, nil)` = need more data; `(f, consumed, nil)` = one frame; `(nil, 0, ErrMalformed-wrapped)` = poisoned stream, caller must close.

- [ ] **Step 1: Write the failing test with golden vectors**

These hex vectors were computed from the Swift layout in `Shared/RelayWireFrame.swift` (Task 2 pins the Swift side to the identical bytes):

```go
package relaywire

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func h(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// Golden vectors shared with Tests/Unit/RelayWireFrameGoldenVectorTests.swift.
const (
	vecOpen       = "0000001d0100000001000000000000000201bb01000b6578616d706c652e636f6d" // reqID=1 flowID=2 example.com:443 tcp
	vecSend       = "0000000d020000000000000002deadbeef"                                 // flowID=2 payload deadbeef
	vecClose      = "00000009030000000000000002"                                         // flowID=2
	vecOpenReply  = "000000088100000001010000"                                           // reqID=1 ok, no error
	vecDeliver    = "0000000b820000000000000002cafe"                                     // flowID=2 payload cafe
	vecFlowClosed = "0000000e8300000000000000020003656f66"                               // flowID=2 err "eof"
)

func TestEncodeGoldenVectors(t *testing.T) {
	if got := EncodeOpenFlow(1, 2, "example.com", 443, true); !bytes.Equal(got, h(t, vecOpen)) {
		t.Fatalf("open: got %x", got)
	}
	if got := EncodeSendPayload(2, h(t, "deadbeef")); len(got) != 1 || !bytes.Equal(got[0], h(t, vecSend)) {
		t.Fatalf("send: got %x", got)
	}
	if got := EncodeCloseFlow(2); !bytes.Equal(got, h(t, vecClose)) {
		t.Fatalf("close: got %x", got)
	}
	if got := EncodeOpenReply(1, true, ""); !bytes.Equal(got, h(t, vecOpenReply)) {
		t.Fatalf("openReply: got %x", got)
	}
	if got := EncodeDeliver(2, h(t, "cafe")); len(got) != 1 || !bytes.Equal(got[0], h(t, vecDeliver)) {
		t.Fatalf("deliver: got %x", got)
	}
	if got := EncodeFlowClosed(2, "eof"); !bytes.Equal(got, h(t, vecFlowClosed)) {
		t.Fatalf("flowClosed: got %x", got)
	}
}

func TestParseGoldenVectors(t *testing.T) {
	f, n, err := Parse(h(t, vecOpen))
	if err != nil || n != 33 || f.Type != TypeOpenFlow || f.ReqID != 1 || f.FlowID != 2 ||
		f.Host != "example.com" || f.Port != 443 || !f.IsTCP {
		t.Fatalf("open: %+v n=%d err=%v", f, n, err)
	}
	f, _, err = Parse(h(t, vecFlowClosed))
	if err != nil || f.Type != TypeFlowClosed || f.FlowID != 2 || f.Err != "eof" {
		t.Fatalf("flowClosed: %+v err=%v", f, err)
	}
	f, _, err = Parse(h(t, vecOpenReply))
	if err != nil || f.Type != TypeOpenReply || !f.OK || f.Err != "" {
		t.Fatalf("openReply: %+v err=%v", f, err)
	}
}

func TestParseIncrementalAndMalformed(t *testing.T) {
	full := h(t, vecSend)
	for i := 0; i < len(full); i++ {
		if f, n, err := Parse(full[:i]); f != nil || n != 0 || err != nil {
			t.Fatalf("prefix %d: should need more data", i)
		}
	}
	// two frames back to back: first Parse consumes exactly the first
	both := append(append([]byte{}, full...), h(t, vecClose)...)
	f, n, err := Parse(both)
	if err != nil || f.Type != TypeSendPayload || n != len(full) {
		t.Fatalf("concat: %+v n=%d err=%v", f, n, err)
	}
	// zero-length frame
	if _, _, err := Parse(h(t, "00000000")); err == nil {
		t.Fatal("zero-length frame must be malformed")
	}
	// oversized length
	if _, _, err := Parse(h(t, "00200001ff")); err == nil {
		t.Fatal("oversized frame must be malformed")
	}
	// unknown type
	if _, _, err := Parse(h(t, "00000009440000000000000002")); err == nil {
		t.Fatal("unknown type must be malformed")
	}
}

func TestChunkingSplitsLargePayloads(t *testing.T) {
	big := make([]byte, MaxFrameBody) // > maxPayloadChunk, must split into 2 frames
	frames := EncodeSendPayload(7, big)
	if len(frames) != 2 {
		t.Fatalf("want 2 frames, got %d", len(frames))
	}
	var total int
	for _, fr := range frames {
		f, n, err := Parse(fr)
		if err != nil || n != len(fr) || f.FlowID != 7 {
			t.Fatalf("chunk: %+v err=%v", f, err)
		}
		total += len(f.Payload)
	}
	if total != len(big) {
		t.Fatalf("payload bytes lost: %d != %d", total, len(big))
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android/core && go test ./relaywire/`
Expected: FAIL (package does not exist / functions undefined).

- [ ] **Step 3: Write the implementation**

```go
// Package relaywire is the Go port of the macOS RelayWireFrame protocol
// (Shared/RelayWireFrame.swift). Layout, big-endian: [uint32 length][uint8 type][body],
// where length covers type+body. Byte-for-byte compatibility is pinned by golden
// vectors shared with the Swift unit tests.
package relaywire

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	TypeOpenFlow    byte = 0x01
	TypeSendPayload byte = 0x02
	TypeCloseFlow   byte = 0x03
	TypeOpenReply   byte = 0x81
	TypeDeliver     byte = 0x82
	TypeFlowClosed  byte = 0x83
)

const MaxFrameBody = 1 << 20
const maxPayloadChunk = MaxFrameBody - 9 // type(1) + flowID(8)

var ErrMalformed = errors.New("relaywire: malformed frame")

type Frame struct {
	Type    byte
	ReqID   uint32
	FlowID  uint64
	Host    string
	Port    uint16
	IsTCP   bool
	OK      bool
	Err     string
	Payload []byte
}

func withLength(body []byte) []byte {
	out := make([]byte, 4+len(body))
	binary.BigEndian.PutUint32(out, uint32(len(body)))
	copy(out[4:], body)
	return out
}

func EncodeOpenFlow(reqID uint32, flowID uint64, host string, port uint16, isTCP bool) []byte {
	hb := []byte(host)
	if len(hb) > 0xFFFF {
		hb = hb[:0xFFFF]
	}
	body := make([]byte, 0, 1+4+8+2+1+2+len(hb))
	body = append(body, TypeOpenFlow)
	body = binary.BigEndian.AppendUint32(body, reqID)
	body = binary.BigEndian.AppendUint64(body, flowID)
	body = binary.BigEndian.AppendUint16(body, port)
	if isTCP {
		body = append(body, 1)
	} else {
		body = append(body, 0)
	}
	body = binary.BigEndian.AppendUint16(body, uint16(len(hb)))
	body = append(body, hb...)
	return withLength(body)
}

func encodeChunked(typ byte, flowID uint64, payload []byte) [][]byte {
	var frames [][]byte
	for {
		chunk := payload
		if len(chunk) > maxPayloadChunk {
			chunk = payload[:maxPayloadChunk]
		}
		body := make([]byte, 0, 1+8+len(chunk))
		body = append(body, typ)
		body = binary.BigEndian.AppendUint64(body, flowID)
		body = append(body, chunk...)
		frames = append(frames, withLength(body))
		payload = payload[len(chunk):]
		if len(payload) == 0 {
			return frames
		}
	}
}

func EncodeSendPayload(flowID uint64, payload []byte) [][]byte {
	return encodeChunked(TypeSendPayload, flowID, payload)
}

func EncodeDeliver(flowID uint64, payload []byte) [][]byte {
	return encodeChunked(TypeDeliver, flowID, payload)
}

func EncodeCloseFlow(flowID uint64) []byte {
	body := make([]byte, 0, 9)
	body = append(body, TypeCloseFlow)
	body = binary.BigEndian.AppendUint64(body, flowID)
	return withLength(body)
}

func EncodeOpenReply(reqID uint32, ok bool, errMsg string) []byte {
	eb := []byte(errMsg)
	if len(eb) > 0xFFFF {
		eb = eb[:0xFFFF]
	}
	body := make([]byte, 0, 1+4+1+2+len(eb))
	body = append(body, TypeOpenReply)
	body = binary.BigEndian.AppendUint32(body, reqID)
	if ok {
		body = append(body, 1)
	} else {
		body = append(body, 0)
	}
	body = binary.BigEndian.AppendUint16(body, uint16(len(eb)))
	body = append(body, eb...)
	return withLength(body)
}

func EncodeFlowClosed(flowID uint64, errMsg string) []byte {
	eb := []byte(errMsg)
	if len(eb) > 0xFFFF {
		eb = eb[:0xFFFF]
	}
	body := make([]byte, 0, 1+8+2+len(eb))
	body = append(body, TypeFlowClosed)
	body = binary.BigEndian.AppendUint64(body, flowID)
	body = binary.BigEndian.AppendUint16(body, uint16(len(eb)))
	body = append(body, eb...)
	return withLength(body)
}

// Parse decodes one frame off the front of buf.
// (nil, 0, nil) means the buffer holds a valid prefix — feed more bytes and retry.
// A non-nil error wraps ErrMalformed: the stream cannot be resynced, close the link.
func Parse(buf []byte) (*Frame, int, error) {
	if len(buf) < 4 {
		return nil, 0, nil
	}
	length := binary.BigEndian.Uint32(buf)
	if length < 1 {
		return nil, 0, fmt.Errorf("%w: zero-length frame", ErrMalformed)
	}
	if length > MaxFrameBody {
		return nil, 0, fmt.Errorf("%w: length %d exceeds cap", ErrMalformed, length)
	}
	total := 4 + int(length)
	if len(buf) < total {
		return nil, 0, nil
	}
	body := buf[4:total]
	f := &Frame{Type: body[0]}
	p := body[1:]
	bad := func(what string) (*Frame, int, error) {
		return nil, 0, fmt.Errorf("%w: %s for type 0x%02x", ErrMalformed, what, f.Type)
	}
	switch f.Type {
	case TypeOpenFlow:
		if len(p) < 4+8+2+1+2 {
			return bad("short body")
		}
		f.ReqID = binary.BigEndian.Uint32(p)
		f.FlowID = binary.BigEndian.Uint64(p[4:])
		f.Port = binary.BigEndian.Uint16(p[12:])
		f.IsTCP = p[14] != 0
		hostLen := int(binary.BigEndian.Uint16(p[15:]))
		if len(p) < 17+hostLen {
			return bad("short host")
		}
		f.Host = string(p[17 : 17+hostLen])
	case TypeSendPayload, TypeDeliver:
		if len(p) < 8 {
			return bad("short body")
		}
		f.FlowID = binary.BigEndian.Uint64(p)
		f.Payload = append([]byte(nil), p[8:]...)
	case TypeCloseFlow:
		if len(p) < 8 {
			return bad("short body")
		}
		f.FlowID = binary.BigEndian.Uint64(p)
	case TypeOpenReply:
		if len(p) < 4+1+2 {
			return bad("short body")
		}
		f.ReqID = binary.BigEndian.Uint32(p)
		f.OK = p[4] != 0
		errLen := int(binary.BigEndian.Uint16(p[5:]))
		if len(p) < 7+errLen {
			return bad("short error")
		}
		f.Err = string(p[7 : 7+errLen])
	case TypeFlowClosed:
		if len(p) < 8+2 {
			return bad("short body")
		}
		f.FlowID = binary.BigEndian.Uint64(p)
		errLen := int(binary.BigEndian.Uint16(p[8:]))
		if len(p) < 10+errLen {
			return bad("short error")
		}
		f.Err = string(p[10 : 10+errLen])
	default:
		return bad("unknown frame type")
	}
	return f, total, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd android/core && go test ./relaywire/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android/core/relaywire/
git commit -m "feat(share): Go port of the RelayWireFrame flow-mux codec"
```

---

### Task 2: Swift golden-vector parity test for RelayWireFrame

**Files:**
- Test: `Tests/Unit/RelayWireFrameGoldenVectorTests.swift`
- Modify: `project.yml` (add the test file to the `TunnelBahnUnitTests` target's file-by-file sources list)

**Interfaces:**
- Consumes: `RelayWireFrame` (existing, `Shared/RelayWireFrame.swift`); the six hex vectors from Task 1 (they must stay literally identical in both files).
- Produces: nothing (regression pin only).

- [ ] **Step 1: Write the test**

```swift
import XCTest
@testable import TunnelBahn

/// Pins RelayWireFrame's bytes to the fixtures shared with the Go port
/// (android/core/relaywire/relaywire_test.go). If either side changes, phone/Mac
/// relay interop breaks — these vectors must stay in lockstep.
final class RelayWireFrameGoldenVectorTests: XCTestCase {
    private func hexData(_ s: String) -> Data {
        var d = Data()
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            d.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return d
    }

    func testEncodersMatchGoldenVectors() {
        XCTAssertEqual(
            RelayWireFrame.encodeOpenFlowRequest(reqID: 1, flowID: 2, remoteHost: "example.com", remotePort: 443, isTCP: true),
            hexData("0000001d0100000001000000000000000201bb01000b6578616d706c652e636f6d"))
        XCTAssertEqual(
            RelayWireFrame.encodeSendPayloadRequest(flowID: 2, payload: hexData("deadbeef")),
            [hexData("0000000d020000000000000002deadbeef")])
        XCTAssertEqual(
            RelayWireFrame.encodeCloseFlowRequest(flowID: 2),
            hexData("00000009030000000000000002"))
        XCTAssertEqual(
            RelayWireFrame.encodeOpenFlowReply(reqID: 1, ok: true, error: nil),
            hexData("000000088100000001010000"))
        XCTAssertEqual(
            RelayWireFrame.encodeDeliverPayloadPush(flowID: 2, payload: hexData("cafe")),
            [hexData("0000000b820000000000000002cafe")])
        XCTAssertEqual(
            RelayWireFrame.encodeFlowClosedPush(flowID: 2, error: "eof"),
            hexData("0000000e8300000000000000020003656f66"))
    }

    func testParserRoundTripsGoldenVectors() {
        guard case let .frame(frame, consumed) = RelayWireFrame.parse(
            hexData("0000001d0100000001000000000000000201bb01000b6578616d706c652e636f6d")) else {
            return XCTFail("expected a frame")
        }
        XCTAssertEqual(consumed, 33)
        guard case let .openFlowRequest(reqID, flowID, host, port, isTCP) = frame else {
            return XCTFail("wrong frame kind")
        }
        XCTAssertEqual(reqID, 1)
        XCTAssertEqual(flowID, 2)
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(port, 443)
        XCTAssertTrue(isTCP)
    }
}
```

- [ ] **Step 2: Register the file and run the test**

Add `Tests/Unit/RelayWireFrameGoldenVectorTests.swift` to the `TunnelBahnUnitTests` sources list in `project.yml`, then:

Run: `xcodegen generate && xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' test -only-testing:TunnelBahnUnitTests/RelayWireFrameGoldenVectorTests`
Expected: PASS (the Swift implementation already exists; this pins it).

- [ ] **Step 3: Commit**

```bash
git add Tests/Unit/RelayWireFrameGoldenVectorTests.swift project.yml
git commit -m "test(share): pin RelayWireFrame bytes to cross-language golden vectors"
```

---

### Task 3: Go `share` handshake primitives + ephemeral TLS cert

**Files:**
- Create: `android/core/share/handshake.go`
- Test: `android/core/share/handshake_test.go`

**Interfaces:**
- Consumes: stdlib only.
- Produces (used by Tasks 4–5; the Swift mirror in Task 4 must produce identical proofs):
  - `const DefaultPort = 47600`
  - `var Magic = [4]byte{'T', 'B', 'S', 'H'}` and `const Version byte = 1`
  - `func ServerProof(secret, clientNonce, serverNonce, certDER []byte) []byte` (32 bytes)
  - `func ClientProof(secret, serverNonce, clientNonce []byte) []byte` (32 bytes)
  - `func GenerateCert() (tls.Certificate, error)` — self-signed ECDSA P-256, CN "TunnelBahn Share", 10-year validity, ephemeral per share session (trust comes from the proof binding, not the cert).

- [ ] **Step 1: Generate the shared proof vectors**

Run this and keep the two hex outputs; they go verbatim into this task's Go test AND Task 4's Swift test:

```bash
python3 - <<'EOF'
import hmac, hashlib
secret = bytes.fromhex("aa" * 32)
cn = bytes.fromhex("01" * 32)
sn = bytes.fromhex("02" * 32)
certhash = hashlib.sha256(b"cert-der-fixture").digest()
print("serverProof:", hmac.new(secret, b"tbshare-server" + cn + sn + certhash, hashlib.sha256).hexdigest())
print("clientProof:", hmac.new(secret, b"tbshare-client" + sn + cn, hashlib.sha256).hexdigest())
EOF
```

- [ ] **Step 2: Write the failing test**

```go
package share

import (
	"bytes"
	"crypto/x509"
	"encoding/hex"
	"testing"
	"time"
)

func fill(b byte, n int) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = b
	}
	return out
}

func TestProofVectors(t *testing.T) {
	secret := fill(0xaa, 32)
	cn := fill(0x01, 32)
	sn := fill(0x02, 32)
	// PASTE the two hex strings printed by the python generator in Step 1:
	wantServer, _ := hex.DecodeString("<serverProof hex from Step 1>")
	wantClient, _ := hex.DecodeString("<clientProof hex from Step 1>")
	if got := ServerProof(secret, cn, sn, []byte("cert-der-fixture")); !bytes.Equal(got, wantServer) {
		t.Fatalf("server proof: got %x", got)
	}
	if got := ClientProof(secret, sn, cn); !bytes.Equal(got, wantClient) {
		t.Fatalf("client proof: got %x", got)
	}
}

func TestProofsDependOnEveryInput(t *testing.T) {
	secret, cn, sn := fill(0xaa, 32), fill(0x01, 32), fill(0x02, 32)
	base := ServerProof(secret, cn, sn, []byte("cert"))
	if bytes.Equal(base, ServerProof(fill(0xab, 32), cn, sn, []byte("cert"))) {
		t.Fatal("secret ignored")
	}
	if bytes.Equal(base, ServerProof(secret, cn, sn, []byte("cert2"))) {
		t.Fatal("cert binding ignored — MITM cert substitution would go undetected")
	}
}

func TestGenerateCertIsValidTLSServerCert(t *testing.T) {
	cert, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if leaf.Subject.CommonName != "TunnelBahn Share" {
		t.Fatalf("CN: %s", leaf.Subject.CommonName)
	}
	if time.Now().Add(9 * 365 * 24 * time.Hour).After(leaf.NotAfter) {
		t.Fatal("validity too short")
	}
}
```

(The TLS loopback test in Task 5 exercises the cert for real.)

- [ ] **Step 3: Run test to verify it fails**

Run: `cd android/core && go test ./share/`
Expected: FAIL (undefined functions).

- [ ] **Step 4: Implement**

```go
// Package share implements the phone-side tunnel-sharing listener: TLS + a mutual
// HMAC handshake bound to the pairing secret, then RelayWireFrame flow relaying
// through the session's live transport.
package share

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"time"
)

const DefaultPort = 47600
const Version byte = 1

var Magic = [4]byte{'T', 'B', 'S', 'H'}

// ServerProof binds the pairing secret to both nonces AND the certificate the
// server actually presented, so a MITM terminating TLS with its own cert cannot
// relay the handshake: the client compares against the cert it observed.
func ServerProof(secret, clientNonce, serverNonce, certDER []byte) []byte {
	h := sha256.Sum256(certDER)
	m := hmac.New(sha256.New, secret)
	m.Write([]byte("tbshare-server"))
	m.Write(clientNonce)
	m.Write(serverNonce)
	m.Write(h[:])
	return m.Sum(nil)
}

func ClientProof(secret, serverNonce, clientNonce []byte) []byte {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte("tbshare-client"))
	m.Write(serverNonce)
	m.Write(clientNonce)
	return m.Sum(nil)
}

func GenerateCert() (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "TunnelBahn Share"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(10 * 365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd android/core && go test ./share/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add android/core/share/
git commit -m "feat(share): tbshare handshake proofs and ephemeral server cert"
```

---

### Task 4: Swift handshake mirror + pairing QR payload codec

**Files:**
- Create: `Shared/PhoneRelayHandshake.swift`
- Create: `Shared/PhoneRelayPairing.swift`
- Test: `Tests/Unit/PhoneRelayHandshakeTests.swift`
- Modify: `project.yml` (add the two Shared files to the app + NetworkExtension target sources and, with the test file, to `TunnelBahnUnitTests`)

**Interfaces:**
- Consumes: CryptoKit; the proof vectors from Task 3 Step 1.
- Produces (used by Tasks 12–13):
  - `enum PhoneRelayHandshake` — `static let magic = Data("TBSH".utf8)`, `static let version: UInt8 = 1`, `static let defaultPort: UInt16 = 47600`, `static func serverProof(secret: Data, clientNonce: Data, serverNonce: Data, certDER: Data) -> Data`, `static func clientProof(secret: Data, serverNonce: Data, clientNonce: Data) -> Data`, `static func makeClientHello(peerID: Data, clientNonce: Data) -> Data` (magic ‖ version ‖ peerID(16) ‖ nonce(32) = 53 bytes), `static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool`, `static func randomBytes(_ count: Int) -> Data`
  - `struct PhoneRelayPairing: Codable, Equatable { var kind: String; var v: Int; var id: String; var secret: String; var name: String; var port: Int }` with `static func generate(name: String) -> PhoneRelayPairing` (random 16-byte id / 32-byte secret, hex), `func qrJSONString() throws -> String`, `static func parse(_ raw: String) -> PhoneRelayPairing?` (validates kind, v, hex lengths).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TunnelBahn

final class PhoneRelayHandshakeTests: XCTestCase {
    private func hexData(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex { let n = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<n], radix: 16)!); i = n }
        return d
    }

    func testProofVectorsMatchGoCore() {
        let secret = Data(repeating: 0xaa, count: 32)
        let cn = Data(repeating: 0x01, count: 32)
        let sn = Data(repeating: 0x02, count: 32)
        // Same fixtures as android/core/share/handshake_test.go — PASTE from Task 3 Step 1:
        XCTAssertEqual(
            PhoneRelayHandshake.serverProof(secret: secret, clientNonce: cn, serverNonce: sn,
                                            certDER: Data("cert-der-fixture".utf8)),
            hexData("<serverProof hex from Task 3 Step 1>"))
        XCTAssertEqual(
            PhoneRelayHandshake.clientProof(secret: secret, serverNonce: sn, clientNonce: cn),
            hexData("<clientProof hex from Task 3 Step 1>"))
    }

    func testClientHelloLayout() {
        let peerID = Data(repeating: 0x0f, count: 16)
        let nonce = Data(repeating: 0x0e, count: 32)
        let hello = PhoneRelayHandshake.makeClientHello(peerID: peerID, clientNonce: nonce)
        XCTAssertEqual(hello.count, 53)
        XCTAssertEqual(hello.prefix(4), Data("TBSH".utf8))
        XCTAssertEqual(hello[4], 1)
        XCTAssertEqual(hello.subdata(in: 5..<21), peerID)
        XCTAssertEqual(hello.suffix(32), nonce)
    }

    func testPairingPayloadRoundTripAndValidation() throws {
        let pairing = PhoneRelayPairing.generate(name: "My Mac")
        XCTAssertEqual(pairing.id.count, 32)      // 16 bytes hex
        XCTAssertEqual(pairing.secret.count, 64)  // 32 bytes hex
        XCTAssertEqual(pairing.port, 47600)
        let json = try pairing.qrJSONString()
        XCTAssertEqual(PhoneRelayPairing.parse(json), pairing)
        XCTAssertNil(PhoneRelayPairing.parse("{\"kind\":\"other\"}"))
        XCTAssertNil(PhoneRelayPairing.parse("not json"))
        // truncated secret must be rejected
        var bad = pairing; bad.secret = String(bad.secret.dropLast(2))
        XCTAssertNil(PhoneRelayPairing.parse(String(data: try JSONEncoder().encode(bad), encoding: .utf8)!))
    }
}
```

- [ ] **Step 2: Register files in project.yml, run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' test -only-testing:TunnelBahnUnitTests/PhoneRelayHandshakeTests`
Expected: FAIL (types don't exist yet — add empty files first so the target compiles, or accept the compile failure as the "red" state).

- [ ] **Step 3: Implement `Shared/PhoneRelayHandshake.swift`**

```swift
import CryptoKit
import Foundation

/// Client half of the "tbshare v1" handshake (spec:
/// docs/superpowers/specs/2026-08-30-tunnel-share-design.md). The Go server half
/// lives in android/core/share; the proof vectors are pinned in both test suites.
public enum PhoneRelayHandshake {
    public static let magic = Data("TBSH".utf8)
    public static let version: UInt8 = 1
    public static let defaultPort: UInt16 = 47600
    public static let nonceLength = 32
    public static let peerIDLength = 16

    public static func serverProof(secret: Data, clientNonce: Data, serverNonce: Data, certDER: Data) -> Data {
        var msg = Data("tbshare-server".utf8)
        msg.append(clientNonce)
        msg.append(serverNonce)
        msg.append(Data(SHA256.hash(data: certDER)))
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: secret)))
    }

    public static func clientProof(secret: Data, serverNonce: Data, clientNonce: Data) -> Data {
        var msg = Data("tbshare-client".utf8)
        msg.append(serverNonce)
        msg.append(clientNonce)
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: secret)))
    }

    public static func makeClientHello(peerID: Data, clientNonce: Data) -> Data {
        var out = magic
        out.append(version)
        out.append(peerID.prefix(peerIDLength))
        out.append(clientNonce.prefix(nonceLength))
        return out
    }

    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
```

- [ ] **Step 4: Implement `Shared/PhoneRelayPairing.swift`**

```swift
import Foundation

/// The QR payload the Mac renders and the phone scans. Kotlin parser:
/// android/app/.../share/SharePairing.kt — field names must stay in lockstep.
public struct PhoneRelayPairing: Codable, Equatable {
    public var kind: String
    public var v: Int
    public var id: String     // 16 bytes, lowercase hex
    public var secret: String // 32 bytes, lowercase hex
    public var name: String
    public var port: Int

    public static let expectedKind = "tunnelbahn.pair"

    public static func generate(name: String) -> PhoneRelayPairing {
        PhoneRelayPairing(
            kind: expectedKind, v: 1,
            id: PhoneRelayHandshake.randomBytes(16).map { String(format: "%02x", $0) }.joined(),
            secret: PhoneRelayHandshake.randomBytes(32).map { String(format: "%02x", $0) }.joined(),
            name: name, port: Int(PhoneRelayHandshake.defaultPort))
    }

    public func qrJSONString() throws -> String {
        String(data: try JSONEncoder().encode(self), encoding: .utf8) ?? ""
    }

    public static func parse(_ raw: String) -> PhoneRelayPairing? {
        guard let data = raw.data(using: .utf8),
              let p = try? JSONDecoder().decode(PhoneRelayPairing.self, from: data),
              p.kind == expectedKind, p.v == 1,
              p.id.count == 32, p.secret.count == 64,
              p.id.allSatisfy(\.isHexDigit), p.secret.allSatisfy(\.isHexDigit),
              (1...65535).contains(p.port)
        else { return nil }
        return p
    }
}
```

- [ ] **Step 5: Run test to verify it passes, then commit**

Run: `xcodegen generate && xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' test -only-testing:TunnelBahnUnitTests/PhoneRelayHandshakeTests`
Expected: PASS.

```bash
git add Shared/PhoneRelayHandshake.swift Shared/PhoneRelayPairing.swift Tests/Unit/PhoneRelayHandshakeTests.swift project.yml
git commit -m "feat(share): Mac-side tbshare handshake and pairing QR codec"
```

---

### Task 5: Go `share.Server` — config, auth, TCP flow relaying

**Files:**
- Create: `android/core/share/server.go`
- Create: `android/core/share/config.go`
- Test: `android/core/share/server_test.go`

**Interfaces:**
- Consumes: Task 1 (`relaywire`), Task 3 (handshake), `android/core/transport.Transport` (existing: `WaitReady/DialTCP/DialUDP/Close`, `transport.ErrUnsupportedProtocol`).
- Produces (used by Tasks 6–7):
  - `type Peer struct { ID [16]byte; Secret []byte; Name string }`
  - `type Config struct { Port int; Peers []Peer; Resolve func(ctx context.Context, query []byte) ([]byte, error); Control func(network, address string, c syscall.RawConn) error; Logf func(format string, args ...any) }` — `Resolve` is injected (a closure over the session's `ResolveOverTCP`) to avoid a core↔share import cycle; `Control` is the existing protect() hook; nil `Logf` → no-op.
  - `func ParseConfig(jsonStr string) (port int, peers []Peer, err error)` for `{"port":47600,"peers":[{"id":"<hex16B>","secret":"<hex32B>","name":"..."}]}`
  - `func NewServer(cfg Config, tr transport.Transport, cert tls.Certificate) *Server`
  - `func (s *Server) Start() error` (binds `0.0.0.0:cfg.Port` via `net.ListenConfig{Control: cfg.Control}`, wraps with `tls.NewListener`, accept loop in a goroutine)
  - `func (s *Server) Addr() string` (for tests with Port 0)
  - `func (s *Server) Close()` (closes listener and every client conn/flow)
  - `func (s *Server) ClientCount() int`
  - Per-connection behavior (tested here): 10 s handshake deadline; unknown peerID or bad proof → close with no distinguishing reply; after auth, `reqOpenFlow(isTCP=true)` → `tr.DialTCP` → `repOpenFlow` → bidirectional pump (`reqSendPayload`→conn write, conn read→`pushDeliver`, EOF/error→`pushFlowClosed`); `reqCloseFlow` closes the dial; malformed frame → connection torn down; all writes to the client conn serialized by a per-connection mutex.

- [ ] **Step 1: Write the failing test**

Build a `fakeTransport` whose `DialTCP` returns an in-memory echo (via `net.Pipe`), and a minimal test client that runs the real TLS dial + handshake + frames:

```go
package share

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/netip"
	"testing"
	"time"

	"tunnelbahn/core/relaywire"
	"tunnelbahn/core/transport"
)

type fakeTransport struct{ dialErr error }

func (f *fakeTransport) WaitReady(ctx context.Context) error { return nil }
func (f *fakeTransport) Close() error                        { return nil }
func (f *fakeTransport) DialUDP(ctx context.Context, dst netip.AddrPort) (net.PacketConn, error) {
	return nil, transport.ErrUnsupportedProtocol
}
func (f *fakeTransport) DialTCP(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
	if f.dialErr != nil {
		return nil, f.dialErr
	}
	a, b := net.Pipe()
	go io.Copy(b, b) // echo
	return a, nil
}

var testPeer = Peer{ID: [16]byte{1}, Secret: bytes.Repeat([]byte{0xaa}, 32), Name: "test"}

func startTestServer(t *testing.T, tr transport.Transport) (*Server, string) {
	t.Helper()
	cert, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	srv := NewServer(Config{Port: 0, Peers: []Peer{testPeer}}, tr, cert)
	if err := srv.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)
	return srv, srv.Addr()
}

// dialAndAuth performs the real client half of the handshake.
func dialAndAuth(t *testing.T, addr string, secret []byte) net.Conn {
	t.Helper()
	conn, err := tls.Dial("tcp", addr, &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		t.Fatal(err)
	}
	observedDER := conn.ConnectionState().PeerCertificates[0].Raw
	cn := make([]byte, 32)
	rand.Read(cn)
	hello := append(append([]byte("TBSH"), 1), append(testPeer.ID[:], cn...)...)
	if _, err := conn.Write(hello); err != nil {
		t.Fatal(err)
	}
	resp := make([]byte, 64)
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(conn, resp); err != nil {
		t.Fatal(err)
	}
	sn, proof := resp[:32], resp[32:]
	if !bytes.Equal(proof, ServerProof(secret, cn, sn, observedDER)) {
		t.Fatal("server proof mismatch")
	}
	if _, err := conn.Write(ClientProof(secret, sn, cn)); err != nil {
		t.Fatal(err)
	}
	status := make([]byte, 1)
	if _, err := io.ReadFull(conn, status); err != nil || status[0] != 1 {
		t.Fatalf("auth status: %v %v", status, err)
	}
	return conn
}

func readFrame(t *testing.T, conn net.Conn, buf *[]byte) *relaywire.Frame {
	t.Helper()
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	tmp := make([]byte, 64*1024)
	for {
		if f, n, err := relaywire.Parse(*buf); err != nil {
			t.Fatal(err)
		} else if f != nil {
			*buf = (*buf)[n:]
			return f
		}
		n, err := conn.Read(tmp)
		if err != nil {
			t.Fatal(err)
		}
		*buf = append(*buf, tmp[:n]...)
	}
}

func TestTCPFlowEchoesThroughTransport(t *testing.T) {
	_, addr := startTestServer(t, &fakeTransport{})
	conn := dialAndAuth(t, addr, testPeer.Secret)
	defer conn.Close()
	var buf []byte
	conn.Write(relaywire.EncodeOpenFlow(1, 42, "10.0.0.9", 80, true))
	if f := readFrame(t, conn, &buf); f.Type != relaywire.TypeOpenReply || !f.OK {
		t.Fatalf("open reply: %+v", f)
	}
	for _, fr := range relaywire.EncodeSendPayload(42, []byte("hello")) {
		conn.Write(fr)
	}
	if f := readFrame(t, conn, &buf); f.Type != relaywire.TypeDeliver || !bytes.Equal(f.Payload, []byte("hello")) {
		t.Fatalf("deliver: %+v", f)
	}
	conn.Write(relaywire.EncodeCloseFlow(42))
}

func TestDialFailureRepliesNotOK(t *testing.T) {
	_, addr := startTestServer(t, &fakeTransport{dialErr: fmt.Errorf("no route")})
	conn := dialAndAuth(t, addr, testPeer.Secret)
	defer conn.Close()
	var buf []byte
	conn.Write(relaywire.EncodeOpenFlow(1, 1, "10.0.0.9", 80, true))
	if f := readFrame(t, conn, &buf); f.Type != relaywire.TypeOpenReply || f.OK || f.Err == "" {
		t.Fatalf("want ok=false with error, got %+v", f)
	}
}

func TestWrongSecretIsRejected(t *testing.T) {
	_, addr := startTestServer(t, &fakeTransport{})
	conn, err := tls.Dial("tcp", addr, &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	cn := make([]byte, 32)
	hello := append(append([]byte("TBSH"), 1), append(testPeer.ID[:], cn...)...)
	conn.Write(hello)
	resp := make([]byte, 64)
	io.ReadFull(conn, resp)
	conn.Write(ClientProof(bytes.Repeat([]byte{0xbb}, 32), resp[:32], cn)) // wrong secret
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	one := make([]byte, 1)
	if n, err := conn.Read(one); err == nil && one[0] == 1 {
		t.Fatalf("authenticated with wrong secret (n=%d)", n)
	}
}

func TestUnknownPeerIDIsRejected(t *testing.T) {
	_, addr := startTestServer(t, &fakeTransport{})
	conn, err := tls.Dial("tcp", addr, &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	hello := append(append([]byte("TBSH"), 1), make([]byte, 48)...) // zero peerID+nonce
	conn.Write(hello)
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(conn, make([]byte, 64)); err == nil {
		t.Fatal("server responded to unknown peer")
	}
}

func TestMalformedFrameTearsDownConnection(t *testing.T) {
	_, addr := startTestServer(t, &fakeTransport{})
	conn := dialAndAuth(t, addr, testPeer.Secret)
	defer conn.Close()
	bad := make([]byte, 8)
	binary.BigEndian.PutUint32(bad, 4)
	bad[4] = 0x44 // unknown type
	conn.Write(bad)
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("connection survived malformed frame")
	}
}

func TestParseConfig(t *testing.T) {
	port, peers, err := ParseConfig(`{"port":47600,"peers":[{"id":"` +
		"01000000000000000000000000000000" + `","secret":"` +
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" + `","name":"mac"}]}`)
	if err != nil || port != 47600 || len(peers) != 1 || peers[0].Name != "mac" || peers[0].ID != testPeer.ID {
		t.Fatalf("port=%d peers=%+v err=%v", port, peers, err)
	}
	if _, _, err := ParseConfig(`{"peers":[{"id":"zz","secret":"aa","name":"x"}]}`); err == nil {
		t.Fatal("bad hex must error")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android/core && go test ./share/`
Expected: FAIL (Server/Config/ParseConfig undefined).

- [ ] **Step 3: Implement `config.go`**

```go
package share

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
)

type Peer struct {
	ID     [16]byte
	Secret []byte
	Name   string
}

func ParseConfig(jsonStr string) (int, []Peer, error) {
	var raw struct {
		Port  int `json:"port"`
		Peers []struct {
			ID     string `json:"id"`
			Secret string `json:"secret"`
			Name   string `json:"name"`
		} `json:"peers"`
	}
	if err := json.Unmarshal([]byte(jsonStr), &raw); err != nil {
		return 0, nil, fmt.Errorf("share config: %w", err)
	}
	port := raw.Port
	if port == 0 {
		port = DefaultPort
	}
	var peers []Peer
	for _, p := range raw.Peers {
		id, err := hex.DecodeString(p.ID)
		if err != nil || len(id) != 16 {
			return 0, nil, fmt.Errorf("share config: bad peer id %q", p.ID)
		}
		secret, err := hex.DecodeString(p.Secret)
		if err != nil || len(secret) != 32 {
			return 0, nil, fmt.Errorf("share config: bad peer secret for %q", p.Name)
		}
		var pid [16]byte
		copy(pid[:], id)
		peers = append(peers, Peer{ID: pid, Secret: secret, Name: p.Name})
	}
	return port, peers, nil
}
```

- [ ] **Step 4: Implement `server.go`**

```go
package share

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"tunnelbahn/core/relaywire"
	"tunnelbahn/core/transport"
)

type Config struct {
	Port    int
	Peers   []Peer
	Resolve func(ctx context.Context, query []byte) ([]byte, error)
	Control func(network, address string, c syscall.RawConn) error
	Logf    func(format string, args ...any)
}

type Server struct {
	cfg     Config
	tr      transport.Transport
	cert    tls.Certificate
	ln      net.Listener
	mu      sync.Mutex
	conns   map[net.Conn]struct{}
	clients atomic.Int32
	closed  atomic.Bool
}

func NewServer(cfg Config, tr transport.Transport, cert tls.Certificate) *Server {
	if cfg.Logf == nil {
		cfg.Logf = func(string, ...any) {}
	}
	if cfg.Port == 0 && cfg.Port != 0 { // placeholder to keep Port 0 = ephemeral for tests
	}
	return &Server{cfg: cfg, tr: tr, cert: cert, conns: map[net.Conn]struct{}{}}
}

func (s *Server) Start() error {
	lc := net.ListenConfig{Control: s.cfg.Control}
	ln, err := lc.Listen(context.Background(), "tcp4", fmt.Sprintf("0.0.0.0:%d", s.cfg.Port))
	if err != nil {
		return fmt.Errorf("share: listen: %w", err)
	}
	s.ln = tls.NewListener(ln, &tls.Config{Certificates: []tls.Certificate{s.cert}})
	go s.acceptLoop()
	return nil
}

func (s *Server) Addr() string { return s.ln.Addr().String() }

func (s *Server) ClientCount() int { return int(s.clients.Load()) }

func (s *Server) Close() {
	if !s.closed.CompareAndSwap(false, true) {
		return
	}
	if s.ln != nil {
		s.ln.Close()
	}
	s.mu.Lock()
	for c := range s.conns {
		c.Close()
	}
	s.mu.Unlock()
}

func (s *Server) acceptLoop() {
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			return // listener closed
		}
		s.mu.Lock()
		s.conns[conn] = struct{}{}
		s.mu.Unlock()
		go func() {
			defer func() {
				conn.Close()
				s.mu.Lock()
				delete(s.conns, conn)
				s.mu.Unlock()
			}()
			s.handleConn(conn)
		}()
	}
}

func (s *Server) handleConn(conn net.Conn) {
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	peer, ok := s.handshake(conn)
	if !ok {
		return // no distinguishing reply on auth failure
	}
	conn.SetDeadline(time.Time{})
	s.clients.Add(1)
	defer s.clients.Add(-1)
	s.cfg.Logf("share: client %q connected from %s", peer.Name, conn.RemoteAddr())

	c := &client{srv: s, conn: conn, flows: map[uint64]*flow{}}
	defer c.closeAllFlows()
	buf := make([]byte, 0, 64*1024)
	tmp := make([]byte, 64*1024)
	for {
		f, n, err := relaywire.Parse(buf)
		if err != nil {
			s.cfg.Logf("share: %v — tearing down %s", err, conn.RemoteAddr())
			return
		}
		if f != nil {
			buf = buf[n:]
			c.dispatch(f)
			continue
		}
		rn, err := conn.Read(tmp)
		if err != nil {
			return
		}
		buf = append(buf, tmp[:rn]...)
	}
}

// handshake runs the server half of tbshare v1. The TLS cert presented to the
// client is bound into the server proof so a TLS-terminating MITM is detected
// client-side (spec: docs/superpowers/specs/2026-08-30-tunnel-share-design.md).
func (s *Server) handshake(conn net.Conn) (Peer, bool) {
	hello := make([]byte, 4+1+16+32)
	if _, err := io.ReadFull(conn, hello); err != nil {
		return Peer{}, false
	}
	if [4]byte(hello[:4]) != Magic || hello[4] != Version {
		return Peer{}, false
	}
	var peer Peer
	found := false
	for _, p := range s.cfg.Peers {
		if p.ID == [16]byte(hello[5:21]) {
			peer, found = p, true
			break
		}
	}
	if !found {
		return Peer{}, false
	}
	clientNonce := hello[21:53]
	serverNonce := make([]byte, 32)
	if _, err := rand.Read(serverNonce); err != nil {
		return Peer{}, false
	}
	certDER := s.cert.Certificate[0]
	resp := append(append([]byte{}, serverNonce...), ServerProof(peer.Secret, clientNonce, serverNonce, certDER)...)
	if _, err := conn.Write(resp); err != nil {
		return Peer{}, false
	}
	proof := make([]byte, 32)
	if _, err := io.ReadFull(conn, proof); err != nil {
		return Peer{}, false
	}
	if !hmac.Equal(proof, ClientProof(peer.Secret, serverNonce, clientNonce)) {
		return Peer{}, false
	}
	if _, err := conn.Write([]byte{1}); err != nil {
		return Peer{}, false
	}
	return peer, true
}

type client struct {
	srv     *Server
	conn    net.Conn
	writeMu sync.Mutex
	flowMu  sync.Mutex
	flows   map[uint64]*flow
}

type flow struct {
	write func([]byte) error // one call per sendPayload frame
	close func()
}

func (c *client) send(frame []byte) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	c.conn.Write(frame)
}

func (c *client) sendAll(frames [][]byte) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	for _, fr := range frames {
		c.conn.Write(fr)
	}
}

func (c *client) closeAllFlows() {
	c.flowMu.Lock()
	defer c.flowMu.Unlock()
	for id, fl := range c.flows {
		fl.close()
		delete(c.flows, id)
	}
}

func (c *client) dispatch(f *relaywire.Frame) {
	switch f.Type {
	case relaywire.TypeOpenFlow:
		go c.openFlow(f)
	case relaywire.TypeSendPayload:
		c.flowMu.Lock()
		fl := c.flows[f.FlowID]
		c.flowMu.Unlock()
		if fl != nil {
			if err := fl.write(f.Payload); err != nil {
				c.dropFlow(f.FlowID, err.Error())
			}
		}
	case relaywire.TypeCloseFlow:
		c.dropFlow(f.FlowID, "")
	}
}

func (c *client) dropFlow(id uint64, errMsg string) {
	c.flowMu.Lock()
	fl := c.flows[id]
	delete(c.flows, id)
	c.flowMu.Unlock()
	if fl != nil {
		fl.close()
		if errMsg != "" {
			c.send(relaywire.EncodeFlowClosed(id, errMsg))
		}
	}
}

func (c *client) registerFlow(id uint64, fl *flow) {
	c.flowMu.Lock()
	c.flows[id] = fl
	c.flowMu.Unlock()
}

func (c *client) openFlow(f *relaywire.Frame) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if f.IsTCP {
		c.openTCPFlow(ctx, f)
		return
	}
	c.openUDPFlow(ctx, f) // implemented in Task 6; until then the stub replies unsupported
}

func (c *client) openTCPFlow(ctx context.Context, f *relaywire.Frame) {
	dst, err := c.resolveDst(ctx, f.Host, f.Port)
	if err != nil {
		c.send(relaywire.EncodeOpenReply(f.ReqID, false, err.Error()))
		return
	}
	conn, err := c.srv.tr.DialTCP(ctx, dst)
	if err != nil {
		c.send(relaywire.EncodeOpenReply(f.ReqID, false, err.Error()))
		return
	}
	c.registerFlow(f.FlowID, &flow{
		write: func(p []byte) error { _, err := conn.Write(p); return err },
		close: func() { conn.Close() },
	})
	c.send(relaywire.EncodeOpenReply(f.ReqID, true, ""))
	go func() {
		buf := make([]byte, 64*1024)
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				c.sendAll(relaywire.EncodeDeliver(f.FlowID, buf[:n]))
			}
			if err != nil {
				msg := ""
				if err != io.EOF {
					msg = err.Error()
				}
				c.flowMu.Lock()
				_, live := c.flows[f.FlowID]
				delete(c.flows, f.FlowID)
				c.flowMu.Unlock()
				if live {
					c.send(relaywire.EncodeFlowClosed(f.FlowID, msg))
				}
				conn.Close()
				return
			}
		}
	}()
}

// resolveDst passes IP literals through; hostname resolution lands in Task 6.
func (c *client) resolveDst(ctx context.Context, host string, port uint16) (netip.AddrPort, error) {
	if addr, err := netip.ParseAddr(host); err == nil {
		return netip.AddrPortFrom(addr, port), nil
	}
	return c.resolveHostname(ctx, host, port)
}
```

Add temporary stubs so Task 5 compiles alone (replaced in Task 6) — and note `NewServer` should simply leave `Port` as given (`0` = ephemeral for tests; `DefaultPort` is applied by `ParseConfig`), so remove the placeholder no-op block above if the linter flags it:

```go
func (c *client) openUDPFlow(ctx context.Context, f *relaywire.Frame) {
	c.send(relaywire.EncodeOpenReply(f.ReqID, false, "udp: not implemented"))
}

func (c *client) resolveHostname(ctx context.Context, host string, port uint16) (netip.AddrPort, error) {
	return netip.AddrPort{}, fmt.Errorf("hostname resolution not implemented")
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd android/core && go test ./share/ -race`
Expected: PASS (including `-race` — the write mutex and flow map are the racy spots).

- [ ] **Step 6: Commit**

```bash
git add android/core/share/
git commit -m "feat(share): phone-side share server with tbshare auth and TCP flow relay"
```

---

### Task 6: Go `share.Server` — UDP flows, DNS flows, hostname resolution

**Files:**
- Create: `android/core/share/udp.go` (replaces the two Task 5 stubs — delete them from `server.go`)
- Test: `android/core/share/udp_test.go`
- Modify: `android/core/go.mod` (add `golang.org/x/net` for `dns/dnsmessage` if not already present)

**Interfaces:**
- Consumes: Task 5's `client` struct, `cfg.Resolve`, `transport.ErrUnsupportedProtocol`.
- Produces:
  - `func (c *client) openUDPFlow(ctx context.Context, f *relaywire.Frame)` — dst port 53 (any host) → DNS flow where each `sendPayload` payload is one DNS query answered via `cfg.Resolve` and returned as one `pushDeliver`; other ports → `tr.DialUDP`, one frame per datagram both ways; `ErrUnsupportedProtocol` → `repOpenFlow ok=false err="transport: protocol unsupported"`.
  - `func (c *client) resolveHostname(ctx context.Context, host string, port uint16) (netip.AddrPort, error)` — builds an A query with `dnsmessage.Builder`, sends via `cfg.Resolve`, parses the first A answer. `cfg.Resolve == nil` → error.

- [ ] **Step 1: Write the failing test**

```go
package share

import (
	"bytes"
	"context"
	"net"
	"net/netip"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
	"tunnelbahn/core/relaywire"
	"tunnelbahn/core/transport"
)

// udpEchoTransport supports DialUDP with a loopback echo.
type udpEchoTransport struct{ fakeTransport }

func (u *udpEchoTransport) DialUDP(ctx context.Context, dst netip.AddrPort) (net.PacketConn, error) {
	server, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	go func() {
		buf := make([]byte, 65535)
		for {
			n, from, err := server.ReadFrom(buf)
			if err != nil {
				return
			}
			server.WriteTo(buf[:n], from)
		}
	}()
	clientSide, err := net.DialUDP("udp", nil, server.LocalAddr().(*net.UDPAddr))
	if err != nil {
		return nil, err
	}
	return clientSide, nil
}

func TestUDPFlowRoundTrip(t *testing.T) {
	_, addr := startTestServer(t, &udpEchoTransport{})
	conn := dialAndAuth(t, addr, testPeer.Secret)
	defer conn.Close()
	var buf []byte
	conn.Write(relaywire.EncodeOpenFlow(1, 9, "10.0.0.9", 5000, false))
	if f := readFrame(t, conn, &buf); f.Type != relaywire.TypeOpenReply || !f.OK {
		t.Fatalf("open: %+v", f)
	}
	for _, fr := range relaywire.EncodeSendPayload(9, []byte("ping")) {
		conn.Write(fr)
	}
	if f := readFrame(t, conn, &buf); f.Type != relaywire.TypeDeliver || !bytes.Equal(f.Payload, []byte("ping")) {
		t.Fatalf("deliver: %+v", f)
	}
}

func TestUDPUnsupportedTransportRefusesFlow(t *testing.T) {
	_, addr := startTestServer(t, &fakeTransport{}) // DialUDP → ErrUnsupportedProtocol
	conn := dialAndAuth(t, addr, testPeer.Secret)
	defer conn.Close()
	var buf []byte
	conn.Write(relaywire.EncodeOpenFlow(1, 9, "10.0.0.9", 5000, false))
	f := readFrame(t, conn, &buf)
	if f.Type != relaywire.TypeOpenReply || f.OK || f.Err != transport.ErrUnsupportedProtocol.Error() {
		t.Fatalf("want unsupported refusal, got %+v", f)
	}
}

func fakeDNSResponse(t *testing.T, query []byte, addr [4]byte) []byte {
	t.Helper()
	var parser dnsmessage.Parser
	hdr, err := parser.Start(query)
	if err != nil {
		t.Fatal(err)
	}
	q, err := parser.Question()
	if err != nil {
		t.Fatal(err)
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: hdr.ID, Response: true})
	b.EnableCompression()
	b.StartQuestions()
	b.Question(q)
	b.StartAnswers()
	b.AResource(dnsmessage.ResourceHeader{Name: q.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60},
		dnsmessage.AResource{A: addr})
	out, err := b.Finish()
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func startTestServerWithResolve(t *testing.T, tr transport.Transport,
	resolve func(context.Context, []byte) ([]byte, error)) (*Server, string) {
	t.Helper()
	cert, err := GenerateCert()
	if err != nil {
		t.Fatal(err)
	}
	srv := NewServer(Config{Port: 0, Peers: []Peer{testPeer}, Resolve: resolve}, tr, cert)
	if err := srv.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)
	return srv, srv.Addr()
}

func TestDNSFlowAnswersViaResolve(t *testing.T) {
	var captured []byte
	resolve := func(_ context.Context, q []byte) ([]byte, error) {
		captured = q
		return fakeDNSResponse(t, q, [4]byte{1, 2, 3, 4}), nil
	}
	_, addr := startTestServerWithResolve(t, &fakeTransport{}, resolve)
	conn := dialAndAuth(t, addr, testPeer.Secret)
	defer conn.Close()
	var buf []byte
	conn.Write(relaywire.EncodeOpenFlow(1, 3, "8.8.8.8", 53, false)) // UDP port 53 → DNS flow
	if f := readFrame(t, conn, &buf); f.Type != relaywire.TypeOpenReply || !f.OK {
		t.Fatalf("open: %+v", f)
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: 7, RecursionDesired: true})
	b.StartQuestions()
	b.Question(dnsmessage.Question{Name: dnsmessage.MustNewName("example.com."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET})
	query, _ := b.Finish()
	for _, fr := range relaywire.EncodeSendPayload(3, query) {
		conn.Write(fr)
	}
	f := readFrame(t, conn, &buf)
	if f.Type != relaywire.TypeDeliver || captured == nil {
		t.Fatalf("deliver: %+v", f)
	}
	var parser dnsmessage.Parser
	if hdr, err := parser.Start(f.Payload); err != nil || hdr.ID != 7 || !hdr.Response {
		t.Fatalf("bad DNS response: %v", err)
	}
}

func TestHostnameOpenResolvesViaResolve(t *testing.T) {
	resolve := func(_ context.Context, q []byte) ([]byte, error) {
		return fakeDNSResponse(t, q, [4]byte{10, 1, 2, 3}), nil
	}
	_, addr := startTestServerWithResolve(t, &fakeTransport{}, resolve)
	conn := dialAndAuth(t, addr, testPeer.Secret)
	defer conn.Close()
	var buf []byte
	conn.Write(relaywire.EncodeOpenFlow(1, 5, "example.com", 80, true))
	if f := readFrame(t, conn, &buf); f.Type != relaywire.TypeOpenReply || !f.OK {
		t.Fatalf("hostname open failed: %+v", f)
	}
}

func TestHostnameOpenWithoutResolverFails(t *testing.T) {
	_, addr := startTestServer(t, &fakeTransport{}) // no Resolve configured
	conn := dialAndAuth(t, addr, testPeer.Secret)
	defer conn.Close()
	var buf []byte
	conn.Write(relaywire.EncodeOpenFlow(1, 5, "example.com", 80, true))
	if f := readFrame(t, conn, &buf); f.OK {
		t.Fatalf("want refusal, got %+v", f)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android/core && go get golang.org/x/net/dns/dnsmessage && go test ./share/`
Expected: FAIL (UDP flows refused by the Task 5 stub; hostname resolution errors).

- [ ] **Step 3: Implement `udp.go` (and delete the two stubs from `server.go`)**

```go
package share

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"time"

	"golang.org/x/net/dns/dnsmessage"
	"tunnelbahn/core/relaywire"
)

// openUDPFlow serves a UDP flow from the Mac. Port 53 (any destination) becomes a
// DNS flow answered through cfg.Resolve — the existing DNS-over-TCP path — which is
// what keeps Mac name resolution working when the phone runs the TCP-only SSH
// transport. Everything else goes to tr.DialUDP (wgws serves it; ssh refuses).
func (c *client) openUDPFlow(ctx context.Context, f *relaywire.Frame) {
	if f.Port == 53 {
		if c.srv.cfg.Resolve == nil {
			c.send(relaywire.EncodeOpenReply(f.ReqID, false, "no tunnel resolver configured"))
			return
		}
		c.registerFlow(f.FlowID, &flow{
			write: func(query []byte) error {
				q := append([]byte(nil), query...)
				go func() {
					rctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
					defer cancel()
					resp, err := c.srv.cfg.Resolve(rctx, q)
					if err != nil {
						c.srv.cfg.Logf("share: dns flow %d: %v", f.FlowID, err)
						return // DNS clients retry; don't kill the flow
					}
					c.sendAll(relaywire.EncodeDeliver(f.FlowID, resp))
				}()
				return nil
			},
			close: func() {},
		})
		c.send(relaywire.EncodeOpenReply(f.ReqID, true, ""))
		return
	}

	dst, err := c.resolveDst(ctx, f.Host, f.Port)
	if err != nil {
		c.send(relaywire.EncodeOpenReply(f.ReqID, false, err.Error()))
		return
	}
	pc, err := c.srv.tr.DialUDP(ctx, dst)
	if err != nil {
		c.send(relaywire.EncodeOpenReply(f.ReqID, false, err.Error()))
		return
	}
	udpDst := net.UDPAddrFromAddrPort(dst)
	c.registerFlow(f.FlowID, &flow{
		write: func(p []byte) error {
			// gonet's connected endpoints reject per-write addresses (see
			// engine.go singleDstPacketConn) — prefer Write when available.
			if w, ok := pc.(interface{ Write([]byte) (int, error) }); ok {
				_, err := w.Write(p)
				return err
			}
			_, err := pc.WriteTo(p, udpDst)
			return err
		},
		close: func() { pc.Close() },
	})
	c.send(relaywire.EncodeOpenReply(f.ReqID, true, ""))
	go func() {
		buf := make([]byte, 65535)
		for {
			n, _, err := pc.ReadFrom(buf)
			if n > 0 {
				c.sendAll(relaywire.EncodeDeliver(f.FlowID, buf[:n]))
			}
			if err != nil {
				c.flowMu.Lock()
				_, live := c.flows[f.FlowID]
				delete(c.flows, f.FlowID)
				c.flowMu.Unlock()
				if live {
					c.send(relaywire.EncodeFlowClosed(f.FlowID, ""))
				}
				pc.Close()
				return
			}
		}
	}()
}

// resolveHostname answers an A query through the tunnel resolver. v1 is
// IPv4-only, matching the phone's IPv4-only tun.
func (c *client) resolveHostname(ctx context.Context, host string, port uint16) (netip.AddrPort, error) {
	if c.srv.cfg.Resolve == nil {
		return netip.AddrPort{}, fmt.Errorf("share: cannot resolve %q: no tunnel resolver", host)
	}
	name, err := dnsmessage.NewName(host + ".")
	if err != nil {
		return netip.AddrPort{}, fmt.Errorf("share: bad hostname %q", host)
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: uint16(time.Now().UnixNano()), RecursionDesired: true})
	b.StartQuestions()
	if err := b.Question(dnsmessage.Question{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}); err != nil {
		return netip.AddrPort{}, err
	}
	query, err := b.Finish()
	if err != nil {
		return netip.AddrPort{}, err
	}
	resp, err := c.srv.cfg.Resolve(ctx, query)
	if err != nil {
		return netip.AddrPort{}, fmt.Errorf("share: resolve %q: %w", host, err)
	}
	var parser dnsmessage.Parser
	if _, err := parser.Start(resp); err != nil {
		return netip.AddrPort{}, err
	}
	if err := parser.SkipAllQuestions(); err != nil {
		return netip.AddrPort{}, err
	}
	for {
		h, err := parser.AnswerHeader()
		if err != nil {
			return netip.AddrPort{}, fmt.Errorf("share: no A record for %q", host)
		}
		if h.Type == dnsmessage.TypeA {
			r, err := parser.AResource()
			if err != nil {
				return netip.AddrPort{}, err
			}
			return netip.AddrPortFrom(netip.AddrFrom4(r.A), port), nil
		}
		if err := parser.SkipAnswer(); err != nil {
			return netip.AddrPort{}, err
		}
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd android/core && go test ./share/ -race`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android/core/share/ android/core/go.mod android/core/go.sum
git commit -m "feat(share): UDP flows, tunnel-DNS flows, and hostname resolution"
```

---

### Task 7: Go session integration + gomobile exports + rebuild .aar

**Files:**
- Modify: `android/core/session.go` (store resolver/protector; StartShare/StopShare/ShareClientCount; StopShare inside Stop)
- Modify: `android/core/mobile/mobile.go` (re-declare the three methods)
- Test: `android/core/session_share_test.go`

**Interfaces:**
- Consumes: Tasks 5–6 (`share.NewServer`, `share.ParseConfig`, `share.GenerateCert`), existing `ResolveOverTCP` (`dns.go:18`), `protectedControl` (`engine.go:103`), `Session` internals (`session.go`).
- Produces (used by Task 9's Kotlin):
  - core: `func (s *Session) StartShare(configJSON string) error` (error if session not running or share already active), `func (s *Session) StopShare()` (idempotent), `func (s *Session) ShareClientCount() int`
  - mobile (`android/core/mobile/mobile.go`): identical three signatures delegating to core; Kotlin sees `session.startShare(json)`, `session.stopShare()`, `session.shareClientCount()`.

- [ ] **Step 1: Write the failing test**

```go
package core

import (
	"strings"
	"testing"
)

func TestStartShareRequiresRunningSession(t *testing.T) {
	s := NewSession()
	err := s.StartShare(`{"port":0,"peers":[]}`)
	if err == nil || !strings.Contains(err.Error(), "not running") {
		t.Fatalf("want not-running error, got %v", err)
	}
}

func TestStopShareIsIdempotentWithoutStart(t *testing.T) {
	s := NewSession()
	s.StopShare()
	s.StopShare()
	if n := s.ShareClientCount(); n != 0 {
		t.Fatalf("client count: %d", n)
	}
}
```

(The full listener path is covered by the `share` package tests; here we pin the lifecycle guards. `session.go` fields are unexported, so the test lives in package `core`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android/core && go test -run 'TestStartShare|TestStopShare' ./...`
Expected: FAIL (methods undefined).

- [ ] **Step 3: Implement in `session.go`**

Add fields to `Session` (next to `tr`/`eng`): `prot Protector`, `resolver netip.AddrPort`, `shareSrv *share.Server`. In `Start`, after config parse and transport construction, store `s.prot = prot` and `s.resolver = <the same netip.AddrPort handed to newCoreProxy>`. In `Stop`, call `s.StopShare()` before tearing down the transport. Then:

```go
// StartShare exposes the live tunnel to paired LAN devices (spec:
// docs/superpowers/specs/2026-08-30-tunnel-share-design.md). It reuses the
// session's transport the same way RunTunnelSpeedTest does — never the engine.
func (s *Session) StartShare(configJSON string) error {
	s.mu.Lock()
	tr := s.tr
	prot := s.prot
	resolver := s.resolver
	if s.shareSrv != nil {
		s.mu.Unlock()
		return errors.New("share: already active")
	}
	s.mu.Unlock()
	if tr == nil {
		return errors.New("share: session not running")
	}
	port, peers, err := share.ParseConfig(configJSON)
	if err != nil {
		return err
	}
	cert, err := share.GenerateCert()
	if err != nil {
		return err
	}
	var control func(network, address string, c syscall.RawConn) error
	if prot != nil {
		control = protectedControl(prot)
	}
	srv := share.NewServer(share.Config{
		Port:  port,
		Peers: peers,
		Resolve: func(ctx context.Context, query []byte) ([]byte, error) {
			return ResolveOverTCP(ctx, tr, resolver, query)
		},
		Control: control,
		Logf:    log.Printf,
	}, tr, cert)
	if err := srv.Start(); err != nil {
		return err
	}
	s.mu.Lock()
	s.shareSrv = srv
	s.mu.Unlock()
	return nil
}

func (s *Session) StopShare() {
	s.mu.Lock()
	srv := s.shareSrv
	s.shareSrv = nil
	s.mu.Unlock()
	if srv != nil {
		srv.Close()
	}
}

func (s *Session) ShareClientCount() int {
	s.mu.Lock()
	srv := s.shareSrv
	s.mu.Unlock()
	if srv == nil {
		return 0
	}
	return srv.ClientCount()
}
```

(Adjust the mutex name to whatever `Session` actually uses; if `Start` doesn't currently keep the resolver `netip.AddrPort` around, capture it where `newCoreProxy` receives it.)

- [ ] **Step 4: Add the mobile bindings in `android/core/mobile/mobile.go`**

```go
// StartShare exposes the live tunnel to paired LAN devices. configJSON:
// {"port":47600,"peers":[{"id":"<hex16B>","secret":"<hex32B>","name":"..."}]}
func (s *Session) StartShare(configJSON string) error { return s.inner.StartShare(configJSON) }

// StopShare closes the share listener and all relayed flows. Idempotent.
func (s *Session) StopShare() { s.inner.StopShare() }

// ShareClientCount reports how many paired devices are currently connected.
func (s *Session) ShareClientCount() int { return s.inner.ShareClientCount() }
```

- [ ] **Step 5: Run all Go tests, rebuild the .aar**

Run: `cd android/core && go test ./... -race`
Expected: PASS.

Run: `cd android && ./build-core.sh`
Expected: `android/app/libs/libtunnelbahn.aar` regenerated without errors.

Check ProGuard: release builds minify — confirm `android/app/proguard-rules.pro` keeps `tunnelbahn.mobile.**`; if there is no keep rule covering it, add `-keep class tunnelbahn.mobile.** { *; }`.

- [ ] **Step 6: Commit**

```bash
git add android/core/session.go android/core/mobile/mobile.go android/core/session_share_test.go android/app/libs/
git commit -m "feat(share): session StartShare/StopShare and gomobile exports"
```

---

### Task 8: Android pairing payload parser + peer store

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/share/SharePairing.kt`
- Create: `android/app/src/main/java/tunnelbahn/app/share/SharePeerStore.kt`
- Test: `android/app/src/test/java/tunnelbahn/app/share/SharePairingTest.kt`
- Test: `android/app/src/test/java/tunnelbahn/app/share/SharePeerStoreTest.kt`

**Interfaces:**
- Consumes: the QR payload JSON from Task 4 (`kind=tunnelbahn.pair`); `ProfileStore.kt` as the EncryptedSharedPreferences model.
- Produces (used by Task 9):
  - `data class SharePeer(val idHex: String, val secretHex: String, val name: String, val port: Int, val addedAtMs: Long)`
  - `sealed interface PairParseResult { data class Ok(val peer: SharePeer) : PairParseResult; data class Error(val reason: String) : PairParseResult }`
  - `fun parsePairPayload(raw: String, nowMs: Long): PairParseResult` (validates kind/v/hex lengths/port range)
  - `class SharePeerStore(context: Context)` with `fun load(): List<SharePeer>`, `fun add(peer: SharePeer)` (replaces an existing entry with the same `idHex`), `fun remove(idHex: String)`, `fun shareEnabled(): Boolean`, `fun setShareEnabled(enabled: Boolean)`, and `fun coreConfigJson(): String` producing exactly the Task 7 `StartShare` shape.

- [ ] **Step 1: Write the failing tests**

`SharePairingTest.kt` (plain JUnit, model: `QRImportTest.kt`):

```kotlin
package tunnelbahn.app.share

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SharePairingTest {
    private val valid = """{"kind":"tunnelbahn.pair","v":1,""" +
        """"id":"0102030405060708090a0b0c0d0e0f10",""" +
        """"secret":"${"ab".repeat(32)}","name":"My Mac","port":47600}"""

    @Test fun parsesValidPayload() {
        val r = parsePairPayload(valid, nowMs = 123L)
        assertTrue(r is PairParseResult.Ok)
        val p = (r as PairParseResult.Ok).peer
        assertEquals("0102030405060708090a0b0c0d0e0f10", p.idHex)
        assertEquals("My Mac", p.name)
        assertEquals(47600, p.port)
        assertEquals(123L, p.addedAtMs)
    }

    @Test fun rejectsWrongKind() {
        assertTrue(parsePairPayload(valid.replace("tunnelbahn.pair", "tunnelbahn.profile"), 0) is PairParseResult.Error)
    }

    @Test fun rejectsShortSecret() {
        assertTrue(parsePairPayload(valid.replace("ab".repeat(32), "ab".repeat(31)), 0) is PairParseResult.Error)
    }

    @Test fun rejectsNonJson() {
        assertTrue(parsePairPayload("nope", 0) is PairParseResult.Error)
    }
}
```

`SharePeerStoreTest.kt` (Robolectric, model: `ProfileStoreTest.kt` — mirror its setup):

```kotlin
package tunnelbahn.app.share

import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SharePeerStoreTest {
    private fun store() = SharePeerStore(ApplicationProvider.getApplicationContext())
    private fun peer(id: String) = SharePeer(id, "ab".repeat(32), "Mac", 47600, 1L)

    @Test fun addLoadRemoveRoundTrip() {
        val s = store()
        s.add(peer("aa".repeat(16)))
        s.add(peer("bb".repeat(16)))
        assertEquals(2, s.load().size)
        s.remove("aa".repeat(16))
        assertEquals(listOf("bb".repeat(16)), s.load().map { it.idHex })
    }

    @Test fun addReplacesSameId() {
        val s = store()
        s.add(peer("aa".repeat(16)))
        s.add(peer("aa".repeat(16)).copy(name = "Renamed"))
        assertEquals(listOf("Renamed"), s.load().map { it.name })
    }

    @Test fun enabledFlagPersists() {
        val s = store()
        assertFalse(s.shareEnabled())
        s.setShareEnabled(true)
        assertTrue(store().shareEnabled())
    }

    @Test fun coreConfigJsonShape() {
        val s = store()
        s.add(peer("aa".repeat(16)))
        val json = s.coreConfigJson()
        assertTrue(json.contains("\"port\":47600"))
        assertTrue(json.contains("\"id\":\"${"aa".repeat(16)}\""))
        assertTrue(json.contains("\"secret\":\"${"ab".repeat(32)}\""))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests "tunnelbahn.app.share.*"`
Expected: FAIL (classes don't exist).

- [ ] **Step 3: Implement `SharePairing.kt`**

```kotlin
package tunnelbahn.app.share

import org.json.JSONObject

data class SharePeer(
    val idHex: String,
    val secretHex: String,
    val name: String,
    val port: Int,
    val addedAtMs: Long,
)

sealed interface PairParseResult {
    data class Ok(val peer: SharePeer) : PairParseResult
    data class Error(val reason: String) : PairParseResult
}

private val hexRe = Regex("^[0-9a-fA-F]+$")

/** Parses the desktop pairing QR (Shared/PhoneRelayPairing.swift renders it). */
fun parsePairPayload(raw: String, nowMs: Long): PairParseResult {
    val o = try {
        JSONObject(raw)
    } catch (_: Exception) {
        return PairParseResult.Error("Not a TunnelBahn pairing code.")
    }
    if (o.optString("kind") != "tunnelbahn.pair") return PairParseResult.Error("Not a TunnelBahn pairing code.")
    if (o.optInt("v") != 1) return PairParseResult.Error("Unsupported pairing version.")
    val id = o.optString("id")
    val secret = o.optString("secret")
    val port = o.optInt("port", 47600)
    if (id.length != 32 || !hexRe.matches(id)) return PairParseResult.Error("Malformed pairing id.")
    if (secret.length != 64 || !hexRe.matches(secret)) return PairParseResult.Error("Malformed pairing secret.")
    if (port !in 1..65535) return PairParseResult.Error("Bad port.")
    val name = o.optString("name").ifBlank { "Paired device" }
    return PairParseResult.Ok(SharePeer(id.lowercase(), secret.lowercase(), name, port, nowMs))
}
```

- [ ] **Step 4: Implement `SharePeerStore.kt`**

Mirror `ProfileStore.kt`'s EncryptedSharedPreferences construction (same MasterKey pattern), file name `"share_peers"`, one JSON array under key `"peers"`, boolean under `"enabled"`:

```kotlin
package tunnelbahn.app.share

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import org.json.JSONObject

/** Paired desktop devices allowed to ride the tunnel. Secrets at rest are encrypted
 *  under a Keystore-wrapped AES key, same posture as ProfileStore. */
class SharePeerStore(context: Context) {
    private val prefs: SharedPreferences = run {
        val key = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        EncryptedSharedPreferences.create(
            context, "share_peers", key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun load(): List<SharePeer> {
        val arr = JSONArray(prefs.getString("peers", "[]") ?: "[]")
        return (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            SharePeer(o.getString("id"), o.getString("secret"), o.getString("name"),
                o.optInt("port", 47600), o.optLong("addedAtMs"))
        }
    }

    fun add(peer: SharePeer) = save(load().filter { it.idHex != peer.idHex } + peer)

    fun remove(idHex: String) = save(load().filter { it.idHex != idHex })

    fun shareEnabled(): Boolean = prefs.getBoolean("enabled", false)

    fun setShareEnabled(enabled: Boolean) = prefs.edit().putBoolean("enabled", enabled).apply()

    /** Exactly the shape core's share.ParseConfig expects. */
    fun coreConfigJson(): String {
        val peers = JSONArray()
        for (p in load()) {
            peers.put(JSONObject().put("id", p.idHex).put("secret", p.secretHex).put("name", p.name))
        }
        return JSONObject().put("port", 47600).put("peers", peers).toString()
    }

    private fun save(peers: List<SharePeer>) {
        val arr = JSONArray()
        for (p in peers) {
            arr.put(JSONObject().put("id", p.idHex).put("secret", p.secretHex)
                .put("name", p.name).put("port", p.port).put("addedAtMs", p.addedAtMs))
        }
        prefs.edit().putString("peers", arr.toString()).apply()
    }
}
```

(If `ProfileStore.kt` uses a different EncryptedSharedPreferences recipe or a Robolectric-friendly fallback, copy its exact pattern — the tests must pass under Robolectric the same way `ProfileStoreTest` does.)

- [ ] **Step 5: Run tests to verify they pass, commit**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests "tunnelbahn.app.share.*"`
Expected: PASS.

```bash
git add android/app/src/main/java/tunnelbahn/app/share/ android/app/src/test/java/tunnelbahn/app/share/
git commit -m "feat(share): Android pairing parser and encrypted peer store"
```

---

### Task 9: Android sharing UI + VPN service wiring

**Files:**
- Create: `android/app/src/main/java/tunnelbahn/app/ui/ShareScreen.kt`
- Create: `android/app/src/main/java/tunnelbahn/app/ui/QrPairScan.kt`
- Create: `android/app/src/main/java/tunnelbahn/app/share/ShareController.kt`
- Modify: `android/app/src/main/java/tunnelbahn/app/ui/AppRoot.kt` (add `Screen.Share`)
- Modify: `android/app/src/main/java/tunnelbahn/app/ui/HomeScreen.kt` (entry point: "Tunnel Sharing" row/button, add `onShare: () -> Unit` parameter)
- Modify: `android/app/src/main/java/tunnelbahn/app/vpn/TunnelBahnVpnService.kt` (start share on running state when enabled)

**Interfaces:**
- Consumes: Task 8 (`SharePeerStore`, `parsePairPayload`), Task 7 (`session.startShare/stopShare/shareClientCount`), existing `TunnelBahnVpnService.activeSession` (`TunnelBahnVpnService.kt:419`), ZXing scan pattern (`ui/QrImport.kt`).
- Produces:
  - `object ShareController { fun syncWithSession(context: Context); fun clientCount(): Int }`
  - `@Composable fun ShareScreen(onBack: () -> Unit)`
  - `@Composable fun rememberQrPairScan(onPaired: (SharePeer) -> Unit, onError: (String) -> Unit): () -> Unit`

- [ ] **Step 1: Implement `QrPairScan.kt`** (clone of `rememberQrImport` with the pairing parser)

```kotlin
package tunnelbahn.app.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts.RequestPermission
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import tunnelbahn.app.share.PairParseResult
import tunnelbahn.app.share.SharePeer
import tunnelbahn.app.share.parsePairPayload

@Composable
fun rememberQrPairScan(
    onPaired: (SharePeer) -> Unit,
    onError: (String) -> Unit,
): () -> Unit {
    val scan = rememberLauncherForActivityResult(ScanContract()) { result ->
        val contents = result.contents ?: return@rememberLauncherForActivityResult
        when (val r = parsePairPayload(contents, System.currentTimeMillis())) {
            is PairParseResult.Ok -> onPaired(r.peer)
            is PairParseResult.Error -> onError(r.reason)
        }
    }
    val options = remember {
        ScanOptions()
            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            .setBeepEnabled(false)
            .setOrientationLocked(false)
            .setPrompt("Scan the pairing QR shown on the Mac")
    }
    val permission = rememberLauncherForActivityResult(RequestPermission()) { granted ->
        if (granted) scan.launch(options) else onError("Camera permission is needed to scan.")
    }
    return { permission.launch(Manifest.permission.CAMERA) }
}
```

- [ ] **Step 2: Implement `ShareController.kt` + service wiring**

```kotlin
package tunnelbahn.app.share

import android.content.Context
import tunnelbahn.app.vpn.TunnelBahnVpnService

/** Reconciles the persisted sharing toggle with the live Go session. Safe to call
 *  from any thread; every entry point that changes session state or share config
 *  funnels through here. */
object ShareController {
    fun syncWithSession(context: Context) {
        val session = TunnelBahnVpnService.activeSession ?: return
        val store = SharePeerStore(context)
        if (store.shareEnabled() && store.load().isNotEmpty()) {
            try {
                session.startShare(store.coreConfigJson())
            } catch (e: Exception) {
                if (e.message?.contains("already active") != true) {
                    android.util.Log.w("ShareController", "startShare failed: ${e.message}")
                }
            }
        } else {
            session.stopShare()
        }
    }

    fun clientCount(): Int = try {
        TunnelBahnVpnService.activeSession?.shareClientCount()?.toInt() ?: 0
    } catch (_: Exception) { 0 }
}
```

In `TunnelBahnVpnService.Sink.onState` (the existing state mapper around `TunnelBahnVpnService.kt:271`), after the state flow is updated: when the mapped state is the running/connected state, call `ShareController.syncWithSession(this@TunnelBahnVpnService)`. (Restarting share on every `running` transition is what re-arms sharing after a session restart — the listener died with the old session.) Note the gomobile int convention: if `shareClientCount()` surfaces as `Long` in Kotlin, adapt the cast (same convention as `protect(fd: Long)`).

- [ ] **Step 3: Implement `ShareScreen.kt`**

Follow the visual conventions of the sibling screens (`CidrRulesScreen.kt` is the closest structural model — Scaffold, top bar with back arrow, list + actions):

```kotlin
package tunnelbahn.app.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import tunnelbahn.app.share.ShareController
import tunnelbahn.app.share.SharePeerStore
import tunnelbahn.app.vpn.TunnelBahnVpnService

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShareScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val store = remember { SharePeerStore(context) }
    var peers by remember { mutableStateOf(store.load()) }
    var enabled by remember { mutableStateOf(store.shareEnabled()) }
    var clientCount by remember { mutableStateOf(0) }
    var error by remember { mutableStateOf<String?>(null) }
    val vpnState by TunnelBahnVpnService.state.collectAsState()

    LaunchedEffect(enabled) {
        while (enabled) {
            clientCount = ShareController.clientCount()
            delay(2000)
        }
        clientCount = 0
    }

    val scanPair = rememberQrPairScan(
        onPaired = { peer ->
            store.add(peer)
            peers = store.load()
            ShareController.syncWithSession(context)
        },
        onError = { error = it },
    )

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Tunnel Sharing") },
            navigationIcon = {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            },
        )
    }) { pad ->
        Column(Modifier.padding(pad).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Share tunnel with paired devices", style = MaterialTheme.typography.bodyLarge)
                    Text(
                        when {
                            !enabled -> "Off"
                            vpnState != "running" -> "Waiting for tunnel connection"
                            clientCount == 0 -> "On — no device connected"
                            else -> "On — $clientCount device(s) connected"
                        },
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                Switch(checked = enabled, onCheckedChange = {
                    enabled = it
                    store.setShareEnabled(it)
                    ShareController.syncWithSession(context)
                })
            }
            Button(onClick = scanPair) { Text("Pair a device (scan QR)") }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            HorizontalDivider()
            Text("Paired devices", style = MaterialTheme.typography.titleSmall)
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(peers, key = { it.idHex }) { peer ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(peer.name, Modifier.weight(1f))
                        IconButton(onClick = {
                            store.remove(peer.idHex)
                            peers = store.load()
                            ShareController.syncWithSession(context)
                        }) { Icon(Icons.Filled.Delete, "Remove") }
                    }
                }
            }
        }
    }
}
```

(Adapt `TunnelBahnVpnService.state` collection and the `"running"` comparison to the actual state type — check the companion at `TunnelBahnVpnService.kt:381-420`; if it's an enum/StateFlow of a sealed type, compare accordingly.)

- [ ] **Step 4: Wire navigation**

In `AppRoot.kt`: add `data object Share : Screen` to the sealed interface, a `is Screen.Share -> ShareScreen(onBack = { screen = Screen.Home })` branch, and pass `onShare = { screen = Screen.Share }` into `HomeScreen`. In `HomeScreen.kt`: add the `onShare: () -> Unit` parameter and a row/button "Tunnel Sharing" alongside the existing Profiles/Speed Test entries (copy the exact composable style of the neighboring entries).

- [ ] **Step 5: Build, run unit tests, commit**

Run: `cd android && ./gradlew :app:assembleDebug :app:testDebugUnitTest`
Expected: BUILD SUCCESSFUL, all tests pass.

```bash
git add android/app/src/main/java/tunnelbahn/app/
git commit -m "feat(share): Android sharing screen, QR pairing, and session wiring"
```

---

### Task 10: Swift `DefaultGatewayResolver`

**Files:**
- Create: `Shared/DefaultGatewayResolver.swift`
- Test: `Tests/Unit/DefaultGatewayResolverTests.swift`
- Modify: `project.yml` (file into app target + `TunnelBahnUnitTests` sources)

**Interfaces:**
- Consumes: Darwin `sysctl` (`CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY`).
- Produces (used by Task 11): `enum DefaultGatewayResolver` with `static func defaultIPv4Gateway() -> String?` (live sysctl) and the pure, testable `static func parseRouteDump(_ data: Data) -> String?`.

- [ ] **Step 1: Write the failing test**

The test builds a synthetic `rt_msghdr2` dump containing one default route (dst `0.0.0.0`, gateway `192.168.43.1`) so the parser is pinned without depending on the machine's routing table:

```swift
import XCTest
@testable import TunnelBahn

final class DefaultGatewayResolverTests: XCTestCase {
    /// Builds one NET_RT_FLAGS route message: rt_msghdr2 + sockaddr_in(dst) + sockaddr_in(gateway).
    private func routeMessage(dst: (UInt8, UInt8, UInt8, UInt8), gw: (UInt8, UInt8, UInt8, UInt8)) -> Data {
        var hdr = rt_msghdr2()
        let hdrLen = MemoryLayout<rt_msghdr2>.size
        var sinDst = sockaddr_in()
        sinDst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sinDst.sin_family = sa_family_t(AF_INET)
        sinDst.sin_addr.s_addr = UInt32(dst.0) | UInt32(dst.1) << 8 | UInt32(dst.2) << 16 | UInt32(dst.3) << 24
        var sinGw = sockaddr_in()
        sinGw.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sinGw.sin_family = sa_family_t(AF_INET)
        sinGw.sin_addr.s_addr = UInt32(gw.0) | UInt32(gw.1) << 8 | UInt32(gw.2) << 16 | UInt32(gw.3) << 24
        let saLen = MemoryLayout<sockaddr_in>.size
        hdr.rtm_msglen = u_short(hdrLen + 2 * saLen)
        hdr.rtm_version = u_char(RTM_VERSION)
        hdr.rtm_type = u_char(RTM_GET)
        hdr.rtm_flags = RTF_UP | RTF_GATEWAY
        hdr.rtm_addrs = RTA_DST | RTA_GATEWAY
        var data = withUnsafeBytes(of: &hdr) { Data($0) }
        withUnsafeBytes(of: &sinDst) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &sinGw) { data.append(contentsOf: $0) }
        return data
    }

    func testParsesDefaultRouteGateway() {
        let dump = routeMessage(dst: (0, 0, 0, 0), gw: (192, 168, 43, 1))
        XCTAssertEqual(DefaultGatewayResolver.parseRouteDump(dump), "192.168.43.1")
    }

    func testIgnoresNonDefaultRoutes() {
        let dump = routeMessage(dst: (10, 0, 0, 0), gw: (10, 0, 0, 1))
        XCTAssertNil(DefaultGatewayResolver.parseRouteDump(dump))
    }

    func testSkipsFirstMessageAndFindsDefaultInSecond() {
        var dump = routeMessage(dst: (10, 0, 0, 0), gw: (10, 0, 0, 1))
        dump.append(routeMessage(dst: (0, 0, 0, 0), gw: (172, 20, 10, 1)))
        XCTAssertEqual(DefaultGatewayResolver.parseRouteDump(dump), "172.20.10.1")
    }

    func testEmptyAndTruncatedInput() {
        XCTAssertNil(DefaultGatewayResolver.parseRouteDump(Data()))
        XCTAssertNil(DefaultGatewayResolver.parseRouteDump(Data([0x01, 0x02])))
    }

    func testLiveLookupDoesNotCrash() {
        // Environment-dependent: just require nil or a dotted quad.
        if let gw = DefaultGatewayResolver.defaultIPv4Gateway() {
            XCTAssertEqual(gw.split(separator: ".").count, 4)
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' test -only-testing:TunnelBahnUnitTests/DefaultGatewayResolverTests`
Expected: FAIL / compile error.

- [ ] **Step 3: Implement**

```swift
import Darwin
import Foundation

/// Resolves the default IPv4 gateway via the PF_ROUTE sysctl. On a phone
/// hotspot / USB / Ethernet tether the gateway IS the phone, which makes it the
/// phone-relay endpoint without any discovery protocol (spec:
/// docs/superpowers/specs/2026-08-30-tunnel-share-design.md).
public enum DefaultGatewayResolver {
    public static func defaultIPv4Gateway() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var needed = 0
        guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, u_int(mib.count), &buf, &needed, nil, 0) == 0 else { return nil }
        return parseRouteDump(Data(buf.prefix(needed)))
    }

    /// Walks rt_msghdr2 records looking for a route whose RTA_DST sockaddr is
    /// 0.0.0.0 and returns its RTA_GATEWAY address. Pure for testability.
    public static func parseRouteDump(_ data: Data) -> String? {
        let hdrSize = MemoryLayout<rt_msghdr2>.size
        var offset = 0
        while offset + hdrSize <= data.count {
            let hdr: rt_msghdr2 = data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr2.self)
            }
            let msgLen = Int(hdr.rtm_msglen)
            guard msgLen >= hdrSize, offset + msgLen <= data.count else { return nil }
            if hdr.rtm_addrs & RTA_DST != 0, hdr.rtm_addrs & RTA_GATEWAY != 0 {
                var saOffset = offset + hdrSize
                var dst: in_addr?
                var gateway: in_addr?
                for bit in [RTA_DST, RTA_GATEWAY, RTA_NETMASK, RTA_GENMASK, RTA_IFP, RTA_IFA, RTA_AUTHOR, RTA_BRD] {
                    guard hdr.rtm_addrs & bit != 0 else { continue }
                    guard saOffset + 2 <= offset + msgLen else { break }
                    let saLen = Int(data[saOffset])
                    let family = data[saOffset + 1]
                    if family == UInt8(AF_INET), saLen >= MemoryLayout<sockaddr_in>.size,
                       saOffset + MemoryLayout<sockaddr_in>.size <= data.count {
                        let sin: sockaddr_in = data.withUnsafeBytes { raw in
                            raw.loadUnaligned(fromByteOffset: saOffset, as: sockaddr_in.self)
                        }
                        if bit == RTA_DST { dst = sin.sin_addr }
                        if bit == RTA_GATEWAY { gateway = sin.sin_addr }
                    }
                    // sockaddrs are padded to 4-byte boundaries; sa_len 0 means 4 bytes.
                    saOffset += saLen == 0 ? 4 : (saLen + 3) & ~3
                }
                if let d = dst, d.s_addr == 0, let gw = gateway {
                    var addr = gw
                    var strBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr, &strBuf, socklen_t(INET_ADDRSTRLEN))
                    return String(cString: strBuf)
                }
            }
            offset += msgLen
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify it passes, commit**

Run: same xcodebuild command.
Expected: PASS.

```bash
git add Shared/DefaultGatewayResolver.swift Tests/Unit/DefaultGatewayResolverTests.swift project.yml
git commit -m "feat(share): default-gateway resolver for phone-relay endpoint discovery"
```

---

### Task 11: Mac profile model + runtime plumbing

**Files:**
- Create: `TunnelBahn/Models/PhoneRelayProfile.swift`
- Modify: `TunnelBahn/Models/SSHProfile.swift` (add `TransportKind.phoneRelay` — the enum lives at `SSHProfile.swift:6`)
- Modify: `TunnelBahn/Models/WireGuardProfile.swift` (optional `phoneRelay` field, back-compat decode like `tcpWrapper` at `WireGuardTCPWrapper.init(from:)`)
- Modify: `Shared/TunnelRuntimeState.swift` (add `TunnelPhoneRelayParams` + field)
- Modify: `TunnelBahn/Services/VPNManager.swift` (`makeRuntimeStateData` ~:1411 populates the params; secret read from Keychain app-side; host = manual override or `DefaultGatewayResolver.defaultIPv4Gateway()`)
- Test: `Tests/Unit/PhoneRelayProfileTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: Task 4 (`PhoneRelayPairing`), Task 10 (`DefaultGatewayResolver`), existing `KeychainService`, `TransportKind`, `WireGuardProfile`, `TunnelRuntimeState`, `VPNManager.makeRuntimeStateData`.
- Produces (used by Tasks 12–13):
  - `struct PhoneRelayProfile: Codable, Equatable { var port: Int; var manualHost: String; var peerIDHex: String; var secretRef: String; var deviceName: String }` (`secretRef` is a Keychain reference, mirroring `ssh.privateKeyRef`)
  - `TransportKind.phoneRelay` (raw value `"phoneRelay"`)
  - `struct TunnelPhoneRelayParams: Codable { var host: String; var port: UInt16; var peerIDHex: String; var secretHex: String }` and `TunnelRuntimeState.phoneRelay: TunnelPhoneRelayParams?`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TunnelBahn

final class PhoneRelayProfileTests: XCTestCase {
    func testTransportKindRawValue() {
        XCTAssertEqual(TransportKind.phoneRelay.rawValue, "phoneRelay")
    }

    func testProfileWithoutPhoneRelayFieldStillDecodes() throws {
        // Back-compat: profiles saved before this feature have no phoneRelay key.
        let json = try JSONEncoder().encode(WireGuardProfile.makeDefault(name: "old"))
        var dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        dict.removeValue(forKey: "phoneRelay")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(WireGuardProfile.self, from: stripped)
        XCTAssertNil(decoded.phoneRelay)
    }

    func testPhoneRelayRoundTrip() throws {
        var profile = WireGuardProfile.makeDefault(name: "relay")
        profile.transport = .phoneRelay
        profile.phoneRelay = PhoneRelayProfile(
            port: 47600, manualHost: "", peerIDHex: String(repeating: "ab", count: 16),
            secretRef: "phone-relay-secret-XYZ", deviceName: "Pixel")
        let decoded = try JSONDecoder().decode(WireGuardProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.phoneRelay, profile.phoneRelay)
        XCTAssertEqual(decoded.transport, .phoneRelay)
    }

    func testRuntimeParamsRoundTrip() throws {
        var state = TunnelRuntimeState.makeMinimalForTests()
        state.phoneRelay = TunnelPhoneRelayParams(
            host: "192.168.43.1", port: 47600,
            peerIDHex: String(repeating: "ab", count: 16),
            secretHex: String(repeating: "cd", count: 32))
        let decoded = try JSONDecoder().decode(TunnelRuntimeState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.phoneRelay?.host, "192.168.43.1")
    }
}
```

(If `WireGuardProfile.makeDefault` / `TunnelRuntimeState.makeMinimalForTests` don't exist under those names, use whatever factory the existing tests — e.g. `TCPWrapperConfigCodecTests` — use to build instances, and keep the assertions identical.)

- [ ] **Step 2: Run to verify it fails, then implement**

`PhoneRelayProfile.swift`:

```swift
import Foundation

/// Per-profile settings for the phone-relay transport. The pairing secret lives in
/// the Keychain under `secretRef`; only its reference is in the profile JSON,
/// matching the SSH key model.
public struct PhoneRelayProfile: Codable, Equatable {
    public var port: Int = 47600
    /// Empty = resolve the default gateway at connect time (the phone, when tethered).
    public var manualHost: String = ""
    public var peerIDHex: String = ""
    public var secretRef: String = ""
    public var deviceName: String = ""
}
```

`TransportKind` (in `SSHProfile.swift`): add `case phoneRelay = "phoneRelay"` (match the existing `.ssh` case style exactly).

`WireGuardProfile.swift`: add `public var phoneRelay: PhoneRelayProfile?` and, in the custom `init(from:)` (if one exists — mirror how `tcpWrapper` is decoded), `phoneRelay = try container.decodeIfPresent(PhoneRelayProfile.self, forKey: .phoneRelay)`.

`TunnelRuntimeState.swift`:

```swift
public struct TunnelPhoneRelayParams: Codable {
    public var host: String
    public var port: UInt16
    public var peerIDHex: String
    public var secretHex: String

    public init(host: String, port: UInt16, peerIDHex: String, secretHex: String) {
        self.host = host
        self.port = port
        self.peerIDHex = peerIDHex
        self.secretHex = secretHex
    }
}
```

plus `public var phoneRelay: TunnelPhoneRelayParams?` on `TunnelRuntimeState` (decode with `decodeIfPresent`).

`VPNManager.makeRuntimeStateData` (~:1411): in the transport branching where `ssh` params are populated, add the `.phoneRelay` branch:

```swift
if profile.transport == .phoneRelay, let relay = profile.phoneRelay {
    let host = relay.manualHost.isEmpty
        ? (DefaultGatewayResolver.defaultIPv4Gateway() ?? "")
        : relay.manualHost
    let secretHex = (try? KeychainService.readString(ref: relay.secretRef)) ?? ""
    state.phoneRelay = TunnelPhoneRelayParams(
        host: host, port: UInt16(clamping: relay.port),
        peerIDHex: relay.peerIDHex, secretHex: secretHex)
}
```

(Use `KeychainService`'s actual read API — check how the SSH private key is read app-side around `VPNManager.swift:1411-1447` and mirror it. If `host` resolves empty, let the extension fail with a clear "no gateway found — set the phone's address manually" error rather than silently connecting nowhere.)

- [ ] **Step 3: Run tests, verify pass, commit**

Run: `xcodegen generate && xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' test -only-testing:TunnelBahnUnitTests/PhoneRelayProfileTests`
Expected: PASS. (The exhaustive `switch runtime.profile.transport` in `PacketTunnelProvider.startTunnel:33-38` will now fail to compile — add a temporary `case .phoneRelay: throw NEVPNError(.configurationInvalid)` stub; Task 12 replaces it.)

```bash
git add TunnelBahn/Models/ Shared/TunnelRuntimeState.swift TunnelBahn/Services/VPNManager.swift NetworkExtension/PacketTunnelProvider.swift Tests/Unit/PhoneRelayProfileTests.swift project.yml
git commit -m "feat(share): phoneRelay transport kind, profile model, and runtime plumbing"
```

---

### Task 12: Mac `PhoneRelayFlowTransport` + provider wiring

**Files:**
- Create: `NetworkExtension/PhoneRelayFlowTransport.swift`
- Modify: `NetworkExtension/PacketTunnelProvider.swift` (replace the Task 11 stub with `startPhoneRelay`)
- Modify: `project.yml` (file into the NetworkExtension target)

**Interfaces:**
- Consumes: `RelayFlowTransport` protocol (`NetworkExtension/RelayFlowTransport.swift:13-28` — `onPayloadFromFlow`, `onFlowClosed`, `openTCP/sendTCP/openUDP/sendUDP/close`, `SendResult {ok, transient, permanent}`), `PacketTunnelRelayServer(relayBridge:packetQueue:)`, `RelayWireFrame`, `PhoneRelayHandshake` (Task 4), `TunnelPhoneRelayParams` (Task 11), `SSHFlowTransport` as the structural model (dial/reconnect/backoff at `SSHFlowTransport.swift:141`, provider wiring at `PacketTunnelProvider.swift:205-297`).
- Produces: `final class PhoneRelayFlowTransport: RelayFlowTransport` with `init(params: TunnelPhoneRelayParams, queue: DispatchQueue, log: @escaping (String) -> Void)`, `func start() async throws` (dial + TLS + handshake, throws on auth failure), `func stop()`; and `PacketTunnelProvider.startPhoneRelay(_ runtime: TunnelRuntimeState) async throws`.

- [ ] **Step 1: Implement the transport**

Core structure (complete the obvious symmetric parts marked "same pattern"; **read `SSHFlowTransport.swift` first and copy its threading contract** — all mutable state confined to one queue, `RelayFlowTransport` entry points arrive on the relay server's `packetQueue`):

```swift
import Foundation
import Network

/// RelayFlowTransport that egresses flows to the paired phone's share listener
/// over TCP+TLS (tbshare v1 handshake, then RelayWireFrame frames — the same
/// protocol the proxy extension already speaks over the local UNIX socket).
/// Structural model: SSHFlowTransport (reconnect/backoff/fail-fast contract).
final class PhoneRelayFlowTransport: RelayFlowTransport {
    var onPayloadFromFlow: ((UInt64, Data) -> Void)?
    var onFlowClosed: ((UInt64, String?) -> Void)?

    private let params: TunnelPhoneRelayParams
    private let queue: DispatchQueue
    private let log: (String) -> Void
    private var connection: NWConnection?
    private var observedCertDER = Data()
    private var receiveBuffer = Data()
    private var reqIDToFlowID: [UInt32: UInt64] = [:]
    private var nextReqID: UInt32 = 1
    private var authenticated = false
    private var stopped = false
    private var reconnectDelay: TimeInterval = 1

    init(params: TunnelPhoneRelayParams, queue: DispatchQueue, log: @escaping (String) -> Void) {
        self.params = params
        self.queue = queue
        self.log = log
    }

    // MARK: lifecycle

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { self.dial(initialStart: cont) }
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.connection?.cancel()
            self.connection = nil
            self.failAllFlows("relay stopped")
        }
    }

    private func makeTLSParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        // Accept any cert but capture its DER: authenticity comes from the
        // handshake's proof binding, not the chain (spec: tunnel-share-design).
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
                self.queue.async { self.observedCertDER = SecCertificateCopyData(leaf) as Data }
            }
            complete(true)
        }, queue)
        return NWParameters(tls: tls)
    }

    private func dial(initialStart: CheckedContinuation<Void, Error>?) {
        guard !stopped else { return }
        authenticated = false
        receiveBuffer.removeAll()
        let conn = NWConnection(
            host: NWEndpoint.Host(params.host),
            port: NWEndpoint.Port(rawValue: params.port) ?? 47600,
            using: makeTLSParameters())
        connection = conn
        var startCont = initialStart
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.runHandshake { result in
                    switch result {
                    case .success:
                        self.authenticated = true
                        self.reconnectDelay = 1
                        self.log("phone-relay: authenticated with \(self.params.host)")
                        startCont?.resume()
                        startCont = nil
                        self.receiveLoop()
                    case .failure(let err):
                        self.log("phone-relay: handshake failed: \(err)")
                        startCont?.resume(throwing: err)
                        startCont = nil
                        conn.cancel()
                    }
                }
            case .failed(let err):
                if let cont = startCont {
                    cont.resume(throwing: err)
                    startCont = nil
                } else {
                    self.scheduleReconnect()
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        failAllFlows("relay connection lost")
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        log("phone-relay: reconnecting in \(delay)s")
        queue.asyncAfter(deadline: .now() + delay) { self.dial(initialStart: nil) }
    }

    private func failAllFlows(_ reason: String) {
        let flows = reqIDToFlowID
        reqIDToFlowID.removeAll()
        for (_, flowID) in flows { onFlowClosed?(flowID, reason) }
        // PacketTunnelRelayServer also learns of closures via its own flow table;
        // matching SSHFlowTransport's fail-fast contract.
    }

    // MARK: handshake

    private func runHandshake(_ completion: @escaping (Result<Void, Error>) -> Void) {
        guard let conn = connection,
              let peerID = Data(hexString: params.peerIDHex),
              let secret = Data(hexString: params.secretHex), secret.count == 32 else {
            completion(.failure(PhoneRelayError.badConfig))
            return
        }
        let clientNonce = PhoneRelayHandshake.randomBytes(32)
        conn.send(content: PhoneRelayHandshake.makeClientHello(peerID: peerID, clientNonce: clientNonce),
                  completion: .contentProcessed { _ in })
        readExactly(64) { resp in
            guard let resp else { return completion(.failure(PhoneRelayError.handshakeClosed)) }
            let serverNonce = Data(resp.prefix(32))
            let proof = Data(resp.suffix(32))
            let expected = PhoneRelayHandshake.serverProof(
                secret: secret, clientNonce: clientNonce,
                serverNonce: serverNonce, certDER: self.observedCertDER)
            guard PhoneRelayHandshake.constantTimeEquals(proof, expected) else {
                return completion(.failure(PhoneRelayError.serverProofMismatch))
            }
            conn.send(content: PhoneRelayHandshake.clientProof(
                secret: secret, serverNonce: serverNonce, clientNonce: clientNonce),
                completion: .contentProcessed { _ in })
            self.readExactly(1) { status in
                guard status?.first == 1 else { return completion(.failure(PhoneRelayError.rejected)) }
                completion(.success(()))
            }
        }
    }

    private func readExactly(_ count: Int, _ done: @escaping (Data?) -> Void) {
        connection?.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            guard error == nil, let data, data.count == count else { return done(nil) }
            done(data)
        }
    }

    // MARK: frame plumbing

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.receiveBuffer.append(data) }
            self.drainFrames()
            if isComplete || error != nil {
                self.scheduleReconnect()
                return
            }
            self.receiveLoop()
        }
    }

    private func drainFrames() {
        while true {
            switch RelayWireFrame.parse(receiveBuffer) {
            case let .frame(frame, consumed):
                receiveBuffer.removeFirst(consumed)
                handle(frame)
            case .needMoreData:
                return
            case let .malformed(reason):
                log("phone-relay: malformed frame (\(reason)) — resetting link")
                connection?.cancel() // poisoned stream; reconnect resyncs
                return
            }
        }
    }

    private func handle(_ frame: RelayWireFrame.Frame) {
        switch frame {
        case let .openFlowReply(reqID, ok, error):
            guard let flowID = reqIDToFlowID.removeValue(forKey: reqID) else { return }
            if !ok { onFlowClosed?(flowID, error ?? "open refused") }
        case let .deliverPayloadPush(flowID, payload):
            onPayloadFromFlow?(flowID, payload)
        case let .flowClosedPush(flowID, error):
            onFlowClosed?(flowID, error)
        default:
            break // request frames are never valid server→client
        }
    }

    private func sendRaw(_ data: Data) -> Bool {
        guard authenticated, let conn = connection else { return false }
        conn.send(content: data, completion: .contentProcessed { _ in })
        return true
    }

    // MARK: RelayFlowTransport

    func openTCP(flowID: UInt64, remoteHost: String, remotePort: UInt16) -> Bool {
        open(flowID: flowID, host: remoteHost, port: remotePort, isTCP: true)
    }

    func openUDP(flowID: UInt64, remoteHost: String, remotePort: UInt16) -> Bool {
        open(flowID: flowID, host: remoteHost, port: remotePort, isTCP: false)
    }

    private func open(flowID: UInt64, host: String, port: UInt16, isTCP: Bool) -> Bool {
        guard authenticated else { return false }
        let reqID = nextReqID
        nextReqID &+= 1
        reqIDToFlowID[reqID] = flowID
        return sendRaw(RelayWireFrame.encodeOpenFlowRequest(
            reqID: reqID, flowID: flowID, remoteHost: host, remotePort: port, isTCP: isTCP))
    }

    func sendTCP(flowID: UInt64, data: Data) -> SendResult {
        guard authenticated else { return .transient }
        for frame in RelayWireFrame.encodeSendPayloadRequest(flowID: flowID, payload: data) {
            guard sendRaw(frame) else { return .transient }
        }
        return .ok
    }

    func sendUDP(flowID: UInt64, data: Data) -> Bool {
        guard authenticated else { return false }
        for frame in RelayWireFrame.encodeSendPayloadRequest(flowID: flowID, payload: data) {
            guard sendRaw(frame) else { return false }
        }
        return true
    }

    func close(flowID: UInt64) {
        _ = sendRaw(RelayWireFrame.encodeCloseFlowRequest(flowID: flowID))
    }
}

enum PhoneRelayError: Error {
    case badConfig, handshakeClosed, serverProofMismatch, rejected
}

extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var out = Data(capacity: hexString.count / 2)
        var idx = hexString.startIndex
        while idx < hexString.endIndex {
            let next = hexString.index(idx, offsetBy: 2)
            guard let byte = UInt8(hexString[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        self = out
    }
}
```

(If `Data(hexString:)` already exists in the project, reuse it instead of redefining.)

- [ ] **Step 2: Wire the provider**

In `PacketTunnelProvider.swift`, replace the Task 11 stub with a `startPhoneRelay(_ runtime:)` modeled line-for-line on `startSSH(_:)` (:205-297):

```swift
private func startPhoneRelay(_ runtime: TunnelRuntimeState) async throws {
    guard let params = runtime.phoneRelay, !params.host.isEmpty else {
        throw NSError(domain: "TunnelBahn", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Phone relay: no phone address (not tethered? set a manual address)"])
    }
    // NOTE (anti-loop): our own TCP dial to the phone is never captured — per-app
    // routing keys on sourceApplication and this extension is not a matched app;
    // excludeLocalNetworks additionally keeps the tether subnet out. Same
    // invariant as the SSH transport (see startSSH's comment).
    let transport = PhoneRelayFlowTransport(params: params, queue: packetQueue) { [weak self] in
        self?.log($0) // reuse the provider's existing logging helper
    }
    try await transport.start()
    phoneRelayTransport = transport
    guard let server = PacketTunnelRelayServer(relayBridge: transport, packetQueue: packetQueue) else {
        throw NSError(domain: "TunnelBahn", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Phone relay: could not start relay server"])
    }
    server.start()
    relayServer = server
    // Minimal settings, exactly like SSH: no utun routes — all traffic rides the
    // transparent proxy → UNIX socket → this transport.
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: params.host)
    try await setTunnelNetworkSettings(settings)
}
```

Add the `phoneRelayTransport` stored property beside the SSH transport's; mirror `stopTunnel`'s teardown (stop the relay server, `transport.stop()`); reuse the exact property names/queue the SSH path uses — including the `probeTCPReachability` diagnostic call with `params.host`/`params.port` (`PacketTunnelProvider.swift:150`), which is the first tool for debugging "can't reach the phone".

- [ ] **Step 3: Build everything, commit**

Run: `xcodegen generate && xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' build test`
Expected: builds; all unit tests pass.

```bash
git add NetworkExtension/ project.yml
git commit -m "feat(share): Mac phone-relay flow transport and tunnel provider wiring"
```

---

### Task 13: Mac UI — profile creation, editor fields, pairing QR

**Files:**
- Create: `TunnelBahn/Views/PhoneRelayEditorFields.swift`
- Modify: `TunnelBahn/Views/ProfileEditorSheet.swift` (transport picker case at :88-94; `if transport == .phoneRelay` section like the SSH one at :99)
- Modify: `TunnelBahn/Views/ProfilesView.swift` (a "New Phone Relay Profile" sidebar action next to `makeNewSSHProfile()`; `profileSubtitle` case at :509)

**Interfaces:**
- Consumes: Task 4 (`PhoneRelayPairing`), Task 11 (`PhoneRelayProfile`, `TransportKind.phoneRelay`), existing `presentQRPanel(title:content:)` (`ProfilesView.swift:675`), `WireGuardConfigRenderer.makeQRCodeImage(from:)`, `KeychainService`.
- Produces: user-visible flows — create a Phone Relay profile; edit port/manual-host/device-name; "Show Pairing QR" button that lazily generates `peerIDHex` + secret (secret → Keychain under a fresh `secretRef`, id stays on the profile) and presents the QR panel with `PhoneRelayPairing(...).qrJSONString()`.

- [ ] **Step 1: Implement `PhoneRelayEditorFields.swift`**

Model it on `SSHProfileEditorFields.swift` (same Form/section idioms). Fields: device name (TextField), port (TextField with Int formatting), manual host override (TextField, footer text "Leave empty to use the phone automatically when tethered"), and a "Show Pairing QR" button wired to a closure `onShowPairingQR: () -> Void` passed from the sheet. Pairing generation logic goes in the sheet/AppState layer, not the field view:

```swift
// In ProfileEditorSheet (or the store it already uses for Keychain writes):
func ensurePairingAndShowQR(for profile: inout WireGuardProfile) {
    var relay = profile.phoneRelay ?? PhoneRelayProfile()
    if relay.peerIDHex.isEmpty || relay.secretRef.isEmpty {
        let pairing = PhoneRelayPairing.generate(name: Host.current().localizedName ?? "Mac")
        relay.peerIDHex = pairing.id
        relay.secretRef = "phone-relay-secret-\(profile.id.uuidString)"
        try? KeychainService.writeString(pairing.secret, ref: relay.secretRef) // mirror the SSH key write API
        profile.phoneRelay = relay
        presentPairingQR(pairing)
    } else if let secret = try? KeychainService.readString(ref: relay.secretRef) {
        presentPairingQR(PhoneRelayPairing(
            kind: PhoneRelayPairing.expectedKind, v: 1, id: relay.peerIDHex,
            secret: secret, name: relay.deviceName.isEmpty ? "Mac" : relay.deviceName,
            port: relay.port))
    }
}
```

`presentPairingQR` renders via the existing QR panel path: `presentQRPanel(title: "Pair with phone", content: try! pairing.qrJSONString())` (match the actual helper signature at `ProfilesView.swift:675` — if the panel helper lives on ProfilesView, route the editor's QR through the same mechanism the "Export to Android (QR)" action uses at :638).

- [ ] **Step 2: Wire the picker, the new-profile action, and the subtitle**

- `ProfileEditorSheet.swift:88-94`: add `.phoneRelay` to the transport `Picker` ("Phone Relay (share phone's tunnel)").
- `:99` region: `if transport == .phoneRelay { PhoneRelayEditorFields(...) }`.
- `ProfilesView.swift`: clone `makeNewSSHProfile()` → `makeNewPhoneRelayProfile()` (transport `.phoneRelay`, empty `PhoneRelayProfile()`), add the sidebar/menu entry next to "New SSH Profile"; add the `profileSubtitle` case (:509) returning e.g. `"Phone Relay · \(relay.manualHost.isEmpty ? "auto (gateway)" : relay.manualHost)"`.

- [ ] **Step 3: Build, run the full Mac test suite, manual smoke**

Run: `xcodegen generate && xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' build test`
Expected: builds, tests pass.

Manual smoke (no phone needed): create a Phone Relay profile → "Show Pairing QR" renders a QR whose JSON parses with `PhoneRelayPairing.parse`; connecting without a phone fails with the "no phone address" error, not a hang.

- [ ] **Step 4: Commit**

```bash
git add TunnelBahn/Views/ project.yml
git commit -m "feat(share): Mac phone-relay profile UI and pairing QR"
```

---

### Task 14: Docs + end-to-end verification checklist

**Files:**
- Create: `docs/superpowers/plans/2026-08-30-tunnel-share-e2e-checklist.md`
- Modify: `README.md` (a "Tunnel Sharing (Phone Relay)" section)

**Interfaces:**
- Consumes: everything above.
- Produces: the on-device verification script and user-facing docs.

- [ ] **Step 1: Write the e2e checklist**

```markdown
# Tunnel Sharing e2e checklist (on-device)

Setup: Android phone with a working SSH profile + hotspot on; MacBook joined to the hotspot.

1. Pair: Mac → Phone Relay profile → Show Pairing QR; phone → Tunnel Sharing → Pair a device → scan.
   Expect: device appears in the paired list.
2. Phone: connect the SSH profile, enable Tunnel Sharing. Expect: "On — no device connected".
3. Mac: connect the Phone Relay profile (per-app routing configured as usual).
   Expect: phone shows "1 device(s) connected"; Mac tunnel state Connected.
4. Mac exit IP (routed app → https://api.ipify.org): equals the PHONE's tunnel exit IP,
   not the hotspot NAT IP.
5. Mac DNS: routed browser resolves and loads a fresh domain (phone on SSH transport —
   proves the DNS flow path).
6. Mac UDP on SSH transport: a QUIC-only probe falls back to TCP (no hang).
   Switch phone to the wgws profile, reconnect both: UDP flow works (QUIC loads).
7. Kill the phone app / stop the phone tunnel. Expect: Mac flows fail fast (fail-closed),
   Mac reconnects automatically after the phone reconnects + sharing re-enables.
8. Revoke the Mac on the phone, reconnect Mac. Expect: authentication fails, clear error.
9. Wrong network (Mac on home Wi-Fi, no manual host): connect fails with the
   "no phone address / set manual address" error. Set manual host to the phone's LAN IP
   on the same Wi-Fi: works (same-LAN mode).
10. Battery/perf sanity: stream a video 5 min through the relay; phone stays responsive.
```

- [ ] **Step 2: README section**

Add under the transports sections: what Tunnel Sharing is (Mac rides the phone's tunnel when tethered), the pairing flow, the security model (QR secret + TLS + cert-bound proofs), the UDP caveat per phone transport (SSH = TCP+DNS only), and that the Mac needs no server credentials.

- [ ] **Step 3: Full verification sweep**

Run all three suites and record output:

```bash
cd android/core && go test ./... -race
cd .. && ./gradlew :app:assembleDebug :app:testDebugUnitTest && cd ..
xcodegen generate && xcodebuild -project TunnelBahn.xcodeproj -scheme TunnelBahn -destination 'platform=macOS' test
```

Expected: all PASS. Then walk the e2e checklist on real hardware (requires the user's phone + server; coordinate before claiming the feature done).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-08-30-tunnel-share-e2e-checklist.md README.md
git commit -m "docs(share): tunnel sharing docs and e2e verification checklist"
```

---

## Self-review notes (already applied)

- Spec coverage: pairing (Tasks 4, 8, 13), auth/TLS (3, 4, 5, 12), TCP relay (5, 12), UDP + DNS + hostname (6), lifecycle (7, 9, 12), discovery-via-gateway (10, 11), UI both sides (9, 13), e2e (14).
- Known intentional gaps vs. a maximal design: no per-client stats, ephemeral server cert (trust = proof binding), IPv4/A-record only, no mDNS — all recorded as spec non-goals.
- Type-consistency check: `relaywire.Parse` tri-state, `share.Config.Resolve` closure seam, `TunnelPhoneRelayParams` field names, and the three `StartShare/StopShare/ShareClientCount` signatures are used identically across tasks.
- Executor freedoms called out inline: exact `Session` mutex/field names (Task 7), `KeychainService` read/write API names (Tasks 11, 13), `TunnelBahnVpnService.state` type (Task 9), SSH transport threading contract (Task 12). In each case the instruction is "read the named existing code and mirror it", not an invented API.
