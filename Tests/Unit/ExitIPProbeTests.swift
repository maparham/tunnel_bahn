import XCTest
@testable import TunnelBahn

final class ExitIPProbeTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParseHappyPath() throws {
        let info = try XCTUnwrap(ExitIPProbe.parse(data(
            #"{"ip":"203.0.113.7","success":true,"city":"Frankfurt","region":"Hesse","country":"Germany"}"#
        )))
        XCTAssertEqual(info.ip, "203.0.113.7")
        XCTAssertEqual(info.location, "Frankfurt, Hesse, Germany")
    }

    func testParseKeepsIPWhenPlaceFieldsAreMissing() throws {
        let info = try XCTUnwrap(ExitIPProbe.parse(data(#"{"ip":"203.0.113.7","success":true}"#)))
        XCTAssertEqual(info.ip, "203.0.113.7")
        XCTAssertNil(info.location)
    }

    func testParseRejectsUnsuccessfulResponse() {
        XCTAssertNil(ExitIPProbe.parse(data(#"{"success":false,"message":"reserved range"}"#)))
    }

    func testParseRejectsMissingOrBlankIP() {
        XCTAssertNil(ExitIPProbe.parse(data(#"{"success":true,"city":"Frankfurt"}"#)))
        XCTAssertNil(ExitIPProbe.parse(data(#"{"success":true,"ip":"  "}"#)))
    }

    func testParseRejectsMalformedBody() {
        XCTAssertNil(ExitIPProbe.parse(data("not json")))
        XCTAssertNil(ExitIPProbe.parse(Data()))
    }

    func testFormatLocationSkipsBlankParts() {
        XCTAssertEqual(ExitIPProbe.formatLocation(city: "Tehran", region: "  ", country: "Iran"), "Tehran, Iran")
        XCTAssertNil(ExitIPProbe.formatLocation(city: nil, region: "", country: nil))
    }
}
