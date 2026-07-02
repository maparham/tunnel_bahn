import Foundation
import Darwin
import OSLog
import SystemConfiguration

/// Per-process file-based log writer shared across the host app and both system extensions
/// via the app group container. Each process opens its own append-mode file descriptor; the
/// kernel's `O_APPEND` guarantees atomic appends for writes under PIPE_BUF, which is
/// sufficient for one JSON line per log call. The in-process `NSLock` only serializes
/// access to our cached FD across threads in the same process.
///
/// Format: one minified JSON object per line:
/// `{"ts":"...","subsystem":"...","category":"...","level":"...","pid":N,"process":"...","message":"..."}`
final class SharedLogWriter {
    static let shared = SharedLogWriter()

    private let fd: Int32
    private let lock = NSLock()
    private let processName: String
    private let pid: Int32

    /// Native `os.Logger` (not `AppLog`, to avoid infinite recursion) used to surface
    /// diagnostics about the writer itself. Visible in `log stream` even when the file
    /// path is the very thing that's broken.
    private static let diag = Logger(subsystem: "com.tunnelbahn.mac.sharedlog", category: "SharedLogWriter")

    private init() {
        self.pid = ProcessInfo.processInfo.processIdentifier
        self.processName = ProcessInfo.processInfo.processName
        if let path = Self.resolvedLogsPath() {
            let opened = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            self.fd = opened
            if opened >= 0 {
                Self.diag.notice("[SharedLogWriter] init ok pid=\(self.pid, privacy: .public) process=\(self.processName, privacy: .public) uid=\(getuid(), privacy: .public) fd=\(opened, privacy: .public) path=\(path, privacy: .public)")
            } else {
                let err = errno
                Self.diag.error("[SharedLogWriter] open failed pid=\(self.pid, privacy: .public) process=\(self.processName, privacy: .public) uid=\(getuid(), privacy: .public) errno=\(err, privacy: .public) path=\(path, privacy: .public)")
            }
        } else {
            self.fd = -1
            Self.diag.error("[SharedLogWriter] init failed pid=\(self.pid, privacy: .public) process=\(self.processName, privacy: .public) uid=\(getuid(), privacy: .public): unable to resolve logs path")
        }
    }

    /// Resolves the path the writer should open. System extensions run as `root` (uid 0),
    /// and `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` then resolves
    /// against `/var/root/...` instead of the user's home — which is a different file from
    /// what the host app opens. When that happens, we instead construct the path manually
    /// against the active console user's home so all three processes (host + 2 extensions)
    /// converge on the same inode. Root has unix-permission override, so writing into the
    /// user's container succeeds even from inside the system extension.
    private static func resolvedLogsPath() -> String? {
        if getuid() != 0 {
            return SharedPaths.logsFileURL()?.path
        }
        var uid: uid_t = 0
        guard let userCF = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) else { return nil }
        let user = userCF as String
        guard !user.isEmpty, user != "loginwindow" else { return nil }
        return "/Users/\(user)/Library/Group Containers/\(AppConstants.appGroupID)/logs.ndjson"
    }

    func append(subsystem: String, category: String, level: String, message: String) {
        guard fd >= 0 else { return }
        let line = makeLine(subsystem: subsystem, category: category, level: level, message: message)
        line.withCString { ptr in
            let len = Int(strlen(ptr))
            lock.lock()
            _ = Darwin.write(fd, ptr, len)
            lock.unlock()
        }
    }

    /// Truncate the shared log file. Safe to call from any process; other writers' O_APPEND
    /// FDs simply continue appending at the new end-of-file.
    func truncateFile() {
        guard fd >= 0 else { return }
        lock.lock()
        flock(fd, LOCK_EX)
        ftruncate(fd, 0)
        flock(fd, LOCK_UN)
        lock.unlock()
    }

    private func makeLine(subsystem: String, category: String, level: String, message: String) -> String {
        let ts = Self.cachedFormatter.string(from: Date())
        return "{\"ts\":\"\(ts)\",\"subsystem\":\"\(escape(subsystem))\",\"category\":\"\(escape(category))\",\"level\":\"\(level)\",\"pid\":\(pid),\"process\":\"\(escape(processName))\",\"message\":\"\(escape(message))\"}\n"
    }

    private func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }

    private static let cachedFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
