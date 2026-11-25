import Darwin
import XCTest
import SMCtlProtocol
@testable import SMCtlClient

final class PulseSystemInfoTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "pulse-launchdaemons-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func install(_ label: String) {
        FileManager.default.createFile(atPath: "\(directory!)/\(label).plist", contents: Data())
    }

    func testNothingInstalledNothingRunning() {
        XCTAssertEqual(FanControlConflicts.detect(launchDaemonsDirectory: directory, runningProcesses: ["Finder"]), [])
    }

    func testInstalledHelperIsReportedAndRunningStateComesFromProcesses() {
        install("com.tunabellysoftware.TGFanHelper")
        let idle = FanControlConflicts.detect(launchDaemonsDirectory: directory, runningProcesses: [])
        XCTAssertEqual(idle.map(\.product), ["TG Pro"])
        XCTAssertFalse(idle[0].running)
        XCTAssertTrue(idle[0].evidence.hasSuffix("com.tunabellysoftware.TGFanHelper.plist"))

        let running = FanControlConflicts.detect(launchDaemonsDirectory: directory, runningProcesses: ["TG Pro"])
        XCTAssertTrue(running[0].running)
    }

    func testRunningAppWithoutHelperIsReported() {
        let conflicts = FanControlConflicts.detect(launchDaemonsDirectory: directory, runningProcesses: ["Macs Fan Control"])
        XCTAssertEqual(conflicts, [FanControlConflict(product: "Macs Fan Control", evidence: "process Macs Fan Control", running: true)])
    }

    func testOwnDaemonIsNeverAConflict() {
        install("one.leaper.smctl.daemon")
        XCTAssertEqual(FanControlConflicts.detect(launchDaemonsDirectory: directory, runningProcesses: [], ownLabel: "one.leaper.smctl.daemon"), [])
        XCTAssertEqual(FanControlConflicts.detect(launchDaemonsDirectory: directory, runningProcesses: [], ownLabel: "com.example.other").map(\.product), ["smctl"])
    }

    func testProcessListIncludesThisProcess() {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        XCTAssertGreaterThan(proc_name(getpid(), &buffer, UInt32(buffer.count)), 0)
        let ownName = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        XCTAssertTrue(FanControlConflicts.runningProcessNames().contains(ownName))
    }

    func testSensorGroupLabels() {
        XCTAssertEqual(SensorGroups.label(for: "Tp"), "CPU")
        XCTAssertEqual(SensorGroups.label(for: "Tg"), "GPU")
        XCTAssertEqual(SensorGroups.label(for: "Qx"), "Qx")
        XCTAssertLessThan(SensorGroups.sortKey(for: "Tp"), SensorGroups.sortKey(for: "Ts"))
        XCTAssertEqual(SensorGroups.pattern(for: "Tp"), "Tp*")
    }
}

final class TemperatureGroupSummaryTests: XCTestCase {
    func testPoweredDownSensorsAreExcludedButCounted() {
        let summaries = TemperatureGroupSummary.summarize([
            TemperatureDTO(key: "Tg0C", group: "Tg", celsius: 0.8),
            TemperatureDTO(key: "Tg0D", group: "Tg", celsius: 36),
            TemperatureDTO(key: "Tg0H", group: "Tg", celsius: 34),
            TemperatureDTO(key: "Tp01", group: "Tp", celsius: 50),
            TemperatureDTO(key: "Ts00", group: "Ts", celsius: -0.5)
        ])
        XCTAssertEqual(summaries.map(\.label), ["CPU", "GPU", "Board"])
        let gpu = summaries[1]
        XCTAssertEqual(gpu.averageCelsius, 35)
        XCTAssertEqual(gpu.maximumCelsius, 36)
        XCTAssertEqual(gpu.hottestKey, "Tg0D")
        XCTAssertEqual(gpu.count, 3)
        XCTAssertEqual(gpu.inactiveCount, 1)
        let board = summaries[2]
        XCTAssertNil(board.averageCelsius)
        XCTAssertNil(board.maximumCelsius)
        XCTAssertEqual(board.inactiveCount, 1)
    }
}
