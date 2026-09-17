import XCTest

final class CountryCidrListSourceTests: XCTestCase {

    // MARK: - Country code validation (security boundary)

    func testURLUsesLowercasedCodeAndAggregatedIPv4File() {
        let url = CountryCidrListSource.url(forCountryCode: "IR")
        XCTAssertEqual(
            url?.absoluteString,
            "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ir/ipv4-aggregated.txt"
        )
    }

    /// `URL.appending(path:)` does not encode "/" and URLSession resolves ".." before sending,
    /// so an unvalidated code escapes the repository and fetches an arbitrary file from the
    /// host. Codes can arrive from persisted data (a restored backup), not just the picker.
    func testTraversalAndJunkCodesProduceNoURL() {
        let hostile = [
            "../../../../attacker/repo/master/evil",
            "ir/../../../../attacker/repo/master/evil",
            "..",
            "/",
            "i/r",
            "i r",
            "",
            "I",
            "IRN",
            "i\u{0301}",
            "İR",
            "1R",
            "%2e%2e",
        ]
        for code in hostile {
            XCTAssertNil(CountryCidrListSource.url(forCountryCode: code), "should reject \(code)")
            XCTAssertFalse(CountryCidrListSource.isValidCountryCode(code), "should reject \(code)")
        }
    }

    func testEveryPickerCodeIsAcceptedByTheValidator() {
        for entry in CountryCidrListSource.allCountries(locale: Locale(identifier: "en_US")) {
            XCTAssertTrue(CountryCidrListSource.isValidCountryCode(entry.code), entry.code)
            XCTAssertNotNil(CountryCidrListSource.url(forCountryCode: entry.code), entry.code)
        }
    }

    func testAllCountriesAreTwoLetterUppercaseSortedByName() {
        let countries = CountryCidrListSource.allCountries(locale: Locale(identifier: "en_US"))
        XCTAssertGreaterThan(countries.count, 200)
        let names = countries.map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertTrue(countries.contains(where: { $0.code == "IR" && $0.name == "Iran" }))
        XCTAssertFalse(countries.contains(where: { $0.code == "001" }))
    }

    func testBulkListTitle() {
        XCTAssertEqual(CountryCidrListEntry(code: "IR", name: "Iran").bulkListTitle, "Iran (IR)")
    }

    // MARK: - Prefix validation (these strings become routing rules)

    /// A default route matches every address. In exclude mode that sends all traffic outside
    /// the tunnel, so it must never survive validation whatever the server says.
    func testDefaultRoutesAreRejected() {
        XCTAssertFalse(CountryCidrListSource.isSafeIPv4Prefix("0.0.0.0/0"))
        XCTAssertFalse(CountryCidrListSource.isSafeIPv4Prefix("::/0"))
        XCTAssertEqual(CountryCidrListSource.validatedIPv4Prefixes(from: "0.0.0.0/0\n1.2.3.0/24"), ["1.2.3.0/24"])
    }

    func testIPv6AndMalformedEntriesAreRejected() {
        for bad in ["2001:db8::/32", "1.2.3.4/33", "1.2.3.4/-1", "1.2.3.256/24", "not-a-cidr", "1.2.3.4/abc"] {
            XCTAssertFalse(CountryCidrListSource.isSafeIPv4Prefix(bad), "should reject \(bad)")
        }
    }

    func testOrdinaryPrefixesAndHostRoutesAreAccepted() {
        for good in ["1.2.3.0/24", "10.0.0.0/8", "5.6.7.8/32", "5.6.7.8", "2.57.3.0/24"] {
            XCTAssertTrue(CountryCidrListSource.isSafeIPv4Prefix(good), "should accept \(good)")
        }
    }

    /// The failure that matters in the field: a captive portal or block page answering HTTP 200.
    func testBlockPageAndEmptyBodyYieldNoPrefixes() {
        let blockPage = """
        <html><head><title>Access Denied</title></head>
        <body><h1>This site is blocked</h1></body></html>
        """
        XCTAssertTrue(CountryCidrListSource.validatedIPv4Prefixes(from: blockPage).isEmpty)
        XCTAssertTrue(CountryCidrListSource.validatedIPv4Prefixes(from: "").isEmpty)
        XCTAssertTrue(CountryCidrListSource.validatedIPv4Prefixes(from: "# only a comment\n\n").isEmpty)
    }

    func testValidationDedupesAndCapsCount() {
        XCTAssertEqual(CountryCidrListSource.validatedIPv4Prefixes(from: "1.2.3.0/24\n1.2.3.0/24"), ["1.2.3.0/24"])
        let many = (0..<(CountryCidrListSource.maxPrefixes + 500))
            .map { "10.\($0 / 256 % 256).\($0 % 256).0/24" }
            .joined(separator: "\n")
        XCTAssertEqual(
            CountryCidrListSource.validatedIPv4Prefixes(from: many).count,
            CountryCidrListSource.maxPrefixes
        )
    }

    func testShippedIranFileValidatesToPrefixes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/iran-ipv4-cidrs.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        let prefixes = CountryCidrListSource.validatedIPv4Prefixes(from: text)
        XCTAssertGreaterThan(prefixes.count, 1000)
        XCTAssertFalse(prefixes.contains(where: { $0.hasPrefix("#") }))
        XCTAssertFalse(prefixes.contains("0.0.0.0/0"))
    }
}
