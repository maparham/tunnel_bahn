import Foundation

/// Public IP the internet sees for one process, plus where that IP geolocates.
struct ExitIPInfo: Equatable {
    let ip: String
    /// "City, Region, Country"; nil when the provider returns no usable place fields.
    let location: String?
}

/// One-shot lookup of the calling process's own exit IP and location.
///
/// Compiled into both the host app and SpeedTestHelper, so each process reports the exit of
/// the path it actually uses: the helper always carries the tunnel's NEAppRule, while the host
/// app stays on the direct path. That is what makes the Tunnel and Direct speed test cards able
/// to show different exits at the same time, even under a per-app split.
enum ExitIPProbe {
    /// Bare ipwho.is reports the caller's own address, so one request covers IP and geo.
    static let endpoint = URL(string: "https://ipwho.is/")!
    private static let timeoutSeconds: TimeInterval = 5

    private struct Response: Decodable {
        let success: Bool
        let ip: String?
        let city: String?
        let region: String?
        let country: String?
    }

    /// Never throws: an unreachable or slow provider yields nil, because a geo lookup must not
    /// fail an otherwise good measurement run.
    static func probe() async -> ExitIPInfo? {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeoutSeconds
        // Also cap total duration: the request timeout only bounds idle gaps, so a server
        // dripping bytes could otherwise hold the probe (and the speed test awaiting it) open
        // for the default 7-day resource timeout.
        config.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeoutSeconds
        guard let (data, _) = try? await session.data(for: request) else { return nil }
        return parse(data)
    }

    /// Pure decoder for the provider payload. Returns nil for a failure response, a missing
    /// address, or a body that is not the expected JSON.
    static func parse(_ data: Data) -> ExitIPInfo? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.success,
              let ip = response.ip?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty
        else { return nil }
        return ExitIPInfo(ip: ip, location: formatLocation(city: response.city, region: response.region, country: response.country))
    }

    /// Same "City, Region, Country" shape the connection view uses, so both places read alike.
    static func formatLocation(city: String?, region: String?, country: String?) -> String? {
        let parts = [city, region, country].compactMap { value -> String? in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
            else { return nil }
            return trimmed
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
