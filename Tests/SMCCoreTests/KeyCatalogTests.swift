import XCTest
@testable import SMCCore

final class KeyCatalogTests: XCTestCase {
    func testDetectsFanModeCaseFtstAndFeatureKeys() {
        let backend = MockSMCBackend(values: [
            "FNum": .ui8(1),
            "F0Ac": .flt(2200),
            "F0Tg": .flt(2400),
            "F0Mn": .flt(1200),
            "F0Mx": .flt(5200),
            "F0Md": .ui8(0),
            "Ftst": .ui8(0),
            "Tp00": .flt(41.25),
            "BUIC": .ui8(80),
            "PDTR": .flt(12.5)
        ])
        let catalog = KeyCatalog(
            temperatureCandidates: ["Tp00", "Tp01"],
            batteryCandidates: ["BUIC", "B0AC"],
            powerCandidates: ["PDTR", "ID0R"]
        )

        let capabilities = catalog.detectCapabilities(using: backend)

        XCTAssertEqual(capabilities.fans.count, 1)
        XCTAssertEqual(capabilities.fans.first?.modeKey, "F0Md")
        XCTAssertTrue(capabilities.ftstAvailable)
        XCTAssertEqual(capabilities.temperatureKeys, ["Tp00"])
        XCTAssertEqual(capabilities.batteryKeys, ["BUIC"])
        XCTAssertEqual(capabilities.powerKeys, ["PDTR"])
    }

    func testDetectsLowercaseFanMode() {
        let backend = MockSMCBackend(values: [
            "FNum": .ui8(1),
            "F0Ac": .flt(2200),
            "F0md": .ui8(0)
        ])

        let capabilities = KeyCatalog(temperatureCandidates: [], batteryCandidates: [], powerCandidates: [])
            .detectCapabilities(using: backend)

        XCTAssertEqual(capabilities.fans.first?.modeKey, "F0md")
        XCTAssertFalse(capabilities.ftstAvailable)
    }
}

private final class MockSMCBackend: SMCBackend {
    enum Value {
        case flt(Float)
        case ui8(UInt8)
    }

    private let values: [String: Value]

    init(values: [String: Value]) {
        self.values = values
    }

    func readKeyInfo(_ key: String) throws -> SMCKeyInfo {
        guard let value = values[key] else {
            throw SMCError.notFound
        }
        switch value {
        case .flt:
            return SMCKeyInfo(dataSize: 4, dataType: FourCharCode.unchecked("flt "), dataAttributes: 0x80)
        case .ui8:
            return SMCKeyInfo(dataSize: 1, dataType: FourCharCode.unchecked("ui8 "), dataAttributes: 0x80)
        }
    }

    func readValue(_ key: String) throws -> SMCReadValue {
        guard let value = values[key] else {
            throw SMCError.notFound
        }

        let info = try readKeyInfo(key)
        switch value {
        case .flt(let float):
            let raw = float.bitPattern
            return SMCReadValue(key: key, info: info, bytes: [
                UInt8(raw & 0xff),
                UInt8((raw >> 8) & 0xff),
                UInt8((raw >> 16) & 0xff),
                UInt8((raw >> 24) & 0xff)
            ])
        case .ui8(let byte):
            return SMCReadValue(key: key, info: info, bytes: [byte])
        }
    }
}
