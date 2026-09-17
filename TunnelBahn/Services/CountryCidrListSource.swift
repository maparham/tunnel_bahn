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
enum CountryCidrListSource {
    static let baseURL = URL(string: "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/")!

    /// URL of the aggregated IPv4 file for `code` (case-insensitive ISO alpha-2).
    static func url(forCountryCode code: String) -> URL {
        baseURL.appending(path: "\(code.lowercased())/ipv4-aggregated.txt")
    }

    /// Every ISO region Foundation knows, sorted by localized name. Built from `Locale` so there
    /// is no hand-maintained country table; codes that are not two-letter countries (e.g. "001"
    /// for World, "150" for Europe) are dropped.
    static func allCountries(locale: Locale = .current) -> [CountryCidrListEntry] {
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .compactMap { code -> CountryCidrListEntry? in
                guard let name = locale.localizedString(forRegionCode: code) else { return nil }
                return CountryCidrListEntry(code: code.uppercased(), name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    enum FetchError: LocalizedError {
        case httpStatus(Int)
        case notText

        var errorDescription: String? {
            switch self {
            case .httpStatus(404):
                return "No list is published for this country."
            case .httpStatus(let code):
                return "The list server answered with HTTP \(code)."
            case .notText:
                return "The downloaded list was not readable text."
            }
        }
    }

    /// Downloads the list text for `code`. Errors are surfaced as-is; the sheet adds the
    /// "connect the tunnel first" hint for network failures.
    static func fetchListText(forCountryCode code: String, session: URLSession = .shared) async throws -> String {
        let (data, response) = try await session.data(from: url(forCountryCode: code))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.httpStatus(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw FetchError.notText
        }
        return text
    }
}
