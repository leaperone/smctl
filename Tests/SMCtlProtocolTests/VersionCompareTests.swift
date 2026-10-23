import XCTest
@testable import SMCtlProtocol

final class VersionCompareTests: XCTestCase {
    func testAdapterRequestsRemainCompatibleWithOlderClients() throws {
        let legacy = try SMCtlProtocolCoding.decode(SetEnabledRequestDTO.self, from: Data(#"{"enabled":false}"#.utf8))
        XCTAssertEqual(legacy, SetEnabledRequestDTO(enabled: false))
        let request = SetEnabledRequestDTO(enabled: false, dischargeTarget: 40)
        XCTAssertEqual(try SMCtlProtocolCoding.decode(SetEnabledRequestDTO.self, from: SMCtlProtocolCoding.encode(request)), request)
    }

    func testOldBatteryStatusDoesNotAdvertiseSupervisedDischarge() throws {
        let data = Data(#"{"timestamp":"2026-06-08T00:00:00Z","chargingControlSupported":true,"adapterControlSupported":true,"configuredLimit":"100","lowerBound":100,"upperBound":100,"sleepPolicy":"strict"}"#.utf8)
        let status = try SMCtlProtocolCoding.decode(BatteryStatusDTO.self, from: data)
        XCTAssertNil(status.foregroundDischargeSupported)
        XCTAssertTrue(status.adapterControlSupported)
    }

    func testNewerDetection() {
        XCTAssertTrue(SMCtlProtocolInfo.isVersion("0.1.7", newerThan: "0.1.6"))
        XCTAssertTrue(SMCtlProtocolInfo.isVersion("0.2.0", newerThan: "0.1.9"))
        XCTAssertTrue(SMCtlProtocolInfo.isVersion("1.0.0", newerThan: "0.9.9"))
        XCTAssertTrue(SMCtlProtocolInfo.isVersion("v0.1.7", newerThan: "0.1.6"), "leading v tolerated")
        XCTAssertTrue(SMCtlProtocolInfo.isVersion("0.1.10", newerThan: "0.1.9"), "numeric not lexical")
    }

    func testNotNewer() {
        XCTAssertFalse(SMCtlProtocolInfo.isVersion("0.1.6", newerThan: "0.1.6"), "equal is not newer")
        XCTAssertFalse(SMCtlProtocolInfo.isVersion("0.1.5", newerThan: "0.1.6"))
        XCTAssertFalse(SMCtlProtocolInfo.isVersion("0.1.6", newerThan: "0.1.6.0"), "trailing zero equal")
    }

    func testGarbageFailsClosed() {
        XCTAssertFalse(SMCtlProtocolInfo.isVersion("garbage", newerThan: "0.1.6"))
        XCTAssertFalse(SMCtlProtocolInfo.isVersion("0.1.x", newerThan: "0.1.6"))
        XCTAssertFalse(SMCtlProtocolInfo.isVersion("", newerThan: "0.1.6"))
    }

    func testPingDTOBackwardCompatibleDecode() throws {
        let json = Data(#"{"ok":true,"version":"0.1.5","timestamp":"2026-06-08T00:00:00Z"}"#.utf8)
        let ping = try SMCtlProtocolCoding.decode(PingDTO.self, from: json)
        XCTAssertNil(ping.latestVersion)
        XCTAssertEqual(ping.version, "0.1.5")
    }
}
