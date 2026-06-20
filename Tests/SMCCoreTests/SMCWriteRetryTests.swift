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

    // MARK: - Float write verification tolerance (issue #11)

    func testFloatWriteVerificationToleratesSMCQuantization() {
        // Real sample: wrote 3829.5 RPM, the SMC read back 3829.125 (low mantissa
        // bits cleared). Bytes differ; the values are 0.375 RPM apart.
        let flt = FourCharCode.unchecked("flt ")
        let written: [UInt8] = [0x00, 0x56, 0x6f, 0x45]   // 3829.5
        let readBack: [UInt8] = [0x00, 0x50, 0x6f, 0x45]  // 3829.125
        XCTAssertNotEqual(written, readBack)
        XCTAssertTrue(smcWriteVerified(expected: written, actual: readBack, dataType: flt))
    }

    func testFloatWriteVerificationStillRejectsRealMismatch() {
        // A write that never landed (read-back still 0) must NOT be hidden by tolerance.
        let flt = FourCharCode.unchecked("flt ")
        let written = FanController.float32LittleEndianBytes(3000)
        let stale = FanController.float32LittleEndianBytes(0)
        XCTAssertFalse(smcWriteVerified(expected: written, actual: stale, dataType: flt))
    }

    func testNonFloatWriteVerificationRequiresExactBytes() {
        // Tolerance must apply only to floats; integer/mode keys stay byte-exact.
        let ui8 = FourCharCode.unchecked("ui8 ")
        XCTAssertTrue(smcWriteVerified(expected: [0x02], actual: [0x02], dataType: ui8))
        XCTAssertFalse(smcWriteVerified(expected: [0x02], actual: [0x03], dataType: ui8))
    }

    func testWriteKeyVerifiesQuantizedFloatWithoutRewriting() throws {
        let backend = QuantizingFloatBackend(initialBytes: FanController.float32LittleEndianBytes(0))
        try backend.writeKey(
            "F0Tg",
            bytes: FanController.float32LittleEndianBytes(3829.5),
            retryPolicy: SMCWriteRetryPolicy(
                maxAttempts: 3,
                initialBackoffNanoseconds: 0,
                verifyReads: 2,
                verifyIntervalNanoseconds: 0
            )
        )
        XCTAssertEqual(backend.rawWriteAttempts, 1, "a quantized read-back must verify on the first write, no rewrite")
    }
}

/// Models SMC float quantization: the firmware stores a written float with its low
/// mantissa bits cleared, so the read-back never byte-matches an interpolated fan
/// target (issue #11).
private final class QuantizingFloatBackend: SMCWriteBackend {
    private(set) var currentBytes: [UInt8]
    private(set) var rawWriteAttempts = 0

    init(initialBytes: [UInt8]) {
        currentBytes = initialBytes
    }

    func readKeyInfo(_ key: String) throws -> SMCKeyInfo {
        SMCKeyInfo(dataSize: 4, dataType: FourCharCode.unchecked("flt "), dataAttributes: 0xd0)
    }

    func readValue(_ key: String) throws -> SMCReadValue {
        SMCReadValue(key: key, info: try readKeyInfo(key), bytes: currentBytes)
    }

    func writeRawValue(_ key: String, bytes: [UInt8]) throws {
        rawWriteAttempts += 1
        var bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        bits &= 0xFFFFF000  // clear the low 12 mantissa bits, as the SMC does
        currentBytes = [
            UInt8(bits & 0xff),
            UInt8((bits >> 8) & 0xff),
            UInt8((bits >> 16) & 0xff),
            UInt8((bits >> 24) & 0xff)
        ]
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
