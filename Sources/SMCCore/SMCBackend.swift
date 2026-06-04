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
    public var sleep: @Sendable (UInt64) -> Void

    public init(
        maxAttempts: Int = 3,
        initialBackoffNanoseconds: UInt64 = 50_000_000,
        sleep: @escaping @Sendable (UInt64) -> Void = { nanoseconds in
            Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000)
        }
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialBackoffNanoseconds = initialBackoffNanoseconds
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
                let readBack = try readValue(key)
                if Array(readBack.bytes.prefix(bytes.count)) == bytes {
                    return
                }
                lastError = SMCError.writeVerificationFailed(key: key, expected: bytes, actual: readBack.bytes)
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
