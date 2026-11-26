import XCTest
import SMCCore
import SMCtlClient
import SMCtlProtocol
@testable import smctl

final class DoctorTests: XCTestCase {
    private func report(
        daemonRunning: Bool = true,
        daemonVersion: String? = "0.2.4",
        fans: [DoctorReport.Fan] = [DoctorReport.Fan(index: 0, modeKey: "F0Md", minimumRPM: 1200, maximumRPM: 5779, actualRPM: 0, mode: "auto")],
        chargingControl: String? = nil,
        batteryReadable: Bool = true,
        conflicts: [FanControlConflict] = [],
        latched: Bool = false
    ) -> DoctorReport {
        DoctorReport(
            timestamp: Date(timeIntervalSince1970: 0),
            machine: .init(model: "MacBookPro18,3", chip: "Apple M1 Pro", macOS: "27.2.1", memoryGB: 16),
            daemon: .init(running: daemonRunning, version: daemonRunning ? daemonVersion : nil, cliVersion: "0.2.4",
                          profile: daemonRunning ? "balanced" : nil, configPath: nil, lastError: nil,
                          message: daemonRunning ? nil : "connection refused"),
            smc: .init(readable: true, message: nil, fans: fans, ftstAvailable: false, expectedUnlockPath: fans.isEmpty ? "none" : "direct",
                       chargingControl: chargingControl, adapterControl: nil, batteryReadable: batteryReadable,
                       temperatureGroups: ["Tp": 14, "Tg": 4]),
            safety: daemonRunning ? SafetyStateDTO(latched: latched, ceilingCelsius: 100, lastTripReason: latched ? "Tp0E 112 °C" : nil, allowsStoppingFans: false) : nil,
            conflicts: conflicts
        )
    }

    private func level(_ name: String, in checks: [DoctorCheck]) -> DoctorCheck.Level? {
        checks.first { $0.name == name }?.level
    }

    func testHealthyMacBookHasNoProblems() {
        let checks = DoctorCheck.evaluate(report())
        XCTAssertFalse(checks.contains { $0.level == .problem || $0.level == .warning }, "\(checks)")
        XCTAssertEqual(level("fans", in: checks), .ok)
        XCTAssertEqual(level("battery", in: checks), .info, "no charging control is informational, not a fault")
    }

    func testFanlessMacIsMonitoringOnlyNotAProblem() {
        let checks = DoctorCheck.evaluate(report(fans: []))
        XCTAssertEqual(level("fans", in: checks), .info)
        XCTAssertTrue(checks.first { $0.name == "fans" }?.detail.contains("fanless") ?? false)
    }

    func testFansWithoutModeKeyAreAProblem() {
        let checks = DoctorCheck.evaluate(report(fans: [DoctorReport.Fan(index: 0, modeKey: nil, minimumRPM: 1200, maximumRPM: 5000, actualRPM: 0, mode: nil)]))
        XCTAssertEqual(level("fans", in: checks), .problem)
    }

    func testDaemonDownAndVersionMismatch() {
        XCTAssertEqual(level("daemon", in: DoctorCheck.evaluate(report(daemonRunning: false))), .problem)
        XCTAssertEqual(level("versions", in: DoctorCheck.evaluate(report(daemonVersion: "0.2.3"))), .warning)
    }

    func testConflictsAndLatchedSafety() {
        let running = FanControlConflict(product: "TG Pro", evidence: "process TG Pro", running: true)
        let installed = FanControlConflict(product: "Stats", evidence: "/Library/LaunchDaemons/x.plist", running: false)
        let checks = DoctorCheck.evaluate(report(conflicts: [running, installed], latched: true))
        XCTAssertEqual(checks.filter { $0.name == "conflict" }.map(\.level), [.problem, .warning])
        XCTAssertEqual(level("safety", in: checks), .warning)
    }

    func testUnlockPathFollowsFtstPresence() {
        let fan = FanCapability(index: 0, actualKey: "F0Ac", targetKey: "F0Tg", minimumKey: "F0Mn", maximumKey: "F0Mx", modeKey: "F0Md")
        XCTAssertEqual(DoctorReport.SMC.unlockPath(fans: [fan], ftstAvailable: false), "direct")
        XCTAssertEqual(DoctorReport.SMC.unlockPath(fans: [fan], ftstAvailable: true), "direct, Ftst fallback")
        XCTAssertEqual(DoctorReport.SMC.unlockPath(fans: [], ftstAvailable: true), "none")
    }

    func testFanTestSettlingAndResult() {
        XCTAssertTrue(FanWriteTest.settled(actual: 3000, target: 3032))
        XCTAssertFalse(FanWriteTest.settled(actual: 2500, target: 3032))
        XCTAssertFalse(FanWriteTest.settled(actual: nil, target: 3032))
        XCTAssertTrue(FanWriteTest.settled(actual: 1150, target: 1200), "small targets get the 100 RPM floor")

        let ok = FanWriteTest.Result(fans: [.init(index: 0, targetRPM: 3000, reachedRPM: 3010, secondsToSettle: 4)], restoredProfile: "balanced", error: nil)
        XCTAssertTrue(ok.passed)
        let slow = FanWriteTest.Result(fans: [.init(index: 0, targetRPM: 3000, reachedRPM: 1800, secondsToSettle: nil)], restoredProfile: "balanced", error: nil)
        XCTAssertFalse(slow.passed)
        XCTAssertEqual(level("fan write test", in: DoctorCheck.evaluate({ var r = report(); r.fanTest = slow; return r }())), .problem)
    }

    func testJSONRoundTrip() throws {
        let original = report()
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(DoctorReport.self, from: data), original)
    }
}
