import XCTest
@testable import smctl

final class FanIntervalTests: XCTestCase {
    func testParsing() throws {
        XCTAssertEqual(try FanInterval.parse(["3"]).parsed, .some(3))
        XCTAssertEqual(try FanInterval.parse(["same", "--on-battery"]).parsed, .some(nil))
        XCTAssertNil(try FanInterval.parse([]).parsed, "no argument shows the values")
        XCTAssertThrowsError(try FanInterval.parse(["same"]), "\"same\" only applies on battery")
        XCTAssertThrowsError(try FanInterval.parse(["6"]))
        XCTAssertThrowsError(try FanInterval.parse(["0", "--on-battery"]))
    }

    func testDescription() {
        XCTAssertEqual(FanInterval.describe(adapter: 2, battery: nil, onBattery: true), "Sensors are read every 2 s.")
        XCTAssertEqual(FanInterval.describe(adapter: 1, battery: 5, onBattery: true),
                       "Sensors are read every 1 s on the adapter and every 5 s on battery (on battery now).")
    }
}
