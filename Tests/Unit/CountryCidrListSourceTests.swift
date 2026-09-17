import XCTest

final class CountryCidrListSourceTests: XCTestCase {
    func testURLUsesLowercasedCodeAndAggregatedIPv4File() {
        let url = CountryCidrListSource.url(forCountryCode: "IR")
        XCTAssertEqual(
            url.absoluteString,
            "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ir/ipv4-aggregated.txt"
        )
    }

    func testAllCountriesAreTwoLetterUppercaseSortedByName() {
        let countries = CountryCidrListSource.allCountries(locale: Locale(identifier: "en_US"))
        XCTAssertGreaterThan(countries.count, 200)
        for c in countries {
            XCTAssertEqual(c.code.count, 2)
            XCTAssertEqual(c.code, c.code.uppercased())
            XCTAssertFalse(c.name.isEmpty)
        }
        let names = countries.map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertTrue(countries.contains(where: { $0.code == "IR" && $0.name == "Iran" }))
        XCTAssertFalse(countries.contains(where: { $0.code == "001" }))
    }

    func testBulkListTitle() {
        XCTAssertEqual(CountryCidrListEntry(code: "IR", name: "Iran").bulkListTitle, "Iran (IR)")
    }

    func testShippedIranFileParsesWithExistingParser() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/iran-ipv4-cidrs.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        let candidates = DestinationCidrTextParser.candidateStrings(from: text)
        XCTAssertGreaterThan(candidates.count, 1000)
        XCTAssertFalse(candidates.contains(where: { $0.hasPrefix("#") }))
    }
}
