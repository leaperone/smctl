import Foundation
import OSLog

public struct SMCKeyWrite: Codable, Equatable, Sendable {
    public var key: String
    public var bytes: [UInt8]

    public init(key: String, bytes: [UInt8]) {
        self.key = key
        self.bytes = bytes
    }
}

public struct SMCControlKeyGroup: Codable, Equatable, Sendable {
    public var identifier: String
    public var statusKey: String
    public var requiredKeys: [String]
    public var enableWrites: [SMCKeyWrite]
    public var disableWrites: [SMCKeyWrite]

    public init(
        identifier: String,
        statusKey: String,
        requiredKeys: [String],
        enableWrites: [SMCKeyWrite],
        disableWrites: [SMCKeyWrite]
    ) {
        self.identifier = identifier
        self.statusKey = statusKey
        self.requiredKeys = requiredKeys
        self.enableWrites = enableWrites
        self.disableWrites = disableWrites
    }
}

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
    public var chargingControl: SMCControlKeyGroup?
    public var adapterControl: SMCControlKeyGroup?

    public init(
        fans: [FanCapability] = [],
        ftstAvailable: Bool = false,
        temperatureKeys: [String] = [],
        batteryKeys: [String] = [],
        powerKeys: [String] = [],
        chargingControl: SMCControlKeyGroup? = nil,
        adapterControl: SMCControlKeyGroup? = nil
    ) {
        self.fans = fans
        self.ftstAvailable = ftstAvailable
        self.temperatureKeys = temperatureKeys
        self.batteryKeys = batteryKeys
        self.powerKeys = powerKeys
        self.chargingControl = chargingControl
        self.adapterControl = adapterControl
    }

    public var availableKeysByFeature: [String: [String]] {
        [
            "fans": fans.flatMap { [$0.actualKey, $0.targetKey, $0.minimumKey, $0.maximumKey] + [$0.modeKey].compactMap { $0 } },
            "ftst": ftstAvailable ? ["Ftst"] : [],
            "temperature": temperatureKeys,
            "battery": batteryKeys,
            "power": powerKeys,
            "chargingControl": chargingControl?.requiredKeys ?? [],
            "adapterControl": adapterControl?.requiredKeys ?? []
        ]
    }
}

public struct KeyCatalog {
    private static let logger = Logger(subsystem: "dev.smctl", category: "KeyCatalog")

    public var temperatureCandidates: [String]
    public var batteryCandidates: [String]
    public var powerCandidates: [String]
    public var chargingControlCandidates: [SMCControlKeyGroup]
    public var adapterControlCandidates: [SMCControlKeyGroup]

    public init(
        temperatureCandidates: [String] = KeyCatalog.defaultTemperatureCandidates,
        batteryCandidates: [String] = ["BUIC", "B0AC", "B0AV", "PPBR", "AC-W"],
        powerCandidates: [String] = ["PDTR", "ID0R", "VD0R"],
        chargingControlCandidates: [SMCControlKeyGroup] = KeyCatalog.defaultChargingControlCandidates,
        adapterControlCandidates: [SMCControlKeyGroup] = KeyCatalog.defaultAdapterControlCandidates
    ) {
        self.temperatureCandidates = temperatureCandidates
        self.batteryCandidates = batteryCandidates
        self.powerCandidates = powerCandidates
        self.chargingControlCandidates = chargingControlCandidates
        self.adapterControlCandidates = adapterControlCandidates
    }

    public func detectCapabilities(using backend: SMCBackend) -> Capabilities {
        let fans = detectFans(using: backend)
        let chargingControl = detectControlGroup(chargingControlCandidates, using: backend)
        let adapterControl = detectControlGroup(adapterControlCandidates, using: backend)
        let batteryKeys = probe(
            batteryCandidates
                + chargingControlCandidates.flatMap(\.requiredKeys)
                + adapterControlCandidates.flatMap(\.requiredKeys),
            using: backend
        )
        return Capabilities(
            fans: fans,
            ftstAvailable: probe("Ftst", using: backend),
            temperatureKeys: probe(temperatureCandidates, using: backend),
            batteryKeys: batteryKeys,
            powerKeys: probe(powerCandidates, using: backend),
            chargingControl: chargingControl,
            adapterControl: adapterControl
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
            Self.logger.error("Probe for SMC key \(key, privacy: .public) failed with non-notFound error: \(String(describing: error), privacy: .public)")
            return true
        }
    }

    private func detectControlGroup(_ groups: [SMCControlKeyGroup], using backend: SMCBackend) -> SMCControlKeyGroup? {
        groups.first { group in
            group.requiredKeys.allSatisfy { probe($0, using: backend) }
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

    public static var defaultChargingControlCandidates: [SMCControlKeyGroup] {
        [
            SMCControlKeyGroup(
                identifier: "tahoe-charging",
                statusKey: "CHTE",
                requiredKeys: ["CHTE"],
                enableWrites: [SMCKeyWrite(key: "CHTE", bytes: [0x00, 0x00, 0x00, 0x00])],
                disableWrites: [SMCKeyWrite(key: "CHTE", bytes: [0x01, 0x00, 0x00, 0x00])]
            ),
            SMCControlKeyGroup(
                identifier: "legacy-charging",
                statusKey: "CH0B",
                requiredKeys: ["CH0B", "CH0C"],
                enableWrites: [
                    SMCKeyWrite(key: "CH0B", bytes: [0x00]),
                    SMCKeyWrite(key: "CH0C", bytes: [0x00])
                ],
                disableWrites: [
                    SMCKeyWrite(key: "CH0B", bytes: [0x02]),
                    SMCKeyWrite(key: "CH0C", bytes: [0x02])
                ]
            )
        ]
    }

    public static var defaultAdapterControlCandidates: [SMCControlKeyGroup] {
        [
            SMCControlKeyGroup(
                identifier: "tahoe-adapter",
                statusKey: "CHIE",
                requiredKeys: ["CHIE"],
                enableWrites: [SMCKeyWrite(key: "CHIE", bytes: [0x00])],
                disableWrites: [SMCKeyWrite(key: "CHIE", bytes: [0x08])]
            ),
            SMCControlKeyGroup(
                identifier: "legacy-adapter",
                statusKey: "CH0I",
                requiredKeys: ["CH0I", "CH0J"],
                enableWrites: [
                    SMCKeyWrite(key: "CH0I", bytes: [0x00]),
                    SMCKeyWrite(key: "CH0J", bytes: [0x00])
                ],
                disableWrites: [
                    SMCKeyWrite(key: "CH0I", bytes: [0x01]),
                    SMCKeyWrite(key: "CH0J", bytes: [0x01])
                ]
            )
        ]
    }
}
