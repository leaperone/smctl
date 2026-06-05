import XCTest
@testable import SMCCore

final class FtstGateManagerTests: XCTestCase {
    func testTracksManualFansAcrossEnterLeaveOrder() {
        var manager = FtstGateManager()

        XCTAssertFalse(manager.hasManualFans)
        manager.enterManual(index: 0)
        manager.enterManual(index: 1)
        manager.enterManual(index: 0)

        XCTAssertEqual(manager.manualFanIndices, [0, 1])
        XCTAssertTrue(manager.otherManualFansRemain(afterLeaving: 0))
        XCTAssertFalse(manager.leaveManual(index: 0))
        XCTAssertEqual(manager.manualFanIndices, [1])
        XCTAssertFalse(manager.otherManualFansRemain(afterLeaving: 1))
        XCTAssertTrue(manager.leaveManual(index: 1))
        XCTAssertFalse(manager.hasManualFans)
    }
}
