import XCTest
@testable import SMCCore

final class SMCParamStructLayoutTests: XCTestCase {
    func testSMCParamStructLayoutMatchesAppleSMCContract() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.stride, 80)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.key), 0)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.vers), 4)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.pLimitData), 8)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.result), 40)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.status), 41)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data8), 42)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.data32), 44)
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.offset(of: \.bytes), 48)
    }
}
