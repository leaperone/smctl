import Foundation
import XCTest
@testable import SMCtlDaemonCore
@testable import SMCCore
import PolicyEngine

final class SmctlDaemonTests: XCTestCase {
    private var configPath: String!

    override func setUp() {
        super.setUp()
        configPath = NSTemporaryDirectory() + "smctl-test-\(UUID().uuidString).toml"
    }

    override func tearDown() {
        if let configPath {
            try? FileManager.default.removeItem(atPath: configPath)
        }
        super.tearDown()
    }

    // MARK: - Fan safety guard at the integration layer

    func testFanGuardForcesAutoWhenSensorsUnreadable() throws {
        // Regression for the fail-open found in review: manual fans + zero readable
        // temperature sensors must hand control back to the system, at the daemon level.
        let backend = RecordingBackend()
        let daemon = makeDaemon(backend: backend, capabilities: .oneFan)

        try daemon.setFanManual(index: 0, rpm: 2000, force: false)
        XCTAssertTrue(daemon.ftstGate.hasManualFans)
        backend.writes.removeAll()

        daemon.evaluateFanSubsystemLocked()

        XCTAssertTrue(daemon.safetyGuard.isLatched, "blind guard must latch")
        XCTAssertTrue(
            backend.writes.contains { $0.key == "F0Md" && $0.bytes == [0] },
            "fans must be restored to auto; writes: \(backend.writes)"
        )
        XCTAssertEqual(daemon.config.fan.profile, "auto")
        XCTAssertFalse(daemon.ftstGate.hasManualFans)
    }

    func testLatchedGuardRejectsManualControl() throws {
        let backend = RecordingBackend()
        let daemon = makeDaemon(backend: backend, capabilities: .oneFan)

        try daemon.setFanManual(index: 0, rpm: 2000, force: false)
        daemon.evaluateFanSubsystemLocked()  // trips (no sensors) and latches

        XCTAssertThrowsError(try daemon.setFanManual(index: 0, rpm: 2000, force: false)) { error in
            XCTAssertTrue("\(error)".contains("safety guard"), "unexpected error: \(error)")
        }
    }

    // MARK: - Startup reconciliation

    func testStartupReconciliationRestoresCrashResidue() {
        // SMC reports a fan stuck in manual mode but the daemon has no local policy:
        // startup must restore auto.
        let backend = RecordingBackend()
        backend.values["F0Md"] = [1]
        let daemon = makeDaemon(backend: backend, capabilities: .oneFan)
        backend.writes.removeAll()

        daemon.reconcileFanStartupLocked()

        XCTAssertTrue(
            backend.writes.contains { $0.key == "F0Md" && $0.bytes == [0] },
            "leftover manual mode must be restored to auto; writes: \(backend.writes)"
        )
    }

    // MARK: - Charge policy through the daemon glue

    func testChargeEvaluationDisablesChargingAboveLimit() throws {
        let backend = RecordingBackend()
        backend.values["BUIC"] = [85]          // charge percent (ui8)
        backend.values["CH0B"] = [0]           // charging allowed
        backend.values["CH0C"] = [0]
        backend.values["AC-W"] = [1]           // plugged in
        let daemon = makeDaemon(backend: backend, capabilities: .oneFanWithCharging)

        try daemon.setChargeLimit("70-80")     // 85% > upper bound 80 while charging allowed

        XCTAssertTrue(
            backend.writes.contains { $0.key == "CH0B" && $0.bytes == [2] },
            "charging must be disabled above the limit; writes: \(backend.writes)"
        )
    }

    // MARK: - Below-minimum gating

    func testBelowMinimumIsClampedWithoutForce() throws {
        let backend = RecordingBackend()
        let daemon = makeDaemon(backend: backend, capabilities: .oneFan)

        try daemon.setFanManual(index: 0, rpm: 200, force: false)

        XCTAssertTrue(
            backend.writes.contains { $0.key == "F0Tg" && $0.bytes == FanController.float32LittleEndianBytes(1000) },
            "below-minimum target must clamp to the fan minimum; writes: \(backend.writes)"
        )
    }

    func testForceAloneCannotGoBelowMinimum() {
        let backend = RecordingBackend()
        let daemon = makeDaemon(backend: backend, capabilities: .oneFan)

        XCTAssertThrowsError(try daemon.setFanManual(index: 0, rpm: 200, force: true)) { error in
            XCTAssertTrue("\(error)".contains("allow_below_minimum"), "error must point at the config opt-in: \(error)")
        }
        XCTAssertFalse(
            backend.writes.contains { $0.key == "F0Tg" && $0.bytes == FanController.float32LittleEndianBytes(200) },
            "no below-minimum write may reach the SMC without the opt-in"
        )
    }

    func testForceWithConfigOptInAllowsBelowMinimumButNeverAboveMaximum() throws {
        let backend = RecordingBackend()
        let daemon = makeDaemon(backend: backend, capabilities: .oneFan)
        daemon.config.safety.allow_below_minimum = true

        try daemon.setFanManual(index: 0, rpm: 0, force: true)
        XCTAssertTrue(
            backend.writes.contains { $0.key == "F0Tg" && $0.bytes == FanController.float32LittleEndianBytes(0) },
            "opt-in plus --force must allow a full fan stop; writes: \(backend.writes)"
        )

        try daemon.setFanManual(index: 0, rpm: 9000, force: true)
        XCTAssertTrue(
            backend.writes.contains { $0.key == "F0Tg" && $0.bytes == FanController.float32LittleEndianBytes(4900) },
            "the reported maximum is a hard ceiling even with --force; writes: \(backend.writes)"
        )
    }

    // MARK: - Config persistence

    func testConfigRoundtripAcrossDaemonInstances() throws {
        let backend = RecordingBackend()
        let daemon = makeDaemon(backend: backend, capabilities: .oneFan)
        try daemon.setChargeLimit("70-80")

        let reloaded = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        XCTAssertEqual(reloaded.config.battery.limit, "70-80")
    }

    func testAlertConfigDecodesFromToml() throws {
        try """
        [battery]
        limit = "80"

        [[alert]]
        name = "cpu-hot"
        on = "temp"
        sensor = "Tp09"
        above = 85.0
        for = 30.0
        cooldown = 300.0
        resolve = true
        action = "webhook"
        url = "http://gotify.lan/message"
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        XCTAssertEqual(daemon.config.alerts.count, 1)
        let alert = daemon.config.alerts.first
        XCTAssertEqual(alert?.name, "cpu-hot")
        XCTAssertEqual(alert?.above, 85)
        XCTAssertEqual(alert?.forSeconds, 30)
        XCTAssertEqual(alert?.rule?.trigger.kind, .temp)
    }

    func testWriteConfigPreservesAlerts() throws {
        try """
        [battery]
        limit = "80"

        [[alert]]
        name = "cpu-hot"
        on = "temp"
        sensor = "Tp09"
        above = 85.0
        action = "exec"
        command = ["/usr/local/bin/notify.sh", "{name}", "{value}"]
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        // A battery write rewrites the whole config file; the alert must survive.
        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        XCTAssertEqual(daemon.config.alerts.count, 1)
        try daemon.setChargeLimit("70-80")

        let reloaded = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        XCTAssertEqual(reloaded.config.alerts.count, 1, "writeConfig must round-trip [[alert]] tables")
        XCTAssertEqual(reloaded.config.alerts.first?.command, ["/usr/local/bin/notify.sh", "{name}", "{value}"])
        XCTAssertEqual(reloaded.config.alerts.first?.resolvedAction, .exec(["/usr/local/bin/notify.sh", "{name}", "{value}"]))
    }

    // MARK: - Helpers

    private func makeDaemon(backend: RecordingBackend, capabilities: Capabilities) -> SmctlDaemon {
        // Seed the fan keys so mode/target writes pass the key-info size check.
        backend.values["F0Md"] = backend.values["F0Md"] ?? [0]
        backend.values["F0Tg"] = backend.values["F0Tg"] ?? FanController.float32LittleEndianBytes(0)
        backend.values["F0Mn"] = FanController.float32LittleEndianBytes(1000)
        backend.values["F0Mx"] = FanController.float32LittleEndianBytes(4900)
        return SmctlDaemon(
            backend: backend,
            reader: nil,  // nil reader == zero readable temperature sensors
            capabilities: capabilities,
            configPath: configPath
        )
    }
}

final class AlertActionRunnerTests: XCTestCase {
    func testExecRunsSubprocessWithSubstitutedArgv() throws {
        let marker = NSTemporaryDirectory() + "smctl-alert-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: marker + "-cpu-hot") }

        let runner = AlertActionRunner()
        let event = AlertEvent(
            ruleName: "cpu-hot",
            kind: .fired,
            triggerKind: .temp,
            reason: "test",
            value: 92,
            timestamp: Date()
        )
        // Filename carries {name}; if substitution works the file lands at <marker>-cpu-hot.
        runner.run(event: event, action: .exec(["/usr/bin/touch", "\(marker)-{name}"]))

        let expected = marker + "-cpu-hot"
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: expected), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected), "exec action should run /usr/bin/touch with {name} substituted")
    }
}

private extension Capabilities {
    static var oneFan: Capabilities {
        Capabilities(
            fans: [FanCapability(
                index: 0,
                actualKey: "F0Ac",
                targetKey: "F0Tg",
                minimumKey: "F0Mn",
                maximumKey: "F0Mx",
                modeKey: "F0Md"
            )],
            ftstAvailable: false
        )
    }

    static var oneFanWithCharging: Capabilities {
        var capabilities = Capabilities.oneFan
        capabilities.chargingControl = SMCControlKeyGroup(
            identifier: "CH0B+CH0C",
            statusKey: "CH0B",
            requiredKeys: ["CH0B", "CH0C"],
            enableWrites: [SMCKeyWrite(key: "CH0B", bytes: [0]), SMCKeyWrite(key: "CH0C", bytes: [0])],
            disableWrites: [SMCKeyWrite(key: "CH0B", bytes: [2]), SMCKeyWrite(key: "CH0C", bytes: [2])]
        )
        capabilities.batteryKeys = ["BUIC", "AC-W"]
        return capabilities
    }
}

/// Mock SMC backend: key/value store for reads, append log for writes.
/// Writes apply immediately (no async-settle simulation needed at this layer).
private final class RecordingBackend: SMCWriteBackend {
    var values: [String: [UInt8]] = [:]
    var writes: [(key: String, bytes: [UInt8])] = []

    func readKeyInfo(_ key: String) throws -> SMCKeyInfo {
        guard let bytes = values[key] else {
            throw SMCError.notFound
        }
        let dataType: String
        switch bytes.count {
        case 1: dataType = "ui8 "
        case 4: dataType = "flt "   // fan keys (F0Tg/F0Mn/F0Mx) are 4-byte floats
        default: dataType = "hex_"
        }
        return SMCKeyInfo(
            dataSize: UInt32(bytes.count),
            dataType: FourCharCode.unchecked(dataType),
            dataAttributes: 0xC0
        )
    }

    func readValue(_ key: String) throws -> SMCReadValue {
        SMCReadValue(key: key, info: try readKeyInfo(key), bytes: values[key] ?? [])
    }

    func writeRawValue(_ key: String, bytes: [UInt8]) throws {
        writes.append((key, bytes))
        values[key] = bytes
    }
}
