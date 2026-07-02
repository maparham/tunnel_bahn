import Foundation
import OSLog

/// Drop-in replacement for `os.Logger` that fans every log call out to both:
///   1. The standard unified-logging system (via `os.Logger`), preserving Console.app
///      visibility and existing diagnostic workflows.
///   2. `SharedLogWriter`, which persists each entry to a shared file in the app-group
///      container so the host app's in-process `LogCaptureStore` can surface logs from
///      sibling system-extension processes (which are otherwise opaque to the host's
///      `OSLogStore.local()` due to App Sandbox boundaries).
///
/// All messages forward with `privacy: .public` since the in-app Logs view shows raw text
/// either way — there is no privacy benefit to redacting them in Console while leaving them
/// visible to the user.
struct AppLog {
    let subsystem: String
    let category: String
    private let osLogger: Logger

    init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        self.osLogger = Logger(subsystem: subsystem, category: category)
    }

    func debug(_ message: @autoclosure () -> String) {
        let m = message()
        osLogger.debug("\(m, privacy: .public)")
        SharedLogWriter.shared.append(subsystem: subsystem, category: category, level: "debug", message: m)
    }

    func info(_ message: @autoclosure () -> String) {
        let m = message()
        osLogger.info("\(m, privacy: .public)")
        SharedLogWriter.shared.append(subsystem: subsystem, category: category, level: "info", message: m)
    }

    func notice(_ message: @autoclosure () -> String) {
        let m = message()
        osLogger.notice("\(m, privacy: .public)")
        SharedLogWriter.shared.append(subsystem: subsystem, category: category, level: "notice", message: m)
    }

    func warning(_ message: @autoclosure () -> String) {
        let m = message()
        osLogger.warning("\(m, privacy: .public)")
        SharedLogWriter.shared.append(subsystem: subsystem, category: category, level: "warning", message: m)
    }

    func error(_ message: @autoclosure () -> String) {
        let m = message()
        osLogger.error("\(m, privacy: .public)")
        SharedLogWriter.shared.append(subsystem: subsystem, category: category, level: "error", message: m)
    }

    func critical(_ message: @autoclosure () -> String) {
        let m = message()
        osLogger.critical("\(m, privacy: .public)")
        SharedLogWriter.shared.append(subsystem: subsystem, category: category, level: "critical", message: m)
    }

    func fault(_ message: @autoclosure () -> String) {
        let m = message()
        osLogger.fault("\(m, privacy: .public)")
        SharedLogWriter.shared.append(subsystem: subsystem, category: category, level: "fault", message: m)
    }

    /// `Logger.log(_:)` shorthand (default level → notice).
    func log(_ message: @autoclosure () -> String) {
        let m = message()
        osLogger.log("\(m, privacy: .public)")
        SharedLogWriter.shared.append(subsystem: subsystem, category: category, level: "notice", message: m)
    }

    func log(level: OSLogType, _ message: @autoclosure () -> String) {
        let m = message()
        osLogger.log(level: level, "\(m, privacy: .public)")
        SharedLogWriter.shared.append(
            subsystem: subsystem,
            category: category,
            level: Self.levelName(for: level),
            message: m
        )
    }

    private static func levelName(for level: OSLogType) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .default: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "notice"
        }
    }
}
