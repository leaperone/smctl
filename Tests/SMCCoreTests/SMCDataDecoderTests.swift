import XCTest
@testable import SMCCore

final class SMCDataDecoderTests: XCTestCase {
    func testDecodesLittleEndianFloat() throws {
        let value = Float(1234.5)
        let raw = value.bitPattern
        let bytes = [
            UInt8(raw & 0xff),
            UInt8((raw >> 8) & 0xff),
            UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 24) & 0xff)
        ]

        let decoded = try SMCDataDecoder.decode(key: "F0Ac", bytes: bytes, dataType: FourCharCode.unchecked("flt "))
        XCTAssertEqual(decoded.doubleValue ?? 0, 1234.5, accuracy: 0.001)
    }

    func testDecodesFPE2BigEndianFixedPoint() throws {
        let decoded = try SMCDataDecoder.decode(key: "F0Mn", bytes: [0x12, 0x34], dataType: FourCharCode.unchecked("fpe2"))
        XCTAssertEqual(decoded.doubleValue ?? 0, Double(0x1234) / 4.0, accuracy: 0.001)
    }

    func testDecodesSP78SignedTemperature() throws {
        let decoded = try SMCDataDecoder.decode(key: "TC0P", bytes: [0x2a, 0x80], dataType: FourCharCode.unchecked("sp78"))
        XCTAssertEqual(decoded.doubleValue ?? 0, 42.5, accuracy: 0.001)
    }

    func testDecodesSI8AdapterSentinel() throws {
        // AC-W reads 0xff (-1) when no adapter is attached — observed on M2 MacBook Air.
        let decoded = try SMCDataDecoder.decode(key: "AC-W", bytes: [0xff], dataType: FourCharCode.unchecked("si8 "))
        XCTAssertEqual(decoded.doubleValue ?? 0, -1, accuracy: 0.001)
    }

    func testDecodesSI16LittleEndianBatteryCurrent() throws {
        // B0AC raw [0xc0, 0xfe] observed on M2 MacBook Air while discharging at -320 mA.
        let decoded = try SMCDataDecoder.decode(
            key: "B0AC",
            bytes: [0xc0, 0xfe],
            dataType: FourCharCode.unchecked("si16"),
            integerByteOrder: .little
        )
        XCTAssertEqual(decoded.doubleValue ?? 0, -320, accuracy: 0.001)
    }

    func testDecodesSI16BigEndian() throws {
        let decoded = try SMCDataDecoder.decode(
            key: "B0AC",
            bytes: [0xfe, 0xc0],
            dataType: FourCharCode.unchecked("si16"),
            integerByteOrder: .big
        )
        XCTAssertEqual(decoded.doubleValue ?? 0, -320, accuracy: 0.001)
    }

    func testDecodesUI16LittleEndianBatteryVoltage() throws {
        // B0AV raw [0xcf, 0x2f] observed on M2 MacBook Air: 12239 mV, matching
        // the AppleSmartBattery IOKit voltage. Big-endian decodes to 53039.
        let decoded = try SMCDataDecoder.decode(
            key: "B0AV",
            bytes: [0xcf, 0x2f],
            dataType: FourCharCode.unchecked("ui16"),
            integerByteOrder: .little
        )
        XCTAssertEqual(decoded.doubleValue ?? 0, 12239, accuracy: 0.001)
    }

    func testDecodesUI16BigEndian() throws {
        let decoded = try SMCDataDecoder.decode(
            key: "B0AV",
            bytes: [0x2f, 0xcf],
            dataType: FourCharCode.unchecked("ui16"),
            integerByteOrder: .big
        )
        XCTAssertEqual(decoded.doubleValue ?? 0, 12239, accuracy: 0.001)
    }

    func testDecodesUI32BothByteOrders() throws {
        let little = try SMCDataDecoder.decode(
            key: "Test",
            bytes: [0x78, 0x56, 0x34, 0x12],
            dataType: FourCharCode.unchecked("ui32"),
            integerByteOrder: .little
        )
        XCTAssertEqual(little.doubleValue ?? 0, Double(0x1234_5678), accuracy: 0.001)

        let big = try SMCDataDecoder.decode(
            key: "Test",
            bytes: [0x12, 0x34, 0x56, 0x78],
            dataType: FourCharCode.unchecked("ui32"),
            integerByteOrder: .big
        )
        XCTAssertEqual(big.doubleValue ?? 0, Double(0x1234_5678), accuracy: 0.001)
    }

    func testDecodesSI32LittleEndianNegative() throws {
        let decoded = try SMCDataDecoder.decode(
            key: "Test",
            bytes: [0xff, 0xff, 0xff, 0xff],
            dataType: FourCharCode.unchecked("si32"),
            integerByteOrder: .little
        )
        XCTAssertEqual(decoded.doubleValue ?? 0, -1, accuracy: 0.001)
    }

    func testPlatformByteOrderIsLittleEndianOnAppleSilicon() {
        #if arch(arm64)
        XCTAssertEqual(SMCIntegerByteOrder.platform, .little)
        #else
        XCTAssertEqual(SMCIntegerByteOrder.platform, .big)
        #endif
    }
}
