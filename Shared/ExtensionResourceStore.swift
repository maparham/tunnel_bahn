import Foundation

/// File-backed merge point for `ExtensionResourceStats`: each extension read-modifies-writes
/// its own fields using atomic writes.
enum ExtensionResourceStore {
    private static let filename = "extension-resource-stats.json"

    static func fileURL() -> URL? {
        SharedPaths.appGroupContainer()?.appendingPathComponent(filename)
    }

    static func write(_ stats: ExtensionResourceStats) throws {
        guard let destination = fileURL() else {
            throw NSError(
                domain: "TunnelBahn.ExtensionResourceStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable for extension resource stats."]
            )
        }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(stats)

        try data.write(to: destination, options: [.atomic])
    }

    static func read() -> ExtensionResourceStats {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url)
        else {
            return .empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ExtensionResourceStats.self, from: data) else {
            return .empty
        }
        guard decoded.schemaVersion == ExtensionResourceStats.currentSchemaVersion else {
            return .empty
        }
        return decoded
    }

    static func reset() {
        guard let url = fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
