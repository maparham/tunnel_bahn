import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOSSH

/// SSH-backed egress transport.
///
/// This task (Task 4) stands up the *connection* layer only: it opens one SSH client connection
/// to the server, authenticates with a private key, and verifies the server host key via
/// trust-on-first-use (TOFU). The per-flow `direct-tcpip` channels that make this a real
/// `RelayFlowTransport` egress are added in Task 5 — until then `openTCP`/`sendTCP`/`close` are
/// minimal stubs that report failure.
///
/// Auth is **private-key only** (see `parsePrivateKey`). swift-nio-ssh 0.14.1's `NIOSSHPrivateKey`
/// only supports ed25519 and ECDSA P-256/384/521 — there is *no* RSA backing case — so RSA client
/// keys cannot be used with this library version regardless of parsing (documented in the report).
final class SSHFlowTransport: RelayFlowTransport, @unchecked Sendable {
    // MARK: RelayFlowTransport callbacks (used from Task 5 onward)
    var onPayloadFromFlow: ((UInt64, Data) -> Void)?
    var onFlowClosed: ((UInt64, String?) -> Void)?

    // MARK: Configuration
    private let host: String
    private let port: UInt16
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private let serverAuth: HostKeyValidator

    // MARK: Runtime
    private let group: EventLoopGroup
    private var channel: Channel?
    private var groupShutDown = false

    private static let log = AppLog(subsystem: "com.tunnelbahn.mac", category: "SSHFlowTransport")

    /// - Parameters:
    ///   - pinnedHostKeyFingerprint: an explicitly-configured host-key fingerprint. When present it
    ///     is treated as a hard requirement (the offered key must match it exactly). When `nil` the
    ///     `hostKeyStore` performs TOFU pinning.
    init(host: String,
         port: UInt16,
         username: String,
         privateKeyPEM: String,
         pinnedHostKeyFingerprint: String?,
         hostKeyStore: SSHHostKeyStore,
         queue: DispatchQueue) throws {
        self.host = host
        self.port = port
        self.username = username
        self.privateKey = try Self.parsePrivateKey(pem: privateKeyPEM)
        self.serverAuth = HostKeyValidator(host: host,
                                           store: hostKeyStore,
                                           explicitPin: pinnedHostKeyFingerprint,
                                           log: Self.log)
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    // MARK: Connection lifecycle

    /// Establishes the SSH transport connection: TCP connect, key exchange, host-key TOFU
    /// verification, and private-key user authentication. Returns once the server has accepted
    /// authentication; throws if the connection, host-key check, or auth fails.
    func start() async throws {
        Self.log.notice("[APPSPLIT_SSH] connect start host=\(host) port=\(port) user=\(username)")

        let authDelegate = PrivateKeyAuth(username: username, privateKey: privateKey, log: Self.log)
        let serverAuth = self.serverAuth

        // Promise fulfilled once the server signals successful user-auth (UserAuthSuccessEvent),
        // or failed if the connection closes / errors before that. This gives an honest
        // auth-success/-failure signal rather than inferring it from channel-active.
        let authPromise = group.next().makePromise(of: Void.self)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let sshHandler = NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: authDelegate,
                                        serverAuthDelegate: serverAuth)),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil)
                let authObserver = AuthCompletionHandler(promise: authPromise, log: Self.log)
                return channel.pipeline.addHandlers([sshHandler, authObserver])
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: Int(port)).get()
        } catch {
            authPromise.fail(error)
            Self.log.error("[APPSPLIT_SSH] auth fail (connect) host=\(host): \(error)")
            shutdownGroup()      // don't leak the event-loop group on a failed start
            throw error
        }
        self.channel = channel

        do {
            try await authPromise.futureResult.get()
        } catch {
            // Prefer the specific host-key rejection reason (if any) over the generic
            // channel-closed error the teardown surfaces, so Task 6/UI can distinguish
            // "host key changed / rejected" from an ordinary disconnect.
            let reason = serverAuth.rejectionReason ?? error
            Self.log.error("[APPSPLIT_SSH] auth fail host=\(host): \(reason)")
            try? await channel.close().get()
            self.channel = nil
            shutdownGroup()      // don't leak the event-loop group on a failed start
            throw reason
        }
        Self.log.notice("[APPSPLIT_SSH] auth success host=\(host) user=\(username)")
    }

    func stop() {
        if let channel = channel {
            channel.close(promise: nil)
            self.channel = nil
        }
        shutdownGroup()
    }

    /// Shuts down the event-loop group at most once. Safe to call from both the `start()` failure
    /// paths and `stop()`; a redundant call is swallowed.
    private func shutdownGroup() {
        guard !groupShutDown else { return }
        groupShutDown = true
        try? group.syncShutdownGracefully()
    }

    // MARK: RelayFlowTransport — per-flow channels arrive in Task 5

    // Task 5: open a `direct-tcpip` child channel on `channel` for this flow.
    func openTCP(flowID: UInt64, remoteHost: String, remotePort: UInt16) -> Bool { false }

    // Task 5: write into the flow's `direct-tcpip` child channel with backpressure hysteresis.
    func sendTCP(flowID: UInt64, data: Data) -> SendResult { .permanent }

    // Task 5: close the flow's `direct-tcpip` child channel.
    func close(flowID: UInt64) {}

    // MARK: Host-key fingerprint

    /// SSH host-key fingerprint = base64( SHA-256( host-key SSH wire encoding ) ).
    ///
    /// The wire encoding is obtained via the public `String(openSSHPublicKey:)` initializer, which
    /// renders `"<algorithm-id> <base64-wire-blob>"`; we decode the blob back to the raw wire bytes
    /// and hash them. (NIOSSH's `ByteBuffer.writeSSHHostKey` is `internal`, so this is the supported
    /// public-API path to the same bytes.) Format is plain base64 with padding, no `SHA256:` prefix.
    static func fingerprint(of hostKey: NIOSSHPublicKey) -> String {
        let openSSH = String(openSSHPublicKey: hostKey)
        let parts = openSSH.split(separator: " ")
        let wireBytes: Data
        if parts.count >= 2, let decoded = Data(base64Encoded: String(parts[1])) {
            wireBytes = decoded
        } else {
            // Defensive fallback: hash the whole rendering rather than crash.
            wireBytes = Data(openSSH.utf8)
        }
        let digest = SHA256.hash(data: wireBytes)
        return Data(digest).base64EncodedString()
    }

    // MARK: Private-key parsing

    enum KeyParseError: Error, CustomStringConvertible {
        case unsupportedRSA
        case unsupportedFormat
        case encryptedKeyUnsupported
        case malformed(String)

        var description: String {
            switch self {
            case .unsupportedRSA:
                return "RSA private keys are not supported by swift-nio-ssh 0.14.1 (NIOSSHPrivateKey has no RSA backing). Use an ed25519 or ECDSA (P-256/384/521) key."
            case .unsupportedFormat:
                return "Unrecognized private key PEM. Expected ed25519 or ECDSA P-256/384/521 as an OpenSSH container (-----BEGIN OPENSSH PRIVATE KEY-----), SEC1 (-----BEGIN EC PRIVATE KEY-----), or PKCS#8 (-----BEGIN PRIVATE KEY-----)."
            case .encryptedKeyUnsupported:
                return "Encrypted (passphrase-protected) private keys are not supported. Provide an unencrypted key."
            case .malformed(let detail):
                return "Malformed OpenSSH private key: \(detail)"
            }
        }
    }

    /// Parses a user-supplied PEM into a `NIOSSHPrivateKey`.
    ///
    /// Supported: ed25519 and ECDSA P-256/384/521, in either the OpenSSH container
    /// (`-----BEGIN OPENSSH PRIVATE KEY-----`) or a standard PEM (SEC1 `-----BEGIN EC PRIVATE KEY-----`
    /// or PKCS#8 `-----BEGIN PRIVATE KEY-----`) for the ECDSA curves. RSA is rejected explicitly —
    /// `NIOSSHPrivateKey` has no RSA backing in swift-nio-ssh 0.14.1.
    ///
    /// Rationale for the split paths: swift-crypto's `Curve25519.Signing.PrivateKey` and the NIST
    /// `P{256,384,521}.Signing.PrivateKey` types expose different constructors — Curve25519 has only
    /// `rawRepresentation` (no PEM), and the NIST `pemRepresentation` initializer accepts PKCS#8 but
    /// NOT SEC1. So ed25519 and OpenSSH-container ECDSA are parsed from the SSH wire format directly,
    /// PKCS#8 ECDSA uses swift-crypto's PEM initializer, and SEC1 ECDSA is parsed from its DER.
    static func parsePrivateKey(pem: String) throws -> NIOSSHPrivateKey {
        if pem.contains("BEGIN RSA PRIVATE KEY") { throw KeyParseError.unsupportedRSA }
        if pem.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSHContainer(pem: pem)
        }
        if pem.contains("BEGIN EC PRIVATE KEY") {          // SEC1
            return try parseSEC1ECDSA(pem: pem)
        }
        if pem.contains("BEGIN PRIVATE KEY") {             // PKCS#8
            return try parsePKCS8ECDSA(pem: pem)
        }
        throw KeyParseError.unsupportedFormat
    }

    // MARK: ECDSA — standard PEM (PKCS#8 and SEC1)

    /// PKCS#8 ECDSA: swift-crypto's `pemRepresentation` initializer accepts PKCS#8 directly. The PEM
    /// header does not name the curve, so we try P-256, then P-384, then P-521 and use whichever
    /// parses (each initializer validates the embedded curve OID and throws on mismatch).
    static func parsePKCS8ECDSA(pem: String) throws -> NIOSSHPrivateKey {
        if let k = try? P256.Signing.PrivateKey(pemRepresentation: pem) { return NIOSSHPrivateKey(p256Key: k) }
        if let k = try? P384.Signing.PrivateKey(pemRepresentation: pem) { return NIOSSHPrivateKey(p384Key: k) }
        if let k = try? P521.Signing.PrivateKey(pemRepresentation: pem) { return NIOSSHPrivateKey(p521Key: k) }
        throw KeyParseError.malformed("PKCS#8 key is not ECDSA P-256/384/521 (ed25519 PKCS#8 and other curves are unsupported)")
    }

    /// SEC1 ECDSA (`EC PRIVATE KEY`): swift-crypto's `pemRepresentation` initializer rejects SEC1, so
    /// we parse the DER (RFC 5915) directly. The curve is taken from the DER's optional `[0]`
    /// parameters OID when present, else inferred from the scalar length; the scalar is then
    /// normalized to the exact curve width before building the matching NIST key.
    static func parseSEC1ECDSA(pem: String) throws -> NIOSSHPrivateKey {
        let (scalarRaw, oidByteCount) = try sec1PrivateScalar(pem: pem)
        // Prefer the parameters OID; fall back to the raw scalar length (32/48/66).
        let byteCount = oidByteCount ?? scalarRaw.count
        let scalar = try normalizeScalar(scalarRaw, byteCount: byteCount)
        return try ecdsaKey(fromScalar: scalar, curveByteCount: byteCount)
    }

    /// Extracts the `privateKey` OCTET STRING (and, if present, the curve width implied by the
    /// `[0]` parameters OID) from a SEC1 `ECPrivateKey` DER.
    /// `ECPrivateKey ::= SEQUENCE { version INTEGER, privateKey OCTET STRING,
    ///                              parameters [0] ECParameters OPTIONAL, publicKey [1] BIT STRING OPTIONAL }`
    ///
    /// The PEM body is scoped to the region strictly between `-----BEGIN EC PRIVATE KEY-----` and
    /// `-----END EC PRIVATE KEY-----`, ignoring any other blocks (e.g. a leading `EC PARAMETERS`
    /// block that `openssl ecparam -genkey` emits) that would otherwise corrupt the base64.
    static func sec1PrivateScalar(pem: String) throws -> (scalar: Data, curveByteCount: Int?) {
        let beginMarker = "-----BEGIN EC PRIVATE KEY-----"
        let endMarker = "-----END EC PRIVATE KEY-----"
        guard let beginRange = pem.range(of: beginMarker),
              let endRange = pem.range(of: endMarker, range: beginRange.upperBound ..< pem.endIndex) else {
            throw KeyParseError.malformed("SEC1: missing EC PRIVATE KEY block markers")
        }
        let inner = pem[beginRange.upperBound ..< endRange.lowerBound]
        let body = inner
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined()
        guard let der = Data(base64Encoded: body) else {
            throw KeyParseError.malformed("SEC1 body is not valid base64")
        }
        var r = DERReader(der)
        guard try r.tag() == 0x30 else { throw KeyParseError.malformed("SEC1: expected SEQUENCE") }
        _ = try r.length()
        guard try r.tag() == 0x02 else { throw KeyParseError.malformed("SEC1: expected version INTEGER") }
        _ = try r.take(try r.length())          // skip version
        guard try r.tag() == 0x04 else { throw KeyParseError.malformed("SEC1: expected privateKey OCTET STRING") }
        let scalar = try r.take(try r.length())

        // Optional [0] parameters (context tag 0xA0) → ECParameters, usually a namedCurve OID.
        var curveByteCount: Int? = nil
        if let next = r.peekTag(), next == 0xA0 {
            _ = try r.tag()
            let paramsLen = try r.length()
            var params = DERReader(try r.take(paramsLen))
            if let inner = params.peekTag(), inner == 0x06 {
                _ = try params.tag()
                let oid = try params.take(try params.length())
                curveByteCount = Self.curveByteCount(forNamedCurveOID: oid)
            }
        }
        return (scalar, curveByteCount)
    }

    /// Maps a namedCurve OID (DER content bytes, without the tag/length) to the curve's scalar width.
    private static func curveByteCount(forNamedCurveOID oid: Data) -> Int? {
        // prime256v1 1.2.840.10045.3.1.7 ; secp384r1 1.3.132.0.34 ; secp521r1 1.3.132.0.35
        let p256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        let p384: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x22]
        let p521: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x23]
        switch Array(oid) {
        case p256: return 32
        case p384: return 48
        case p521: return 66
        default: return nil
        }
    }

    /// Wraps a raw EC private scalar (already curve-sized, big-endian) into the matching NIOSSHPrivateKey.
    static func ecdsaKey(fromScalar scalar: Data, curveByteCount: Int) throws -> NIOSSHPrivateKey {
        switch curveByteCount {
        case 32: return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: scalar))
        case 48: return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: scalar))
        case 66: return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: scalar))
        default:
            throw KeyParseError.malformed("unrecognized ECDSA scalar length \(curveByteCount) (expected 32/48/66)")
        }
    }

    /// Parses an unencrypted OpenSSH private-key container into a `NIOSSHPrivateKey`.
    /// Supports keytypes `ssh-ed25519` and `ecdsa-sha2-nistp{256,384,521}`.
    ///
    /// OpenSSH private-key format (unencrypted):
    ///   "openssh-key-v1\0"
    ///   string  ciphername          ("none")
    ///   string  kdfname             ("none")
    ///   string  kdfoptions          ("")
    ///   uint32  number of keys      (1)
    ///   string  publickey[0]
    ///   string  encrypted section:
    ///       uint32 checkint
    ///       uint32 checkint          (must equal the first)
    ///       string keytype
    ///       <keytype-specific fields, see below>
    ///       string comment
    ///       padding 1,2,3,...
    /// All SSH "string"s are a uint32 big-endian length followed by that many bytes.
    ///
    /// ed25519 fields:  string pub(32)  ·  string priv(64 = seed || pubkey)
    /// ecdsa fields:    string curve-name  ·  string Q(public point)  ·  string d(private scalar, mpint)
    static func parseOpenSSHContainer(pem: String) throws -> NIOSSHPrivateKey {
        // Strip armor lines and whitespace, base64-decode the body.
        let body = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let blob = Data(base64Encoded: body) else {
            throw KeyParseError.malformed("body is not valid base64")
        }

        var reader = SSHBlobReader(blob)

        let magic = "openssh-key-v1\u{0}"
        guard let magicBytes = reader.take(magic.utf8.count),
              magicBytes == Data(magic.utf8) else {
            throw KeyParseError.malformed("missing openssh-key-v1 magic")
        }

        let cipher = try reader.readString()
        let kdf = try reader.readString()
        _ = try reader.readLengthPrefixed()   // kdfoptions
        guard cipher == "none", kdf == "none" else {
            throw KeyParseError.encryptedKeyUnsupported
        }

        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else {
            throw KeyParseError.malformed("unexpected key count \(keyCount)")
        }

        _ = try reader.readLengthPrefixed()    // public key blob (skip)

        // Private section is itself a length-prefixed blob.
        let privSection = try reader.readLengthPrefixed()
        var priv = SSHBlobReader(privSection)

        let check1 = try priv.readUInt32()
        let check2 = try priv.readUInt32()
        guard check1 == check2 else {
            throw KeyParseError.malformed("checkint mismatch (wrong passphrase or corrupt key)")
        }

        let keytype = try priv.readString()
        switch keytype {
        case "ssh-ed25519":
            _ = try priv.readLengthPrefixed()      // public key (32 bytes)
            let privateBlob = try priv.readLengthPrefixed()  // 64 bytes: seed || pubkey
            guard privateBlob.count == 64 else {
                throw KeyParseError.malformed("ed25519 private field is \(privateBlob.count) bytes, expected 64")
            }
            let seed = privateBlob.prefix(32)
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curveName = try priv.readString()       // e.g. "nistp256"
            _ = try priv.readLengthPrefixed()           // Q: public EC point (skip)
            let scalarRaw = try priv.readLengthPrefixed()  // d: private scalar as SSH mpint
            let byteCount: Int
            switch curveName {
            case "nistp256": byteCount = 32
            case "nistp384": byteCount = 48
            case "nistp521": byteCount = 66
            default: throw KeyParseError.malformed("unknown ECDSA curve '\(curveName)'")
            }
            let scalar = try normalizeScalar(scalarRaw, byteCount: byteCount)
            return try ecdsaKey(fromScalar: scalar, curveByteCount: byteCount)

        default:
            if keytype.contains("rsa") { throw KeyParseError.unsupportedRSA }
            throw KeyParseError.malformed("unsupported key type '\(keytype)' (only ssh-ed25519 and ecdsa-sha2-nistp256/384/521)")
        }
    }

    /// Normalizes an SSH `mpint`-style scalar to exactly `byteCount` big-endian bytes: drops a leading
    /// zero sign byte / leading zeros, then left-pads with zeros. swift-crypto's NIST
    /// `PrivateKey(rawRepresentation:)` requires the exact curve byte count.
    static func normalizeScalar(_ raw: Data, byteCount: Int) throws -> Data {
        var bytes = Array(raw)
        while bytes.count > byteCount, bytes.first == 0 { bytes.removeFirst() }
        guard bytes.count <= byteCount else {
            throw KeyParseError.malformed("ECDSA scalar too large (\(bytes.count) > \(byteCount))")
        }
        if bytes.count < byteCount {
            bytes = Array(repeating: UInt8(0), count: byteCount - bytes.count) + bytes
        }
        return Data(bytes)
    }
}

// MARK: - Minimal DER TLV reader (for SEC1 EC private keys)

/// Just enough DER to walk a SEC1 `ECPrivateKey` SEQUENCE and pull out the private-scalar OCTET STRING.
private struct DERReader {
    private let d: [UInt8]
    private var o: Int

    init(_ data: Data) { self.d = Array(data); self.o = 0 }

    mutating func tag() throws -> UInt8 {
        guard o < d.count else { throw SSHFlowTransport.KeyParseError.malformed("DER: truncated tag") }
        let t = d[o]; o += 1; return t
    }

    /// Returns the next tag byte without consuming it, or nil at end of buffer.
    func peekTag() -> UInt8? {
        o < d.count ? d[o] : nil
    }

    mutating func length() throws -> Int {
        guard o < d.count else { throw SSHFlowTransport.KeyParseError.malformed("DER: truncated length") }
        let first = d[o]; o += 1
        if first < 0x80 { return Int(first) }
        let n = Int(first & 0x7f)
        guard n >= 1, n <= 4, o + n <= d.count else {
            throw SSHFlowTransport.KeyParseError.malformed("DER: bad long-form length")
        }
        var value = 0
        for _ in 0 ..< n { value = (value << 8) | Int(d[o]); o += 1 }
        return value
    }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, o + count <= d.count else {
            throw SSHFlowTransport.KeyParseError.malformed("DER: truncated value")
        }
        let slice = Data(d[o ..< o + count]); o += count; return slice
    }
}

// MARK: - SSH wire blob reader

/// Minimal big-endian reader for the SSH binary "string" wire format used inside OpenSSH keys.
private struct SSHBlobReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    private var remaining: Int { data.endIndex - offset }

    mutating func take(_ count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        let slice = data.subdata(in: offset ..< offset + count)
        offset += count
        return slice
    }

    mutating func readUInt32() throws -> UInt32 {
        guard let bytes = take(4) else {
            throw SSHFlowTransport.KeyParseError.malformed("truncated uint32")
        }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readLengthPrefixed() throws -> Data {
        let len = try readUInt32()
        guard let bytes = take(Int(len)) else {
            throw SSHFlowTransport.KeyParseError.malformed("truncated string of length \(len)")
        }
        return bytes
    }

    mutating func readString() throws -> String {
        let bytes = try readLengthPrefixed()
        guard let s = String(data: bytes, encoding: .utf8) else {
            throw SSHFlowTransport.KeyParseError.malformed("non-utf8 string")
        }
        return s
    }
}

// MARK: - User authentication (private key)

/// Offers the configured private key for `publickey` authentication. Offers the key exactly once;
/// if the server rejects it and asks again, fails the challenge (nil offer) to avoid an infinite
/// re-offer loop.
private final class PrivateKeyAuth: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private let log: AppLog
    private var offered = false

    init(username: String, privateKey: NIOSSHPrivateKey, log: AppLog) {
        self.username = username
        self.privateKey = privateKey
        self.log = log
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey), !offered else {
            if offered {
                log.error("[APPSPLIT_SSH] auth fail: server rejected private key")
            } else {
                log.error("[APPSPLIT_SSH] auth fail: server does not accept publickey auth")
            }
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: privateKey)))
        nextChallengePromise.succeed(offer)
    }
}

// MARK: - Host-key validation (TOFU)

/// Validates the server host key against the `SSHHostKeyStore` (TOFU) or an explicit pin.
/// On mismatch it FAILS the validation promise — a changed host key is a hard MITM failure and is
/// never auto-trusted.
private final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let store: SSHHostKeyStore
    private let explicitPin: String?
    private let log: AppLog

    /// Set when this delegate fails host-key validation, so `start()` can surface the specific
    /// "host key changed / rejected" reason instead of the generic disconnect error that the
    /// resulting connection teardown produces. Written on the event loop before the validation
    /// promise is failed; read by `start()` only after awaiting that failure (happens-after).
    private(set) var rejectionReason: Error?

    struct HostKeyRejected: Error, CustomStringConvertible {
        enum Kind { case explicitPinMismatch, tofuMismatch }
        let host: String
        let kind: Kind
        var description: String {
            switch kind {
            case .explicitPinMismatch:
                return "SSH host key verification failed for \(host): offered key does not match the configured pin (possible MITM)"
            case .tofuMismatch:
                return "SSH host key verification failed for \(host): host key changed since first use (possible MITM)"
            }
        }
    }

    init(host: String, store: SSHHostKeyStore, explicitPin: String?, log: AppLog) {
        self.host = host
        self.store = store
        self.explicitPin = explicitPin
        self.log = log
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fp = SSHFlowTransport.fingerprint(of: hostKey)

        if let pin = explicitPin {
            if fp == pin {
                log.notice("[APPSPLIT_SSH] host-key matched (explicit pin) host=\(host)")
                validationCompletePromise.succeed(())
            } else {
                log.critical("[APPSPLIT_SSH] host-key REJECTED (explicit pin mismatch) host=\(host)")
                let reason = HostKeyRejected(host: host, kind: .explicitPinMismatch)
                rejectionReason = reason
                validationCompletePromise.fail(reason)
            }
            return
        }

        let known = store.fingerprint(forHost: host) != nil
        if store.verifyOrPin(fingerprint: fp, forHost: host) {
            if known {
                log.notice("[APPSPLIT_SSH] host-key matched (TOFU pin) host=\(host)")
            } else {
                log.notice("[APPSPLIT_SSH] host-key pinned (first seen, TOFU) host=\(host)")
            }
            validationCompletePromise.succeed(())
        } else {
            log.critical("[APPSPLIT_SSH] host-key REJECTED (TOFU mismatch) host=\(host)")
            let reason = HostKeyRejected(host: host, kind: .tofuMismatch)
            rejectionReason = reason
            validationCompletePromise.fail(reason)
        }
    }
}

// MARK: - Auth completion observer

/// Watches for `UserAuthSuccessEvent` (fired by `NIOSSHHandler` once the server accepts user auth)
/// and fulfills the connection's auth promise. If the channel goes inactive or errors before that
/// event, the promise is failed so `start()` surfaces an auth/connection failure.
private final class AuthCompletionHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let promise: EventLoopPromise<Void>
    private let log: AppLog
    private var completed = false

    init(promise: EventLoopPromise<Void>, log: AppLog) {
        self.promise = promise
        self.log = log
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !completed {
            completed = true
            promise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            completed = true
            promise.fail(ChannelError.ioOnClosedChannel)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !completed {
            completed = true
            promise.fail(error)
        }
        context.fireErrorCaught(error)
    }
}
