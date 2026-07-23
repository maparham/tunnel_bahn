import Foundation

/// Abstract key/value backing for the host-key store. Deliberately a *reference*-semantics
/// protocol (`set` is non-mutating) so a single backing instance persists writes across the
/// `SSHHostKeyStore` value type. Implementations MUST be classes.
protocol HostKeyBacking: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
}

/// Trust-on-first-use (TOFU) store for SSH server host-key fingerprints.
///
/// A fingerprint here is the base64 of the SHA-256 digest of the server host key's SSH wire
/// encoding (see `SSHFlowTransport.fingerprint(of:)`). The first time a host is seen its key is
/// pinned and trusted; every subsequent connection must present the *same* fingerprint, otherwise
/// verification fails (a changed key is treated as a hard MITM failure — never auto-trusted).
struct SSHHostKeyStore {
    private let backing: HostKeyBacking

    init(backing: HostKeyBacking) {
        self.backing = backing
    }

    private func storageKey(forHost host: String) -> String { "ssh-hostkey.\(host)" }

    /// The currently-pinned fingerprint for `host`, or `nil` if the host has never been seen.
    func fingerprint(forHost host: String) -> String? {
        backing.get(storageKey(forHost: host))
    }

    /// Pin `fingerprint` for `host`, overwriting any existing pin.
    func pin(fingerprint fp: String, forHost host: String) {
        backing.set(storageKey(forHost: host), fp)
    }

    /// TOFU verification.
    ///
    /// - Returns: `true` if `fingerprint` matches the existing pin, or if the host was previously
    ///   unknown (in which case it is now pinned). `false` if the host was known and the presented
    ///   fingerprint does NOT match the pin (host-key change / possible MITM).
    func verifyOrPin(fingerprint fp: String, forHost host: String) -> Bool {
        if let existing = fingerprint(forHost: host) {
            return existing == fp
        }
        pin(fingerprint: fp, forHost: host)
        return true
    }
}

/// Production backing: the App Group `UserDefaults` suite (shared between the host app and the
/// system extension). Host-key fingerprints are non-secret trust anchors, so plain shared
/// defaults is adequate; the SSH *private* key lives in the Keychain (wired in a later task).
final class UserDefaultsHostKeyBacking: HostKeyBacking {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroupStore.defaults) {
        self.defaults = defaults
    }

    func get(_ key: String) -> String? {
        defaults.string(forKey: key)
    }

    func set(_ key: String, _ value: String) {
        defaults.set(value, forKey: key)
    }
}
