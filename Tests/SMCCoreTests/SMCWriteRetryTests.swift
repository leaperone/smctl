import XCTest
@testable import SMCCore

final class SMCWriteRetryTests: XCTestCase {
    func testWriteRetriesUntilReadBackMatches() throws {
        let backend = MockWriteBackend(initialBytes: [0x00], successfulBytesAfterAttempt: 3)
        try backend.writeKey(
            "CH0B",
            bytes: [0x02],
            retryPolicy: SMCWriteRetryPolicy(
                maxAttempts: 3,
                initialBackoffNanoseconds: 0,
                verifyReads: 1,
                verifyIntervalNanoseconds: 0
            )
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
                retryPolicy: SMCWriteRetryPolicy(
                    maxAttempts: 3,
                    initialBackoffNanoseconds: 0,
                    verifyReads: 1,
                    verifyIntervalNanoseconds: 0
                )
            )
        ) { error in
            XCTAssertEqual(backend.rawWriteAttempts, 3)
            guard case SMCError.writeVerificationFailed = error else {
                XCTFail("Expected writeVerificationFailed, got \(error)")
                return
            }
        }
    }

    func testVerificationToleratesAsynchronousApply() throws {
        // Regression (M4 Mac mini): the SMC applies writes asynchronously — a read
        // immediately after a successful write returns the stale previous value.
        // Verification must re-read within the settle window instead of rewriting.
        let backend = AsyncApplyMockBackend(initialBytes: [0x00], staleReadsBeforeApply: 2)
        try backend.writeKey(
            "F0Md",
            bytes: [0x01],
            retryPolicy: SMCWriteRetryPolicy(
                maxAttempts: 3,
                initialBackoffNanoseconds: 0,
                verifyReads: 4,
                verifyIntervalNanoseconds: 0
            )
        )

        XCTAssertEqual(backend.rawWriteAttempts, 1, "settle window must absorb stale reads without rewriting")
        XCTAssertEqual(backend.currentBytes, [0x01])
    }

    func testVerificationFailsWhenValueNeverSettles() throws {
        let backend = AsyncApplyMockBackend(initialBytes: [0x00], staleReadsBeforeApply: 99)

        XCTAssertThrowsError(
            try backend.writeKey(
                "F0Md",
                bytes: [0x01],
                retryPolicy: SMCWriteRetryPolicy(
                    maxAttempts: 2,
                    initialBackoffNanoseconds: 0,
                    verifyReads: 3,
                    verifyIntervalNanoseconds: 0
                )
            )
        ) { error in
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

/// Models firmware that accepts the write but exposes the new value only after
/// `staleReadsBeforeApply` subsequent reads.
private final class AsyncApplyMockBackend: SMCWriteBackend {
    private(set) var currentBytes: [UInt8]
    private var pendingBytes: [UInt8]?
    private var staleReadsRemaining: Int
    private let staleReadsBeforeApply: Int
    private(set) var rawWriteAttempts = 0

    init(initialBytes: [UInt8], staleReadsBeforeApply: Int) {
        currentBytes = initialBytes
        self.staleReadsBeforeApply = staleReadsBeforeApply
        staleReadsRemaining = staleReadsBeforeApply
    }

    func readKeyInfo(_ key: String) throws -> SMCKeyInfo {
        SMCKeyInfo(dataSize: 1, dataType: FourCharCode.unchecked("ui8 "), dataAttributes: 0xd0)
    }

    func readValue(_ key: String) throws -> SMCReadValue {
        if let pendingBytes {
            if staleReadsRemaining <= 0 {
                currentBytes = pendingBytes
                self.pendingBytes = nil
            } else {
                staleReadsRemaining -= 1
            }
        }
        return SMCReadValue(key: key, info: try readKeyInfo(key), bytes: currentBytes)
    }

    func writeRawValue(_ key: String, bytes: [UInt8]) throws {
        rawWriteAttempts += 1
        pendingBytes = bytes
        staleReadsRemaining = staleReadsBeforeApply
    }
}
