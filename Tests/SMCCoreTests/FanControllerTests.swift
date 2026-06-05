import XCTest
@testable import SMCCore

final class FanControllerTests: XCTestCase {
    func testDirectUnlockSetsManualAndTargetWithoutFtst() throws {
        let backend = MockFanBackend()
        backend.installSingleFan(ftst: false, mode: 0)
        let controller = FanController(backend: backend, capabilities: capabilities(ftst: false))

        let result = try controller.setManual(index: 0, rpm: 2400, timing: .test)

        XCTAssertEqual(result.unlockPath, .direct)
        XCTAssertEqual(backend.uint8Value("F0Md"), 1)
        XCTAssertNil(backend.uint8Value("Ftst"))
        XCTAssertEqual(try XCTUnwrap(backend.floatValue("F0Tg")), 2400, accuracy: 0.01)
    }

    func testFtstFallbackUnlockRetriesUntilModeWriteSucceeds() throws {
        let backend = MockFanBackend()
        backend.installSingleFan(ftst: true, mode: 3)
        backend.modeFailuresBeforeSuccess = 3
        let clock = TestFanClock()
        let controller = FanController(backend: backend, capabilities: capabilities(ftst: true))

        let result = try controller.setManual(index: 0, rpm: 3200, timing: clock.timing())

        XCTAssertEqual(result.unlockPath, .ftst)
        XCTAssertEqual(backend.uint8Value("Ftst"), 1)
        XCTAssertEqual(backend.uint8Value("F0Md"), 1)
        XCTAssertEqual(try XCTUnwrap(backend.floatValue("F0Tg")), 3200, accuracy: 0.01)
        XCTAssertEqual(clock.sleeps, [500_000_000, 100_000_000, 100_000_000])
    }

    func testFtstFallbackTimesOutWithoutRealSleep() throws {
        let backend = MockFanBackend()
        backend.installSingleFan(ftst: true, mode: 3)
        backend.modeFailuresBeforeSuccess = Int.max
        let clock = TestFanClock()
        let controller = FanController(backend: backend, capabilities: capabilities(ftst: true))

        XCTAssertThrowsError(
            try controller.setManual(index: 0, rpm: 3200, timing: clock.timing(timeoutNanoseconds: 300_000_000))
        ) { error in
            guard case FanControlError.unsupported = error else {
                XCTFail("Expected unsupported timeout, got \(error)")
                return
            }
        }
        XCTAssertEqual(backend.uint8Value("Ftst"), 1)
        XCTAssertEqual(backend.uint8Value("F0Md"), 3)
        XCTAssertGreaterThanOrEqual(clock.sleeps.count, 4)
    }

    func testSetAutoClearsFtstOnlyWhenLastManualFanLeaves() throws {
        let backend = MockFanBackend()
        backend.installTwoFans(ftst: true)
        let controller = FanController(backend: backend, capabilities: twoFanCapabilities(ftst: true))

        try controller.setAuto(index: 0, otherManualFansRemaining: true)
        XCTAssertEqual(backend.uint8Value("F0Md"), 0)
        XCTAssertEqual(backend.uint8Value("Ftst"), 1)

        try controller.setAuto(index: 1, otherManualFansRemaining: false)
        XCTAssertEqual(backend.uint8Value("F1Md"), 0)
        XCTAssertEqual(backend.uint8Value("Ftst"), 0)
    }

    private func capabilities(ftst: Bool) -> Capabilities {
        Capabilities(
            fans: [
                FanCapability(index: 0, actualKey: "F0Ac", targetKey: "F0Tg", minimumKey: "F0Mn", maximumKey: "F0Mx", modeKey: "F0Md")
            ],
            ftstAvailable: ftst
        )
    }

    private func twoFanCapabilities(ftst: Bool) -> Capabilities {
        Capabilities(
            fans: [
                FanCapability(index: 0, actualKey: "F0Ac", targetKey: "F0Tg", minimumKey: "F0Mn", maximumKey: "F0Mx", modeKey: "F0Md"),
                FanCapability(index: 1, actualKey: "F1Ac", targetKey: "F1Tg", minimumKey: "F1Mn", maximumKey: "F1Mx", modeKey: "F1Md")
            ],
            ftstAvailable: ftst
        )
    }
}

private final class TestFanClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0
    private(set) var sleeps: [UInt64] = []

    func timing(timeoutNanoseconds: UInt64 = 10_000_000_000) -> FanUnlockTiming {
        FanUnlockTiming(
            timeoutNanoseconds: timeoutNanoseconds,
            nowNanoseconds: {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.now
            },
            sleep: { [self] nanoseconds in
                lock.lock()
                sleeps.append(nanoseconds)
                now += nanoseconds
                lock.unlock()
            }
        )
    }
}

private final class MockFanBackend: SMCWriteBackend {
    enum StoredValue {
        case flt(Float)
        case ui8(UInt8)
    }

    var values: [String: StoredValue] = [:]
    var modeFailuresBeforeSuccess = 0
    private var modeWriteAttempts = 0

    func installSingleFan(ftst: Bool, mode: UInt8) {
        values["F0Ac"] = .flt(1800)
        values["F0Tg"] = .flt(1800)
        values["F0Mn"] = .flt(1200)
        values["F0Mx"] = .flt(5200)
        values["F0Md"] = .ui8(mode)
        if ftst {
            values["Ftst"] = .ui8(0)
        }
    }

    func installTwoFans(ftst: Bool) {
        installSingleFan(ftst: ftst, mode: 1)
        values["F1Ac"] = .flt(1800)
        values["F1Tg"] = .flt(1800)
        values["F1Mn"] = .flt(1200)
        values["F1Mx"] = .flt(5200)
        values["F1Md"] = .ui8(1)
        if ftst {
            values["Ftst"] = .ui8(1)
        }
    }

    func readKeyInfo(_ key: String) throws -> SMCKeyInfo {
        guard let value = values[key] else {
            throw SMCError.notFound
        }
        switch value {
        case .flt:
            return SMCKeyInfo(dataSize: 4, dataType: FourCharCode.unchecked("flt "), dataAttributes: 0xc0)
        case .ui8:
            return SMCKeyInfo(dataSize: 1, dataType: FourCharCode.unchecked("ui8 "), dataAttributes: 0xc0)
        }
    }

    func readValue(_ key: String) throws -> SMCReadValue {
        guard let value = values[key] else {
            throw SMCError.notFound
        }
        let info = try readKeyInfo(key)
        switch value {
        case .flt(let float):
            return SMCReadValue(key: key, info: info, bytes: FanController.float32LittleEndianBytes(float))
        case .ui8(let byte):
            return SMCReadValue(key: key, info: info, bytes: [byte])
        }
    }

    func writeRawValue(_ key: String, bytes: [UInt8]) throws {
        if key.hasSuffix("Md"), bytes == [1] {
            modeWriteAttempts += 1
            if modeWriteAttempts <= modeFailuresBeforeSuccess {
                throw SMCError.badCommand
            }
        }
        switch try readKeyInfo(key).dataSize {
        case 1:
            values[key] = .ui8(bytes[0])
        case 4:
            let raw = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            values[key] = .flt(Float(bitPattern: raw))
        default:
            throw SMCError.keySizeMismatch
        }
    }

    func uint8Value(_ key: String) -> UInt8? {
        guard case .ui8(let value) = values[key] else {
            return nil
        }
        return value
    }

    func floatValue(_ key: String) -> Double? {
        guard case .flt(let value) = values[key] else {
            return nil
        }
        return Double(value)
    }
}

private extension FanUnlockTiming {
    static let test = FanUnlockTiming(
        nowNanoseconds: { 0 },
        sleep: { _ in }
    )
}
