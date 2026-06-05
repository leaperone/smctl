import Foundation

public struct SMCReadValue: Codable, Equatable {
    public var key: String
    public var info: SMCKeyInfo
    public var bytes: [UInt8]

    public init(key: String, info: SMCKeyInfo, bytes: [UInt8]) {
        self.key = key
        self.info = info
        self.bytes = bytes
    }

    public var decoded: SMCDecodedValue? {
        try? SMCDataDecoder.decode(key: key, bytes: bytes, dataType: info.dataType)
    }
}

public protocol SMCBackend {
    func readKeyInfo(_ key: String) throws -> SMCKeyInfo
    func readValue(_ key: String) throws -> SMCReadValue
}

public protocol SMCWriteBackend: SMCBackend {
    func writeRawValue(_ key: String, bytes: [UInt8]) throws
}

public struct SMCWriteRetryPolicy: Sendable {
    public var maxAttempts: Int
    public var initialBackoffNanoseconds: UInt64
    /// SMC value writes can apply asynchronously (observed on M4 Mac mini: a read
    /// immediately after a successful write returns the OLD value for several hundred
    /// milliseconds). Verification therefore re-reads up to `verifyReads` times with
    /// `verifyIntervalNanoseconds` between reads before declaring a mismatch.
    public var verifyReads: Int
    public var verifyIntervalNanoseconds: UInt64
    public var sleep: @Sendable (UInt64) -> Void

    public init(
        maxAttempts: Int = 3,
        initialBackoffNanoseconds: UInt64 = 50_000_000,
        verifyReads: Int = 6,
        verifyIntervalNanoseconds: UInt64 = 200_000_000,
        sleep: @escaping @Sendable (UInt64) -> Void = { nanoseconds in
            Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000)
        }
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialBackoffNanoseconds = initialBackoffNanoseconds
        self.verifyReads = max(1, verifyReads)
        self.verifyIntervalNanoseconds = verifyIntervalNanoseconds
        self.sleep = sleep
    }

    public static let `default` = SMCWriteRetryPolicy()
}

public extension SMCWriteBackend {
    func writeKey(
        _ key: String,
        bytes: [UInt8],
        retryPolicy: SMCWriteRetryPolicy = .default
    ) throws {
        let info = try readKeyInfo(key)
        guard bytes.count == Int(info.dataSize) else {
            throw SMCError.malformedData(
                key: key,
                type: info.dataTypeString,
                expected: Int(info.dataSize),
                actual: bytes.count
            )
        }

        var lastError: Error?
        var delay = retryPolicy.initialBackoffNanoseconds
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                try writeRawValue(key, bytes: bytes)
                // Settle window: the SMC may apply the write asynchronously, so an
                // immediate read-back can return the stale previous value.
                var actual: [UInt8] = []
                for verifyAttempt in 1...retryPolicy.verifyReads {
                    let readBack = try readValue(key)
                    actual = readBack.bytes
                    if Array(actual.prefix(bytes.count)) == bytes {
                        return
                    }
                    if verifyAttempt < retryPolicy.verifyReads {
                        retryPolicy.sleep(retryPolicy.verifyIntervalNanoseconds)
                    }
                }
                lastError = SMCError.writeVerificationFailed(key: key, expected: bytes, actual: actual)
            } catch {
                lastError = error
            }

            if attempt < retryPolicy.maxAttempts, delay > 0 {
                retryPolicy.sleep(delay)
                delay *= 2
            }
        }

        throw lastError ?? SMCError.writeVerificationFailed(key: key, expected: bytes, actual: [])
    }
}
