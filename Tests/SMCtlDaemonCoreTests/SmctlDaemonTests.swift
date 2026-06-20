import Foundation
import Darwin
import XCTest
@testable import SMCtlDaemonCore
@testable import SMCCore
import PolicyEngine

final class SmctlDaemonTests: XCTestCase {
    private var configPath: String!

    override func setUp() {
        super.setUp()
        setenv("SMCTL_SENTRY_DISABLED", "1", 1)
        configPath = NSTemporaryDirectory() + "smctl-test-\(UUID().uuidString).toml"
    }

    override func tearDown() {
        if let configPath {
            try? FileManager.default.removeItem(atPath: configPath)
        }
        unsetenv("SMCTL_SENTRY_DISABLED")
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

    func testForceDischargeRoundtripsAndStopsWithDisabledLimit() throws {
        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        try daemon.setChargeLimit("70-80", forceDischarge: true)

        let reloaded = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        XCTAssertEqual(reloaded.config.battery.limit, "70-80")
        XCTAssertTrue(reloaded.config.battery.force_discharge, "writeConfig must persist battery.force_discharge")

        try reloaded.setChargeLimit("100", forceDischarge: true)

        let stopped = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        XCTAssertEqual(stopped.config.battery.limit, "100")
        XCTAssertFalse(stopped.config.battery.force_discharge, "disabled charge limiting cannot keep force-discharge armed")
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

    func testSentryConfigDecodesFromToml() throws {
        try """
        [sentry]
        dsn = "https://public@example.invalid/1"
        environment = "staging"
        debug = true
        traces_sample_rate = 0.25
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        XCTAssertEqual(daemon.config.sentry.dsn, "https://public@example.invalid/1")
        XCTAssertEqual(daemon.config.sentry.environment, "staging")
        XCTAssertTrue(daemon.config.sentry.debug)
        XCTAssertEqual(daemon.config.sentry.traces_sample_rate, 0.25)
    }

    func testSentrySampleRateIsClamped() throws {
        try """
        [sentry]
        traces_sample_rate = 2.0
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        XCTAssertEqual(daemon.config.sentry.traces_sample_rate, 1)
    }

    func testWriteConfigPreservesSentry() throws {
        try """
        [battery]
        limit = "80"

        [sentry]
        dsn = "https://public@example.invalid/1"
        environment = "staging"
        debug = true
        traces_sample_rate = 0.5
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        try daemon.setChargeLimit("70-80")

        let reloaded = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        XCTAssertEqual(reloaded.config.sentry.dsn, "https://public@example.invalid/1")
        XCTAssertEqual(reloaded.config.sentry.environment, "staging")
        XCTAssertTrue(reloaded.config.sentry.debug)
        XCTAssertEqual(reloaded.config.sentry.traces_sample_rate, 0.5)
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

    func testAlertStatusIncludesDefinitionsAndInvalidRules() throws {
        try """
        [[alert]]
        name = "cpu-hot"
        on = "temp"
        sensor = "Tp09"
        above = 85.0
        for = 30.0
        cooldown = 300.0
        resolve = true
        action = "webhook"
        url = "https://gotify.lan/message?token=secret"

        [[alert]]
        name = "broken"
        on = "temp"
        action = "exec"
        command = ["/usr/local/bin/notify.sh", "secret-token"]
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        let status = daemon.alertStatus()

        XCTAssertEqual(status.rules.map(\.name), ["cpu-hot"], "only valid rules should enter the alert engine")
        XCTAssertEqual(status.definitions?.count, 2)
        let valid = status.definitions?.first { $0.name == "cpu-hot" }
        XCTAssertEqual(valid?.valid, true)
        XCTAssertEqual(valid?.action, "webhook")
        XCTAssertEqual(valid?.actionTarget, "https://gotify.lan/message")
        XCTAssertFalse(valid?.actionTarget?.contains("secret") ?? true, "status must not leak webhook query tokens")

        let broken = status.definitions?.first { $0.name == "broken" }
        XCTAssertEqual(broken?.valid, false)
        XCTAssertEqual(broken?.problem, "temp trigger requires 'above'")
        XCTAssertEqual(broken?.actionTarget, "/usr/local/bin/notify.sh (+1 args)")
        XCTAssertFalse(broken?.actionTarget?.contains("secret") ?? true, "status must not leak exec argv secrets")
    }

    // MARK: - Alert write-error signal

    func testWriteErrorAlertIgnoresGeneralDaemonError() {
        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        daemon.config.alerts = [AlertConfig(name: "writes", on: "write-error", cooldown: 0, action: "log")]

        daemon.evaluateLocked()
        XCTAssertNotNil(daemon.daemonStatus().lastError, "test setup should create a general daemon error")

        daemon.tickFanAndAlertsLocked()

        XCTAssertTrue(daemon.alertStatus().recent.isEmpty, "write-error alerts must not fire from generic lastError")
    }

    func testWriteErrorAlertFiresForSMCWriteFailureAndClearsAfterSuccess() throws {
        let backend = RecordingBackend()
        backend.values["BUIC"] = [85]
        backend.values["CH0B"] = [0]
        backend.values["CH0C"] = [0]
        backend.values["AC-W"] = [1]
        backend.failingWriteKeys = ["CH0B"]
        let daemon = makeDaemon(backend: backend, capabilities: .oneFanWithCharging)
        daemon.config.alerts = [AlertConfig(name: "writes", on: "write-error", cooldown: 0, action: "log")]

        try daemon.setChargeLimit("70-80")
        XCTAssertNotNil(daemon.daemonStatus().lastError)

        daemon.tickFanAndAlertsLocked()
        var status = daemon.alertStatus()
        XCTAssertEqual(status.recent.count, 1)
        XCTAssertEqual(status.recent.first?.trigger, "write-error")
        XCTAssertEqual(status.recent.first?.reason.contains("CH0B"), true)

        backend.failingWriteKeys = []
        try daemon.setChargingEnabled(true)
        daemon.tickFanAndAlertsLocked()

        status = daemon.alertStatus()
        XCTAssertEqual(status.rules.first?.status, "armed")
    }

    // MARK: - Config decoding tolerance (issue #9)

    func testDoubleConfigFieldsAcceptTomlIntegers() throws {
        // TOML keeps integers distinct from floats, so a natural `temp_ceiling = 95`
        // / `points = [[105, 2000]]` used to throw a type mismatch and silently reset
        // the ENTIRE config to defaults.
        try """
        [safety]
        temp_ceiling = 95

        [[fan.curves]]
        name = "test"
        sensors = []
        points = [[0, "max"], [105, 2000]]
        hysteresis = 3
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)

        XCTAssertFalse(
            daemon.daemonStatus().lastError?.contains("failed to parse") ?? false,
            "a valid integer config must not be reported as a parse error"
        )
        XCTAssertEqual(daemon.config.safety.temp_ceiling, 95)
        let curve = try XCTUnwrap(daemon.config.fan.curves.first)
        XCTAssertEqual(curve.hysteresis, 3)
        XCTAssertEqual(curve.points, [[.number(0), .maximum], [.number(105), .number(2000)]])
    }

    func testFanCurveWeightsAcceptIntegerValues() throws {
        // Integer weights are the natural way to write them and must not throw and
        // discard the whole config (gap caught in preflight review).
        try """
        [[fan.curves]]
        name = "test"
        sensors = ["Tp01", "Tg05"]
        points = [[0.0, "max"]]
        weights = { Tp01 = 2, Tg05 = 1 }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)

        XCTAssertFalse(daemon.daemonStatus().lastError?.contains("failed to parse") ?? false)
        XCTAssertEqual(daemon.config.fan.curves.first?.weights, ["Tp01": 2, "Tg05": 1])
    }

    func testFanCurveWeightsAcceptMixedIntegerAndFloat() throws {
        try """
        [[fan.curves]]
        name = "test"
        sensors = ["Tp01", "Tg05"]
        points = [[0.0, "max"]]
        weights = { Tp01 = 2, Tg05 = 1.5 }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)

        XCTAssertFalse(daemon.daemonStatus().lastError?.contains("failed to parse") ?? false)
        XCTAssertEqual(daemon.config.fan.curves.first?.weights, ["Tp01": 2, "Tg05": 1.5])
    }

    func testFanCurveOmittingHysteresisDefaultsToZero() throws {
        // `hysteresis` used to be required — omitting it threw keyNotFound and reset
        // the whole config.
        try """
        [[fan.curves]]
        name = "test"
        sensors = []
        points = [[0.0, "max"]]
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)

        XCTAssertFalse(daemon.daemonStatus().lastError?.contains("failed to parse") ?? false)
        XCTAssertEqual(daemon.config.fan.curves.first?.hysteresis, 0)
    }

    func testMalformedConfigSurfacesInDaemonStatusAndFallsBackToDefaults() throws {
        // Part 2: a genuine type error must be visible in `daemon status`, not
        // silently swallowed while the daemon runs on defaults.
        try """
        [safety]
        temp_ceiling = "boom"
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        let daemon = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)

        let status = daemon.daemonStatus()
        XCTAssertEqual(
            daemon.config.safety.temp_ceiling, FanSafetyGuard.defaultCeilingCelsius,
            "unparseable config must fall back to defaults, not crash"
        )
        let reported = try XCTUnwrap(status.lastError, "config parse failure must surface in status")
        XCTAssertTrue(reported.contains("failed to parse"), "status should explain the failure: \(reported)")
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

final class XPCAuthorizationTests: XCTestCase {
    func testUserIsAdminHandlesSystemAccountsWithNegativeIDs() {
        // nobody is uid/gid -2 (4294967294 as uid_t). The group lookup must not
        // trap converting such ids to Int32 — a non-admin caller crashing the
        // daemon is a local DoS (regression test for a real crash).
        XCTAssertFalse(XPCService.userIsAdmin(uid_t(bitPattern: -2)))
    }

    func testUserIsAdminReturnsFalseForUnknownUID() {
        XCTAssertFalse(XPCService.userIsAdmin(54321))
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
    var failingWriteKeys: Set<String> = []

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
        if failingWriteKeys.contains(key) {
            throw SMCError.badCommand
        }
        writes.append((key, bytes))
        values[key] = bytes
    }
}
