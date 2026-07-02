import Foundation
import OSLog

struct LogEntry: Identifiable {
    let id: UUID = UUID()
    let date: Date
    let subsystem: String
    let category: String
    let level: String
    let process: String
    let pid: Int
    let message: String

    init(from entry: OSLogEntryLog) {
        self.date = entry.date
        self.subsystem = entry.subsystem
        self.category = entry.category
        self.level = Self.levelString(entry.level)
        self.process = entry.process
        self.pid = Int(entry.processIdentifier)
        self.message = entry.composedMessage
    }

    private static func levelString(_ level: OSLogEntryLog.Level) -> String {
        if level == .debug { return "debug" }
        if level == .info { return "info" }
        if level == .notice { return "notice" }
        if level == .error { return "error" }
        if level == .fault { return "fault" }
        return "notice"
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var timestamp: String {
        Self.timestampFormatter.string(from: date)
    }

    var exportLine: String {
        let ts = Self.isoFormatter.string(from: date)
        return "[\(ts)] [\(process):\(pid)] [\(subsystem)] [\(category)] [\(level)] \(message)"
    }
}

/// Reads logs from the unified log store and presents them to `LogsView`.
///
/// **Why `OSLogStore.local()` rather than a shared file**: System extensions on macOS run as
/// `root` with a much stricter sandbox profile than the host app — they cannot write to the
/// user's app-group container (open() returns EPERM), and the host (running as the user)
/// cannot read root's app-group container at `/var/root/...`. There is no filesystem path
/// both processes can share. The unified log store, on the other hand, is a system-managed
/// database that holds entries from every process; an unprivileged reader in the host app
/// can read entries emitted by processes running as other uids, as long as the entries are
/// public (which every call in this codebase is, via `AppLog` forwarding `privacy: .public`).
///
/// **Predicate choice**: `BEGINSWITH` works (verified by the user's `log stream` command).
/// An `IN [array]` predicate appears unsupported by OSLog's predicate evaluator and silently
/// returns zero entries — the cause of the original "constantly empty" Logs tab.
@MainActor
final class LogCaptureStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []

    private var nextFetchDate: Date
    private var pollingTask: Task<Void, Never>?

    nonisolated static let subsystemPrefix = "com.tunnelbahn.mac"
    private static let maxEntries = 10_000
    /// Native `os.Logger` used for the store's own diagnostics so problems are visible in
    /// `log stream` even when the store itself isn't surfacing anything.
    nonisolated static let diag = Logger(subsystem: "com.tunnelbahn.mac.sharedlog", category: "LogCaptureStore")

    init() {
        // Backdate by 30 seconds so any entries emitted during the host app's cold-launch
        // sequence (before AppState.init runs) are still captured. The OSLog store is
        // historical, so this just adjusts the starting cursor — we don't replay arbitrary
        // amounts of past data.
        self.nextFetchDate = Date().addingTimeInterval(-30)
        startPolling()
    }

    func clear() {
        entries = []
        nextFetchDate = Date()
    }

    var allText: String {
        entries.map(\.exportLine).joined(separator: "\n")
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            await self?.fetchNewEntries(isFirstFetch: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await self?.fetchNewEntries(isFirstFetch: false)
            }
        }
    }

    private func fetchNewEntries(isFirstFetch: Bool) async {
        let sinceDate = nextFetchDate

        let (newEntries, errorDescription): ([LogEntry], String?) = await Task.detached(priority: .utility) {
            do {
                let store = try OSLogStore.local()
                let position = store.position(date: sinceDate)
                let predicate = NSPredicate(format: "subsystem BEGINSWITH %@", Self.subsystemPrefix)
                let sequence = try store.getEntries(at: position, matching: predicate)
                var results: [LogEntry] = []
                for entry in sequence {
                    guard let logEntry = entry as? OSLogEntryLog else { continue }
                    results.append(LogEntry(from: logEntry))
                }
                return (results, nil)
            } catch {
                return ([], error.localizedDescription)
            }
        }.value

        if let errorDescription {
            Self.diag.error("[LogCaptureStore] fetch error: \(errorDescription, privacy: .public)")
        }

        if isFirstFetch {
            Self.diag.notice("[LogCaptureStore] initial fetch from=\(sinceDate, privacy: .public) returned=\(newEntries.count, privacy: .public)")
        }

        guard !newEntries.isEmpty else { return }

        if let lastDate = newEntries.last?.date {
            nextFetchDate = lastDate.addingTimeInterval(0.001)
        }

        var combined = entries + newEntries
        if combined.count > Self.maxEntries {
            combined.removeFirst(combined.count - Self.maxEntries)
        }
        entries = combined
    }
}
