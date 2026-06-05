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

    // MARK: - Config persistence

    func testConfigRoundtripAcrossDaemonInstances() throws {
        let backend = RecordingBackend()
        let daemon = makeDaemon(backend: backend, capabilities: .oneFan)
        try daemon.setChargeLimit("70-80")

        let reloaded = makeDaemon(backend: RecordingBackend(), capabilities: .oneFan)
        XCTAssertEqual(reloaded.config.battery.limit, "70-80")
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
        return SMCKeyInfo(
            dataSize: UInt32(bytes.count),
            dataType: FourCharCode.unchecked(bytes.count == 1 ? "ui8 " : "hex_"),
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
