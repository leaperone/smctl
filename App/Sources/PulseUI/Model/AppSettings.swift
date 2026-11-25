import Foundation
import SMCtlClient
import SMCtlProtocol

/// What the menu bar item shows.
public enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    case temperatureAndFan
    case temperature
    case fan
    case icon

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .temperatureAndFan: return "Temperature and fan"
        case .temperature: return "Temperature"
        case .fan: return "Fan speed"
        case .icon: return "Icon only"
        }
    }
}

/// Which CPU reading represents "the temperature" in the menu bar.
public enum TemperatureMetric: String, CaseIterable, Identifiable, Sendable {
    case cpuAverage
    case cpuMaximum

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpuAverage: return "CPU average"
        case .cpuMaximum: return "CPU hottest sensor"
        }
    }
}

public enum FanSpeedUnit: String, CaseIterable, Identifiable, Sendable {
    case rpm
    case percent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rpm: return "RPM"
        case .percent: return "Percent"
        }
    }
}

/// UserDefaults keys, shared by @AppStorage in views and by tests.
public enum SettingsKey {
    public static let menuBarStyle = "menuBarStyle"
    public static let temperatureMetric = "temperatureMetric"
    public static let fanSpeedUnit = "fanSpeedUnit"
}

/// What the menu bar item displays, with deadbands so the item only redraws
/// when the visible text changes. macOS redraws every status item replica (per
/// display and appearance) on each change, which dominated the app's CPU use.
public struct MenuBarState: Equatable, Sendable {
    public static let temperatureDeadband = 0.75
    public static let rpmDeadband = 25.0
    public static let percentDeadband = 1.0

    public var cpuAverage: Double?
    public var cpuMaximum: Double?
    public var fanRPM: Double?
    public var fanPercent: Double?
    public var hasFan = false
    public var curveActive = false
    public var latched = false

    public init() {}

    /// The next state: values only move once they leave their deadband.
    public func updated(cpu: TemperatureGroupSummary?, fan: FanStatusDTO?, curveActive: Bool, latched: Bool) -> MenuBarState {
        var next = self
        next.cpuAverage = Self.damp(cpuAverage, cpu?.averageCelsius, Self.temperatureDeadband)
        next.cpuMaximum = Self.damp(cpuMaximum, cpu?.maximumCelsius, Self.temperatureDeadband)
        next.fanRPM = Self.damp(fanRPM, fan?.actualRPM, Self.rpmDeadband)
        next.fanPercent = Self.damp(fanPercent, fan.flatMap(PulseStore.percent), Self.percentDeadband)
        next.hasFan = fan != nil
        next.curveActive = curveActive
        next.latched = latched
        return next
    }

    static func damp(_ shown: Double?, _ raw: Double?, _ deadband: Double) -> Double? {
        guard let raw, raw.isFinite else { return nil }
        guard let shown, abs(raw - shown) < deadband else { return raw }
        return shown
    }

    public func text(style: MenuBarStyle, metric: TemperatureMetric, unit: FanSpeedUnit) -> String {
        let temperature = Format.temperature(metric == .cpuAverage ? cpuAverage : cpuMaximum)
        let speed = unit == .rpm ? Format.rpm(fanRPM) : Format.percent(fanPercent)
        switch style {
        case .temperatureAndFan: return hasFan ? "\(temperature)  \(speed)" : temperature
        case .temperature: return temperature
        case .fan: return speed
        case .icon: return ""
        }
    }
}

public enum Format {
    public static func temperature(_ celsius: Double?, decimals: Int = 0) -> String {
        guard let celsius, celsius.isFinite else { return "–" }
        return String(format: "%.\(decimals)f°", celsius)
    }

    public static func rpm(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return "\(Int(value.rounded()))"
    }

    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return "\(Int(value.rounded()))%"
    }

    public static func fanSpeed(_ fan: FanStatusDTO?, unit: FanSpeedUnit) -> String {
        guard let fan else { return "–" }
        switch unit {
        case .rpm: return rpm(fan.actualRPM)
        case .percent: return percent(PulseStore.percent(fan))
        }
    }
}
