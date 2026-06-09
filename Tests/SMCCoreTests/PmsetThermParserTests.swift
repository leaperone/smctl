import XCTest
@testable import SMCCore

final class PmsetThermParserTests: XCTestCase {
    func testIdleMacReportsNotRecorded() {
        let output = """
        Note: No thermal warning level has been recorded
        Note: No performance warning level has been recorded
        Note: No CPU power status has been recorded
        """
        let status = PmsetThermParser.parse(output)
        XCTAssertFalse(status.recorded)
        XCTAssertNil(status.speedLimitPercent)
        XCTAssertFalse(status.isThrottled)
    }

    func testParsesThrottledOutput() {
        let output = """
        CPU_Scheduler_Limit \t= 80
        CPU_Available_CPUs \t= 8
        CPU_Speed_Limit \t= 72
        """
        let status = PmsetThermParser.parse(output)
        XCTAssertTrue(status.recorded)
        XCTAssertEqual(status.speedLimitPercent, 72)
        XCTAssertEqual(status.schedulerLimitPercent, 80)
        XCTAssertEqual(status.availableCPUs, 8)
        XCTAssertTrue(status.isThrottled)
    }

    func testFullSpeedIsNotThrottled() {
        let output = "CPU_Speed_Limit = 100"
        let status = PmsetThermParser.parse(output)
        XCTAssertTrue(status.recorded)
        XCTAssertEqual(status.speedLimitPercent, 100)
        XCTAssertFalse(status.isThrottled)
    }

    func testToleratesVariedSpacingAndTrailingText() {
        let output = "  CPU_Speed_Limit  =  55 %  \n  CPU_Available_CPUs=10\n"
        let status = PmsetThermParser.parse(output)
        XCTAssertEqual(status.speedLimitPercent, 55)
        XCTAssertEqual(status.availableCPUs, 10)
    }

    func testEmptyOutputIsNotRecorded() {
        let status = PmsetThermParser.parse("")
        XCTAssertFalse(status.recorded)
    }
}

final class PowerReaderTests: XCTestCase {
    func testSnapshotComposesInjectedSources() {
        let backend = StubBackend(values: [
            "PDTR": 18.4,
            "VD0R": 20.1,
            "ID0R": 1.1
        ])
        let reader = PowerReader(
            backend: backend,
            thermalStateProvider: { .serious },
            pmsetThermProvider: { "CPU_Speed_Limit = 72\nCPU_Available_CPUs = 8" },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let snapshot = reader.snapshot()
        XCTAssertEqual(snapshot.thermalPressure, .serious)
        XCTAssertEqual(snapshot.cpu.speedLimitPercent, 72)
        XCTAssertEqual(snapshot.packagePowerWatts!, 18.4, accuracy: 0.001)
        XCTAssertEqual(snapshot.inputVoltage!, 20.1, accuracy: 0.001)
        XCTAssertEqual(snapshot.inputCurrent!, 1.1, accuracy: 0.001)
        XCTAssertEqual(snapshot.inputPowerWatts!, 22.11, accuracy: 0.01)
    }

    func testMissingPmsetDegradesToNotRecorded() {
        let reader = PowerReader(
            backend: StubBackend(values: [:]),
            thermalStateProvider: { .nominal },
            pmsetThermProvider: { nil }
        )
        let snapshot = reader.snapshot()
        XCTAssertFalse(snapshot.cpu.recorded)
        XCTAssertNil(snapshot.packagePowerWatts)
        XCTAssertNil(snapshot.inputPowerWatts)
    }
}

/// Minimal SMCBackend stub returning canned numeric values as little-endian flt bytes.
private struct StubBackend: SMCBackend {
    var values: [String: Double]

    private var floatInfo: SMCKeyInfo {
        SMCKeyInfo(dataSize: 4, dataType: FourCharCode.unchecked("flt "), dataAttributes: 0)
    }

    func readKeyInfo(_ key: String) throws -> SMCKeyInfo {
        guard values[key] != nil else { throw SMCError.notFound }
        return floatInfo
    }

    func readValue(_ key: String) throws -> SMCReadValue {
        guard let value = values[key] else { throw SMCError.notFound }
        var float = Float(value)
        let bytes = withUnsafeBytes(of: &float) { Array($0) }
        return SMCReadValue(key: key, info: floatInfo, bytes: bytes)
    }
}
