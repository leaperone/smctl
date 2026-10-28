import XCTest
@testable import smctl

final class DDCLuminanceTests: XCTestCase {
    func testPercentToRawUsesDisplayRange() {
        XCTAssertEqual(DDCLuminance.rawValue(percent: 50, maximum: 100), 50)
        XCTAssertEqual(DDCLuminance.rawValue(percent: 50, maximum: 255), 128)
        XCTAssertEqual(DDCLuminance.rawValue(percent: 100, maximum: 255), 255)
        XCTAssertEqual(DDCLuminance.rawValue(percent: 0, maximum: 255), 0)
    }

    func testRawToPercentUsesDisplayRange() {
        XCTAssertEqual(DDCLuminance.percent(raw: 128, maximum: 255), 50)
        XCTAssertEqual(DDCLuminance.percent(raw: 50, maximum: 100), 50)
    }

    func testZeroOrNegativeRangeFallsBackToHundred() {
        XCTAssertEqual(DDCLuminance.rawValue(percent: 40, maximum: 0), 40)
        XCTAssertEqual(DDCLuminance.percent(raw: 40, maximum: 0), 40)
        XCTAssertEqual(DDCLuminance.percent(raw: 40, maximum: -1), 40)
    }
}
