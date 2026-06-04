import Foundation

public struct FanCapability: Codable, Equatable {
    public var index: Int
    public var actualKey: String
    public var targetKey: String
    public var minimumKey: String
    public var maximumKey: String
    public var modeKey: String?

    public init(index: Int, actualKey: String, targetKey: String, minimumKey: String, maximumKey: String, modeKey: String?) {
        self.index = index
        self.actualKey = actualKey
        self.targetKey = targetKey
        self.minimumKey = minimumKey
        self.maximumKey = maximumKey
        self.modeKey = modeKey
    }
}

public struct Capabilities: Codable, Equatable {
    public var fans: [FanCapability]
    public var ftstAvailable: Bool
    public var temperatureKeys: [String]
    public var batteryKeys: [String]
    public var powerKeys: [String]

    public init(
        fans: [FanCapability] = [],
        ftstAvailable: Bool = false,
        temperatureKeys: [String] = [],
        batteryKeys: [String] = [],
        powerKeys: [String] = []
    ) {
        self.fans = fans
        self.ftstAvailable = ftstAvailable
        self.temperatureKeys = temperatureKeys
        self.batteryKeys = batteryKeys
        self.powerKeys = powerKeys
    }

    public var availableKeysByFeature: [String: [String]] {
        [
            "fans": fans.flatMap { [$0.actualKey, $0.targetKey, $0.minimumKey, $0.maximumKey] + [$0.modeKey].compactMap { $0 } },
            "ftst": ftstAvailable ? ["Ftst"] : [],
            "temperature": temperatureKeys,
            "battery": batteryKeys,
            "power": powerKeys
        ]
    }
}

public struct KeyCatalog {
    public var temperatureCandidates: [String]
    public var batteryCandidates: [String]
    public var powerCandidates: [String]

    public init(
        temperatureCandidates: [String] = KeyCatalog.defaultTemperatureCandidates,
        batteryCandidates: [String] = ["BUIC", "B0AC", "B0AV", "PPBR", "AC-W"],
        powerCandidates: [String] = ["PDTR", "ID0R", "VD0R"]
    ) {
        self.temperatureCandidates = temperatureCandidates
        self.batteryCandidates = batteryCandidates
        self.powerCandidates = powerCandidates
    }

    public func detectCapabilities(using backend: SMCBackend) -> Capabilities {
        let fans = detectFans(using: backend)
        return Capabilities(
            fans: fans,
            ftstAvailable: probe("Ftst", using: backend),
            temperatureKeys: probe(temperatureCandidates, using: backend),
            batteryKeys: probe(batteryCandidates, using: backend),
            powerKeys: probe(powerCandidates, using: backend)
        )
    }

    private func detectFans(using backend: SMCBackend) -> [FanCapability] {
        let fanCount = readFanCount(using: backend) ?? probeFanCount(using: backend)
        guard fanCount > 0 else {
            return []
        }

        return (0..<fanCount).compactMap { index in
            let actual = "F\(index)Ac"
            guard probe(actual, using: backend) else {
                return nil
            }

            let target = "F\(index)Tg"
            let minimum = "F\(index)Mn"
            let maximum = "F\(index)Mx"
            let modeKey = ["F\(index)Md", "F\(index)md"].first { probe($0, using: backend) }

            return FanCapability(
                index: index,
                actualKey: actual,
                targetKey: target,
                minimumKey: minimum,
                maximumKey: maximum,
                modeKey: modeKey
            )
        }
    }

    private func readFanCount(using backend: SMCBackend) -> Int? {
        guard
            let value = try? backend.readValue("FNum"),
            let count = value.decoded?.doubleValue
        else {
            return nil
        }
        return max(0, Int(count))
    }

    private func probeFanCount(using backend: SMCBackend) -> Int {
        var count = 0
        for index in 0..<8 {
            if probe("F\(index)Ac", using: backend) {
                count = index + 1
            }
        }
        return count
    }

    private func probe(_ keys: [String], using backend: SMCBackend) -> [String] {
        stableUnique(keys).filter { probe($0, using: backend) }
    }

    private func probe(_ key: String, using backend: SMCBackend) -> Bool {
        do {
            _ = try backend.readKeyInfo(key)
            return true
        } catch SMCError.notFound {
            return false
        } catch {
            return false
        }
    }

    private func stableUnique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    public static var defaultTemperatureCandidates: [String] {
        let prefixes = ["Tp", "Tg", "TC", "Ts"]
        let numeric = prefixes.flatMap { prefix in
            (0...39).map { "\(prefix)\(String(format: "%02d", $0))" }
        }
        let commonSuffixes = ["0P", "1P", "2P", "3P", "0p", "0C", "0D", "0E", "0F", "0H", "0M"]
        let common = prefixes.flatMap { prefix in
            commonSuffixes.map { "\(prefix)\($0)" }
        }
        return numeric + common
    }
}
