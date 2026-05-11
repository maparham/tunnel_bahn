import Foundation

/// Atomic file-backed transport for `PerAppTransferStats` shared between the host app
/// (reader) and the TransparentProxy extension (writer).
///
/// Concurrency model:
/// - Single writer assumed (the extension's flush timer). No explicit locks.
/// - Atomic temp-file + rename: a partial flush can never be observed by readers.
/// - Readers tolerate missing/corrupt files by returning `.empty`.
enum PerAppTransferStore {
    private static let filename = "per-app-stats.json"

    static func fileURL() -> URL? {
        SharedPaths.appGroupContainer()?.appendingPathComponent(filename)
    }

    /// Writes `stats` atomically. Safe to call from any thread; expected to run on the
    /// extension's flush queue (single-writer).
    static func write(_ stats: PerAppTransferStats) throws {
        guard let destination = fileURL() else {
            throw NSError(
                domain: "TunnelBahn.PerAppTransferStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable for app-tunnel stats."]
            )
        }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(stats)

        // `Data.write(options: .atomic)` already does temp+rename on Apple platforms,
        // so a partial write can never be observed.
        try data.write(to: destination, options: [.atomic])
    }

    /// Reads the latest stats. Returns `.empty` for any read or decode failure
    /// (missing file, JSON corruption, schema mismatch).
    static func read() -> PerAppTransferStats {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url)
        else {
            return .empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(PerAppTransferStats.self, from: data) else {
            return .empty
        }
        guard decoded.schemaVersion == PerAppTransferStats.currentSchemaVersion else {
            return .empty
        }
        return decoded
    }

    /// Clears any persisted app-tunnel stats. Called by `VPNManager` on disconnect so the UI
    /// resets in step with aggregate counters.
    static func reset() {
        guard let url = fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
