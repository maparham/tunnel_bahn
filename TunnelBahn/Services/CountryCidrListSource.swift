import Foundation

/// One country in the picker: ISO 3166-1 alpha-2 code plus its localized display name.
struct CountryCidrListEntry: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    /// Title given to the bulk list created from this country, e.g. "Iran (IR)".
    var bulkListTitle: String { "\(name) (\(code))" }
}

/// Downloads per-country IPv4 CIDR lists from the ipverse/rir-ip GitHub repository.
///
/// Each file is the RIR delegation data for one country, aggregated into as few prefixes as
/// possible, with `#` comment lines at the top — the same format as `docs/iran-ipv4-cidrs.txt`,
/// so `DestinationCidrTextParser` reads it unchanged.
///
/// Everything this type returns becomes a tunnel routing rule, so the download is treated as
/// untrusted input end to end: the country code is validated before it can shape a URL, the
/// body is size-capped, and every prefix is checked for meaning as well as syntax.
enum CountryCidrListSource {
    static let baseURL = URL(string: "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/")!

    /// Response body cap. The aggregated per-country files are tens of KB; none approaches this.
    static let maxResponseBytes = 8 << 20
    /// Cap on prefixes accepted from a single list.
    static let maxPrefixes = 65_536
    private static let requestTimeout: TimeInterval = 20

    /// Exactly two ASCII letters.
    ///
    /// This is a security boundary, not a tidiness check. `URL.appending(path:)` does not
    /// percent-encode "/" and URLSession resolves ".." segments before sending, so a code like
    /// "../../../../owner/repo/branch/file" walks out of the repository path and fetches an
    /// arbitrary file from the host — served over a valid certificate. Codes reach us from
    /// persisted data (a restored backup carries whatever `countryCode` the file contained),
    /// not only from the picker, so every use validates rather than trusting the source.
    static func isValidCountryCode(_ code: String) -> Bool {
        code.count == 2 && code.allSatisfy { $0.isASCII && $0.isLetter }
    }

    /// URL of the aggregated IPv4 file for `code`, or nil when `code` is not a country code.
    static func url(forCountryCode code: String) -> URL? {
        guard isValidCountryCode(code) else { return nil }
        return baseURL.appending(path: "\(code.lowercased())/ipv4-aggregated.txt")
    }

    /// Every ISO region Foundation knows, sorted by localized name. Built from `Locale` so there
    /// is no hand-maintained country table; codes that are not two-letter countries (e.g. "001"
    /// for World, "150" for Europe) are dropped.
    static func allCountries(locale: Locale = .current) -> [CountryCidrListEntry] {
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter(isValidCountryCode)
            .compactMap { code -> CountryCidrListEntry? in
                guard let name = locale.localizedString(forRegionCode: code) else { return nil }
                return CountryCidrListEntry(code: code.uppercased(), name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    enum FetchError: LocalizedError {
        case invalidCountryCode(String)
        case httpStatus(Int)
        case notText
        case tooLarge
        case noUsablePrefixes

        var errorDescription: String? {
            switch self {
            case .invalidCountryCode(let code):
                return "\"\(code)\" is not a valid two-letter country code."
            case .httpStatus(404):
                return "No list is published for this country."
            case .httpStatus(let code):
                return "The list server answered with HTTP \(code)."
            case .notText:
                return "The downloaded list was not readable text."
            case .tooLarge:
                return "The download was far too large to be a country list."
            case .noUsablePrefixes:
                return "The download contained no usable IPv4 ranges, so the existing list was kept. A captive portal or block page usually answers this way instead of GitHub."
            }
        }
    }

    /// Downloads and validates one country's list.
    ///
    /// Never returns an empty array: callers replace a stored list with whatever comes back, so
    /// an empty or unparsable body has to be an error rather than a successful wipe. The cache
    /// is bypassed because an explicit refresh that returns a five-minute-old cached body is
    /// not a refresh.
    static func fetchPrefixes(forCountryCode code: String, session: URLSession = .shared) async throws -> [String] {
        guard let url = url(forCountryCode: code) else {
            throw FetchError.invalidCountryCode(code)
        }
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout
        )
        request.setValue("text/plain", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.httpStatus(http.statusCode)
        }
        guard data.count <= maxResponseBytes else { throw FetchError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw FetchError.notText }

        let prefixes = validatedIPv4Prefixes(from: text)
        guard !prefixes.isEmpty else { throw FetchError.noUsablePrefixes }
        return prefixes
    }

    /// Keeps only the entries that are safe to use as routing rules, in file order.
    ///
    /// Syntactic validity is not enough. A default route (`/0`) matches every address, so one
    /// in an exclude list would push all traffic outside the tunnel — on a live session, since
    /// the extension unions pushed ranges. IPv6 entries are dropped because this is the IPv4
    /// export and an address family the caller never asked for has no business here.
    static func validatedIPv4Prefixes(from plainText: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for candidate in DestinationCidrTextParser.candidateStrings(from: plainText) {
            guard out.count < maxPrefixes else { break }
            guard !seen.contains(candidate), isSafeIPv4Prefix(candidate) else { continue }
            seen.insert(candidate)
            out.append(candidate)
        }
        return out
    }

    /// True for an IPv4 CIDR that is not a default route. A bare address (no "/") is a host
    /// route and is allowed.
    static func isSafeIPv4Prefix(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: "/", maxSplits: 1)
        guard let addressPart = parts.first.map(String.init) else { return false }
        var v4 = in_addr()
        guard inet_pton(AF_INET, addressPart, &v4) == 1 else { return false }
        if parts.count > 1 {
            guard let bits = Int(parts[1]), bits >= 1, bits <= 32 else { return false }
        }
        // Final gate through the same parser the extension uses, so nothing we store can
        // parse differently there than it does here.
        return !IPCIDRMatcher.prepare([candidate]).isEmpty
    }
}
