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
}
