import XCTest
@testable import PhorganizeCore

final class OrganizationOptionsTests: XCTestCase {
    func testDecodingOldOptionsWithoutTimezoneIdentifierUsesOffsetFallback() throws {
        let json = """
        {
          "recursive": true,
          "includeCameraFolder": false,
          "renameByDate": false,
          "extensionCase": "lower",
          "operationMode": "move",
          "timezoneOffsetHours": 9,
          "metadataConcurrency": 3,
          "copyConcurrency": 2
        }
        """.data(using: .utf8)!

        let options = try JSONDecoder().decode(OrganizationOptions.self, from: json)

        XCTAssertTrue(options.recursive)
        XCTAssertFalse(options.includeCameraFolder)
        XCTAssertFalse(options.includeLensFolder)
        XCTAssertFalse(options.renameByDate)
        XCTAssertEqual(options.extensionCase, .lower)
        XCTAssertEqual(options.operationMode, .move)
        XCTAssertEqual(options.timeZone.secondsFromGMT(), 9 * 3_600)
        XCTAssertEqual(options.metadataConcurrency, 3)
        XCTAssertEqual(options.copyConcurrency, 2)
    }

    func testEncodingAndDecodingTimezoneIdentifier() throws {
        let options = OrganizationOptions(timezoneIdentifier: "America/Los_Angeles")
        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(OrganizationOptions.self, from: data)

        XCTAssertEqual(decoded.timezoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(decoded.timeZone.identifier, "America/Los_Angeles")
    }

    func testExplicitOffsetIsIndependentOfCurrentTimezone() throws {
        for hours in [-12, 0, 9, 14] {
            let options = OrganizationOptions(timezoneOffsetHours: hours)
            XCTAssertEqual(options.timeZone.secondsFromGMT(), hours * 3_600)
            let decoded = try JSONDecoder().decode(OrganizationOptions.self, from: JSONEncoder().encode(options))
            XCTAssertEqual(decoded.timeZone, options.timeZone)
        }
    }

    func testExplicitIdentifierTakesPrecedenceAndPreservesFractionalOffsets() throws {
        for (identifier, offset) in [("Asia/Kolkata", 19_800), ("Asia/Kathmandu", 20_700)] {
            let options = OrganizationOptions(timezoneOffsetHours: 9, timezoneIdentifier: identifier)
            XCTAssertEqual(options.timeZone.secondsFromGMT(), offset)
            let decoded = try JSONDecoder().decode(OrganizationOptions.self, from: JSONEncoder().encode(options))
            XCTAssertEqual(decoded.timeZone.identifier, identifier)
        }
    }

    func testNamedTimezoneUsesDaylightSavingAndDefaultsUseCurrentZone() {
        let options = OrganizationOptions(timezoneIdentifier: "America/Los_Angeles")
        XCTAssertEqual(options.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: 1_736_942_400)), -28_800)
        XCTAssertEqual(options.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: 1_752_580_800)), -25_200)
        XCTAssertEqual(OrganizationOptions().timeZone, .current)
    }

    func testOutOfRangeLegacyOffsetDoesNotOverflow() throws {
        let json = Data("{\"timezoneOffsetHours\":\(Int.max)}".utf8)
        let decoded = try JSONDecoder().decode(OrganizationOptions.self, from: json)
        XCTAssertEqual(decoded.timeZone, .current)
    }
}
