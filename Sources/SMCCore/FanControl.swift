import Foundation

public enum FanMode: UInt8, Codable, Equatable, Sendable {
    case auto = 0
    case manual = 1
    case system = 3
}

public enum FanUnlockPath: String, Codable, Equatable, Sendable {
    case direct
    case ftst
}

public enum FanControlError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)
    case missingFan(Int)
    case missingModeKey(Int)

    public var description: String {
        switch self {
        case .unsupported(let message):
            return message
        case .missingFan(let index):
            return "Fan \(index) is not available."
        case .missingModeKey(let index):
            return "Fan \(index) has no readable mode key; manual fan control is unsupported."
        }
    }
}

public struct FanUnlockTiming: Sendable {
    public var ftstSettleNanoseconds: UInt64
    public var retryIntervalNanoseconds: UInt64
    public var timeoutNanoseconds: UInt64
    public var nowNanoseconds: @Sendable () -> UInt64
    public var sleep: @Sendable (UInt64) -> Void

    public init(
        ftstSettleNanoseconds: UInt64 = 500_000_000,
        retryIntervalNanoseconds: UInt64 = 100_000_000,
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        nowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: @escaping @Sendable (UInt64) -> Void = { nanoseconds in
            Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000)
        }
    ) {
        self.ftstSettleNanoseconds = ftstSettleNanoseconds
        self.retryIntervalNanoseconds = retryIntervalNanoseconds
        self.timeoutNanoseconds = timeoutNanoseconds
        self.nowNanoseconds = nowNanoseconds
        self.sleep = sleep
    }

    public static let `default` = FanUnlockTiming()
}

public struct FanStatus: Codable, Equatable, Sendable {
    public var index: Int
    public var actualRPM: Double?
    public var targetRPM: Double?
    public var minimumRPM: Double?
    public var maximumRPM: Double?
    public var mode: FanMode?
    public var rawMode: UInt8?

    public init(
        index: Int,
        actualRPM: Double?,
        targetRPM: Double?,
        minimumRPM: Double?,
        maximumRPM: Double?,
        mode: FanMode?,
        rawMode: UInt8?
    ) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.mode = mode
        self.rawMode = rawMode
    }
}

public struct FanManualResult: Codable, Equatable, Sendable {
    public var index: Int
    public var requestedRPM: Double
    public var unlockPath: FanUnlockPath

    public init(index: Int, requestedRPM: Double, unlockPath: FanUnlockPath) {
        self.index = index
        self.requestedRPM = requestedRPM
        self.unlockPath = unlockPath
    }
}

public struct FtstGateManager: Codable, Equatable, Sendable {
    public private(set) var manualFanIndices: Set<Int>

    public init(manualFanIndices: Set<Int> = []) {
        self.manualFanIndices = manualFanIndices
    }

    public var hasManualFans: Bool {
        !manualFanIndices.isEmpty
    }

    public mutating func enterManual(index: Int) {
        manualFanIndices.insert(index)
    }

    @discardableResult
    public mutating func leaveManual(index: Int) -> Bool {
        manualFanIndices.remove(index)
        return manualFanIndices.isEmpty
    }

    public func otherManualFansRemain(afterLeaving index: Int) -> Bool {
        manualFanIndices.contains { $0 != index }
    }

    public mutating func removeAll() {
        manualFanIndices.removeAll()
    }
}

public struct FanController {
    private let backend: any SMCWriteBackend
    private let capabilities: Capabilities

    public init(backend: any SMCWriteBackend, capabilities: Capabilities) {
        self.backend = backend
        self.capabilities = capabilities
    }

    public func status() -> [FanStatus] {
        capabilities.fans.map(status(for:))
    }

    public func status(index: Int) throws -> FanStatus {
        try status(for: fan(index))
    }

    public func setManual(
        index: Int,
        rpm: Double,
        timing: FanUnlockTiming = .default
    ) throws -> FanManualResult {
        let fan = try fan(index)
        let unlockPath = try unlockManualMode(fan: fan, timing: timing)
        try backend.writeKey(
            fan.targetKey,
            bytes: Self.float32LittleEndianBytes(Float(rpm)),
            retryPolicy: Self.singleAttemptRetryPolicy
        )
        return FanManualResult(index: index, requestedRPM: rpm, unlockPath: unlockPath)
    }

    @discardableResult
    public func unlockManualMode(
        index: Int,
        timing: FanUnlockTiming = .default
    ) throws -> FanUnlockPath {
        try unlockManualMode(fan: fan(index), timing: timing)
    }

    public func setAuto(index: Int, otherManualFansRemaining: Bool) throws {
        let fan = try fan(index)
        guard let modeKey = fan.modeKey else {
            throw FanControlError.missingModeKey(index)
        }
        try backend.writeKey(modeKey, bytes: [FanMode.auto.rawValue], retryPolicy: Self.singleAttemptRetryPolicy)
        guard capabilities.ftstAvailable, !otherManualFansRemaining else {
            return
        }
        if try readUInt8("Ftst") == 1 {
            try backend.writeKey("Ftst", bytes: [0], retryPolicy: Self.singleAttemptRetryPolicy)
        }
    }

    public func clearFtstIfSet() throws {
        guard capabilities.ftstAvailable else {
            return
        }
        if try readUInt8("Ftst") == 1 {
            try backend.writeKey("Ftst", bytes: [0], retryPolicy: Self.singleAttemptRetryPolicy)
        }
    }

    private func unlockManualMode(fan: FanCapability, timing: FanUnlockTiming) throws -> FanUnlockPath {
        guard let modeKey = fan.modeKey else {
            throw FanControlError.missingModeKey(fan.index)
        }

        do {
            try backend.writeKey(modeKey, bytes: [FanMode.manual.rawValue], retryPolicy: Self.singleAttemptRetryPolicy)
            return .direct
        } catch {
            guard capabilities.ftstAvailable else {
                throw FanControlError.unsupported(
                    "Manual fan control is unsupported: direct mode write failed"
                        + " (\(String(describing: error))) and Ftst is unavailable."
                )
            }
        }

        try backend.writeKey("Ftst", bytes: [1], retryPolicy: Self.singleAttemptRetryPolicy)
        timing.sleep(timing.ftstSettleNanoseconds)

        let start = timing.nowNanoseconds()
        var lastError: Error?
        while timing.nowNanoseconds() &- start <= timing.timeoutNanoseconds {
            do {
                try backend.writeKey(modeKey, bytes: [FanMode.manual.rawValue], retryPolicy: Self.singleAttemptRetryPolicy)
                return .ftst
            } catch {
                lastError = error
                timing.sleep(timing.retryIntervalNanoseconds)
            }
        }

        throw FanControlError.unsupported("Manual fan control did not unlock within 10 seconds after Ftst=1. Last error: \(String(describing: lastError))")
    }

    private func fan(_ index: Int) throws -> FanCapability {
        guard let fan = capabilities.fans.first(where: { $0.index == index }) else {
            throw FanControlError.missingFan(index)
        }
        return fan
    }

    private func status(for fan: FanCapability) -> FanStatus {
        let rawMode = fan.modeKey.flatMap { try? readUInt8($0) }
        return FanStatus(
            index: fan.index,
            actualRPM: numericValue(fan.actualKey),
            targetRPM: numericValue(fan.targetKey),
            minimumRPM: numericValue(fan.minimumKey),
            maximumRPM: numericValue(fan.maximumKey),
            mode: rawMode.flatMap(FanMode.init(rawValue:)),
            rawMode: rawMode
        )
    }

    private func numericValue(_ key: String) -> Double? {
        guard let value = try? backend.readValue(key) else {
            return nil
        }
        return value.decoded?.doubleValue
    }

    private func readUInt8(_ key: String) throws -> UInt8? {
        let value = try backend.readValue(key)
        if let number = value.decoded?.doubleValue {
            return UInt8(clamping: Int(number.rounded()))
        }
        return value.bytes.first
    }

    public static func float32LittleEndianBytes(_ value: Float) -> [UInt8] {
        let raw = value.bitPattern
        return [
            UInt8(raw & 0xff),
            UInt8((raw >> 8) & 0xff),
            UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 24) & 0xff)
        ]
    }

    private static let singleAttemptRetryPolicy = SMCWriteRetryPolicy(
        maxAttempts: 1,
        initialBackoffNanoseconds: 0
    )
}
