import Foundation

public struct TemperatureReading: Codable, Equatable {
    public var key: String
    public var group: String
    public var celsius: Double
    public var dataType: String
}

public struct FanReading: Codable, Equatable {
    public var index: Int
    public var actualRPM: Double?
    public var targetRPM: Double?
    public var minimumRPM: Double?
    public var maximumRPM: Double?
    public var mode: String?
}

public struct NamedReading: Codable, Equatable {
    public var key: String
    public var name: String
    public var value: Double?
    public var rawBytes: [UInt8]?
    public var unit: String?
    public var dataType: String
}

public struct SensorSnapshot: Codable, Equatable {
    public var timestamp: Date
    public var capabilities: Capabilities
    public var temperatures: [TemperatureReading]
    public var fans: [FanReading]
    public var battery: [NamedReading]
    public var power: [NamedReading]
}

public final class SensorReader {
    private let backend: SMCBackend
    private let catalog: KeyCatalog
    private var cachedCapabilities: Capabilities?

    public init(backend: SMCBackend, catalog: KeyCatalog = KeyCatalog()) {
        self.backend = backend
        self.catalog = catalog
    }

    public func capabilities() -> Capabilities {
        if let cachedCapabilities {
            return cachedCapabilities
        }
        let detected = catalog.detectCapabilities(using: backend)
        cachedCapabilities = detected
        return detected
    }

    public func snapshot() -> SensorSnapshot {
        let capabilities = capabilities()
        return SensorSnapshot(
            timestamp: Date(),
            capabilities: capabilities,
            temperatures: readTemperatures(keys: capabilities.temperatureKeys),
            fans: readFans(capabilities.fans),
            battery: readNamedReadings([
                ("BUIC", "Charge", "%", 1),
                ("B0AC", "Current", "A", 0.001),  // si16 in mA
                ("B0AV", "Voltage", "V", 0.001),  // ui16 in mV
                ("PPBR", "Battery Power", "W", 1),
                ("AC-W", "Adapter Power", "W", 1)
            ], availableKeys: capabilities.batteryKeys),
            power: readNamedReadings([
                ("PDTR", "Package Power", "W", 1),
                ("PSTR", "System Power", "W", 1),
                ("ID0R", "Input Current", "A", 1),
                ("VD0R", "Input Voltage", "V", 1)
            ], availableKeys: capabilities.powerKeys)
        )
    }

    private func readTemperatures(keys: [String]) -> [TemperatureReading] {
        keys.compactMap { key in
            guard
                let value = try? backend.readValue(key),
                let decoded = value.decoded?.doubleValue
            else {
                return nil
            }

            return TemperatureReading(
                key: key,
                group: String(key.prefix(2)),
                celsius: decoded,
                dataType: value.info.dataTypeString
            )
        }
        .sorted { lhs, rhs in
            if lhs.group == rhs.group {
                return lhs.key < rhs.key
            }
            return lhs.group < rhs.group
        }
    }

    private func readFans(_ fans: [FanCapability]) -> [FanReading] {
        fans.map { fan in
            FanReading(
                index: fan.index,
                actualRPM: numericValue(fan.actualKey),
                targetRPM: numericValue(fan.targetKey),
                minimumRPM: numericValue(fan.minimumKey),
                maximumRPM: numericValue(fan.maximumKey),
                mode: fan.modeKey.flatMap { fanMode($0) }
            )
        }
    }

    private func readNamedReadings(_ readings: [(String, String, String, Double)], availableKeys: [String]) -> [NamedReading] {
        let available = Set(availableKeys)
        return readings.compactMap { key, name, unit, scale in
            guard available.contains(key), let value = try? backend.readValue(key) else {
                return nil
            }

            switch value.decoded {
            case .number(let number):
                return NamedReading(key: key, name: name, value: number * scale, rawBytes: nil, unit: unit, dataType: value.info.dataTypeString)
            case .unsigned(let unsigned):
                return NamedReading(key: key, name: name, value: Double(unsigned) * scale, rawBytes: nil, unit: unit, dataType: value.info.dataTypeString)
            case .bytes(let bytes):
                return NamedReading(key: key, name: name, value: nil, rawBytes: bytes, unit: nil, dataType: value.info.dataTypeString)
            case nil:
                return nil
            }
        }
    }

    private func numericValue(_ key: String) -> Double? {
        guard let value = try? backend.readValue(key) else {
            return nil
        }
        return value.decoded?.doubleValue
    }

    private func fanMode(_ key: String) -> String? {
        guard let rawValue = numericValue(key) else {
            return nil
        }

        switch Int(rawValue) {
        case 0:
            return "auto"
        case 1:
            return "manual"
        case 3:
            return "system"
        default:
            return "unknown(\(Int(rawValue)))"
        }
    }
}
