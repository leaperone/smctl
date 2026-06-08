import Foundation

public enum SMCtlProtocolInfo {
    public static let version = "0.1.7"
    public static let machServiceName = "one.leaper.smctl.daemon"

    /// Numeric-component semver comparison, tolerant of a leading "v".
    /// Non-numeric/garbage versions compare as not-newer (fail closed: no false alarm).
    public static func isVersion(_ candidate: String, newerThan baseline: String) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let trimmed = s.hasPrefix("v") ? String(s.dropFirst()) : s
            let comps = trimmed.split(separator: ".").map { Int($0) }
            guard comps.allSatisfy({ $0 != nil }) else { return nil }
            return comps.map { $0! }
        }
        guard let a = parts(candidate), let b = parts(baseline) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

@objc(SMCtlDaemonXPCProtocol)
public protocol SMCtlDaemonXPCProtocol {
    func daemonPing(withReply reply: @escaping (Data?, String?) -> Void)
    func getBatteryStatus(withReply reply: @escaping (Data?, String?) -> Void)
    func getFans(withReply reply: @escaping (Data?, String?) -> Void)
    func getCapabilities(withReply reply: @escaping (Data?, String?) -> Void)
    func getDaemonStatus(withReply reply: @escaping (Data?, String?) -> Void)
    func setFanManual(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func setFanAuto(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func setFanProfile(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func setChargeLimit(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func setChargingEnabled(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func setAdapterEnabled(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func reloadConfig(withReply reply: @escaping (Data?, String?) -> Void)
}

public enum SMCtlProtocolCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

public struct EmptyResponseDTO: Codable, Equatable, Sendable {
    public init() {}
}

public struct PingDTO: Codable, Equatable, Sendable {
    public var ok: Bool
    public var version: String
    public var timestamp: Date
    /// Latest release tag the daemon has seen from its periodic check, or nil when
    /// the check is disabled or has not run yet. A missing key decodes to nil, so a
    /// newer CLI talking to an older daemon degrades gracefully.
    public var latestVersion: String?

    public init(ok: Bool, version: String, timestamp: Date, latestVersion: String? = nil) {
        self.ok = ok
        self.version = version
        self.timestamp = timestamp
        self.latestVersion = latestVersion
    }
}

public struct BatteryStatusDTO: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var chargePercent: Int?
    public var isCharging: Bool?
    public var pluggedIn: Bool?
    public var chargingControlSupported: Bool
    public var adapterControlSupported: Bool
    public var chargingControlGroup: String?
    public var adapterControlGroup: String?
    public var configuredLimit: String
    public var lowerBound: Int
    public var upperBound: Int
    public var sleepPolicy: String
    public var message: String?

    public init(
        timestamp: Date,
        chargePercent: Int?,
        isCharging: Bool?,
        pluggedIn: Bool?,
        chargingControlSupported: Bool,
        adapterControlSupported: Bool,
        chargingControlGroup: String?,
        adapterControlGroup: String?,
        configuredLimit: String,
        lowerBound: Int,
        upperBound: Int,
        sleepPolicy: String,
        message: String?
    ) {
        self.timestamp = timestamp
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.pluggedIn = pluggedIn
        self.chargingControlSupported = chargingControlSupported
        self.adapterControlSupported = adapterControlSupported
        self.chargingControlGroup = chargingControlGroup
        self.adapterControlGroup = adapterControlGroup
        self.configuredLimit = configuredLimit
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.sleepPolicy = sleepPolicy
        self.message = message
    }
}

public struct CapabilitiesDTO: Codable, Equatable, Sendable {
    public var chargingControlSupported: Bool
    public var adapterControlSupported: Bool
    public var chargingControlGroup: String?
    public var adapterControlGroup: String?
    public var batteryKeys: [String]
    public var fanCount: Int
    public var fanControlSupported: Bool
    public var ftstAvailable: Bool

    public init(
        chargingControlSupported: Bool,
        adapterControlSupported: Bool,
        chargingControlGroup: String?,
        adapterControlGroup: String?,
        batteryKeys: [String],
        fanCount: Int = 0,
        fanControlSupported: Bool = false,
        ftstAvailable: Bool = false
    ) {
        self.chargingControlSupported = chargingControlSupported
        self.adapterControlSupported = adapterControlSupported
        self.chargingControlGroup = chargingControlGroup
        self.adapterControlGroup = adapterControlGroup
        self.batteryKeys = batteryKeys
        self.fanCount = fanCount
        self.fanControlSupported = fanControlSupported
        self.ftstAvailable = ftstAvailable
    }
}

public struct DaemonStatusDTO: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var periodSeconds: Double
    public var configPath: String
    public var lastEvaluation: Date?
    public var lastError: String?

    public init(
        timestamp: Date,
        periodSeconds: Double,
        configPath: String,
        lastEvaluation: Date?,
        lastError: String?
    ) {
        self.timestamp = timestamp
        self.periodSeconds = periodSeconds
        self.configPath = configPath
        self.lastEvaluation = lastEvaluation
        self.lastError = lastError
    }
}

public struct SetChargeLimitRequestDTO: Codable, Equatable, Sendable {
    public var limit: String

    public init(limit: String) {
        self.limit = limit
    }
}

public struct SetEnabledRequestDTO: Codable, Equatable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

public struct FanStatusDTO: Codable, Equatable, Sendable {
    public var index: Int
    public var actualRPM: Double?
    public var targetRPM: Double?
    public var minimumRPM: Double?
    public var maximumRPM: Double?
    public var mode: String

    public init(index: Int, actualRPM: Double?, targetRPM: Double?, minimumRPM: Double?, maximumRPM: Double?, mode: String) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.mode = mode
    }
}

public struct FansStatusDTO: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var profile: String
    public var fans: [FanStatusDTO]
    public var message: String?

    public init(timestamp: Date, profile: String, fans: [FanStatusDTO], message: String?) {
        self.timestamp = timestamp
        self.profile = profile
        self.fans = fans
        self.message = message
    }
}

public struct SetFanManualRequestDTO: Codable, Equatable, Sendable {
    public var index: Int
    public var rpm: Double
    public var force: Bool

    public init(index: Int, rpm: Double, force: Bool = false) {
        self.index = index
        self.rpm = rpm
        self.force = force
    }
}

public struct SetFanAutoRequestDTO: Codable, Equatable, Sendable {
    public var index: Int?

    public init(index: Int? = nil) {
        self.index = index
    }
}

public struct SetFanProfileRequestDTO: Codable, Equatable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}
