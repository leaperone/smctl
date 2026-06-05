import XCTest
@testable import SMCCore

final class SMCWriteRetryTests: XCTestCase {
    func testWriteRetriesUntilReadBackMatches() throws {
        let backend = MockWriteBackend(initialBytes: [0x00], successfulBytesAfterAttempt: 3)
        try backend.writeKey(
            "CH0B",
            bytes: [0x02],
            retryPolicy: SMCWriteRetryPolicy(maxAttempts: 3, initialBackoffNanoseconds: 0)
        )

        XCTAssertEqual(backend.rawWriteAttempts, 3)
        XCTAssertEqual(backend.currentBytes, [0x02])
    }

    func testWriteThrowsWhenVerificationNeverMatches() throws {
        let backend = MockWriteBackend(initialBytes: [0x00], successfulBytesAfterAttempt: 99)

        XCTAssertThrowsError(
            try backend.writeKey(
                "CH0B",
                bytes: [0x02],
                retryPolicy: SMCWriteRetryPolicy(maxAttempts: 3, initialBackoffNanoseconds: 0)
            )
        ) { error in
            XCTAssertEqual(backend.rawWriteAttempts, 3)
            guard case SMCError.writeVerificationFailed = error else {
                XCTFail("Expected writeVerificationFailed, got \(error)")
                return
            }
        }
    }
}

private final class MockWriteBackend: SMCWriteBackend {
    private(set) var currentBytes: [UInt8]
    private let successfulBytesAfterAttempt: Int
    private(set) var rawWriteAttempts = 0

    init(initialBytes: [UInt8], successfulBytesAfterAttempt: Int) {
        currentBytes = initialBytes
        self.successfulBytesAfterAttempt = successfulBytesAfterAttempt
    }

    func readKeyInfo(_ key: String) throws -> SMCKeyInfo {
        SMCKeyInfo(dataSize: 1, dataType: FourCharCode.unchecked("ui8 "), dataAttributes: 0x80)
    }

    func readValue(_ key: String) throws -> SMCReadValue {
        SMCReadValue(key: key, info: try readKeyInfo(key), bytes: currentBytes)
    }

    func writeRawValue(_ key: String, bytes: [UInt8]) throws {
        rawWriteAttempts += 1
        if rawWriteAttempts >= successfulBytesAfterAttempt {
            currentBytes = bytes
        }
    }
}

