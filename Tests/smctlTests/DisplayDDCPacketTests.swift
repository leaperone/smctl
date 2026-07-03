import DisplayDDC
import XCTest

/// DDC/CI packet construction per the MCCS spec: checksum is XOR of the
/// destination address (0x6E), the data offset, and all payload bytes.
final class DisplayDDCPacketTests: XCTestCase {
    func testWritePacketForLuminance40() {
        var packet = ddcCreatePacket(UInt8(DDC_VCP_LUMINANCE))
        XCTAssertEqual(packet.inputAddr, 0x51)
        ddcPrepareWrite(&packet, 40)
        withUnsafeBytes(of: packet.data) { data in
            XCTAssertEqual(data[0], 0x84)
            XCTAssertEqual(data[1], 0x03)
            XCTAssertEqual(data[2], 0x10)
            XCTAssertEqual(data[3], 0x00)
            XCTAssertEqual(data[4], 40)
            XCTAssertEqual(data[5], 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 40)
        }
    }

    func testReadPacketForPowerMode() {
        var packet = ddcCreatePacket(UInt8(DDC_VCP_POWER_MODE))
        ddcPrepareRead(&packet.data.0)
        withUnsafeBytes(of: packet.data) { data in
            XCTAssertEqual(data[0], 0x82)
            XCTAssertEqual(data[1], 0x01)
            XCTAssertEqual(data[2], 0xD6)
            XCTAssertEqual(data[3], 0x6E ^ 0x82 ^ 0x01 ^ 0xD6)
        }
    }
}
