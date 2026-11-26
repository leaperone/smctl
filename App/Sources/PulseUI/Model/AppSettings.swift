import Foundation
import SMCtlClient
import SMCtlProtocol

/// How the menu bar item arranges its readings.
public enum MenuBarLayout: String, CaseIterable, Identifiable, Sendable {
    /// One line: `52°  1450`.
    case inline
    /// Two small lines per column (`CPU 52°` over `FAN 1450`): narrower.
    case stacked

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inline: return "Inline"
        case .stacked: return "Stacked"
        }
    }
}

/// A reading that can appear in the menu bar.
public enum MenuBarItem: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case gpu
    case fan
    case power

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: return "CPU temperature"
        case .gpu: return "GPU temperature"
        case .fan: return "Fan speed"
        case .power: return "Power draw"
        }
    }

    public var shortLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .fan: return "FAN"
        case .power: return "PWR"
        }
    }

    var isTemperature: Bool { self == .cpu || self == .gpu }
}

/// Which reading of a sensor group represents its temperature.
public enum TemperatureMetric: String, CaseIterable, Identifiable, Sendable {
    case cpuAverage
    case cpuMaximum

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpuAverage: return "Average"
        case .cpuMaximum: return "Hottest sensor"
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

/// The glyph at the start of the menu bar item.
public enum MenuBarIcon: String, CaseIterable, Identifiable, Sendable {
    /// A dot coloured by temperature that beats faster as the Mac heats up.
    case pulse
    /// The heartbeat trace from the app icon.
    case heartbeat
    case fan
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pulse: return "Pulse dot"
        case .heartbeat: return "Heartbeat"
        case .fan: return "Fan"
        case .none: return "None"
        }
    }

    /// Icons that can beat with the temperature.
    public var canAnimate: Bool { self == .pulse || self == .heartbeat }
}

/// When the pulse icon beats. Each beat redraws every status item replica
/// (~15 ms of AppKit work on macOS 26; "always" measured at ~2.5% CPU), so
/// beating only when warm keeps the idle cost at zero.
public enum HeartbeatMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case whenWarm
    case always

    public static let warmThresholdCelsius = 65.0

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .whenWarm: return "When warm"
        case .always: return "Always"
        }
    }

    public func beats(celsius: Double?) -> Bool {
        switch self {
        case .off: return false
        case .always: return true
        case .whenWarm: return (celsius ?? 0) >= Self.warmThresholdCelsius
        }
    }
}

/// UserDefaults keys, shared by @AppStorage in views and the status item.
public enum SettingsKey {
    public static let menuBarIcon = "menuBarIcon"
    public static let menuBarHeartbeat = "menuBarHeartbeat"
    public static let menuBarMonochrome = "menuBarMonochrome"
    public static let menuBarShowsReadings = "menuBarShowsReadings"
    public static let menuBarLayout = "menuBarLayout"
    public static let menuBarItems = "menuBarItems"
    public static let temperatureMetric = "temperatureMetric"
    public static let fanSpeedUnit = "fanSpeedUnit"
    /// Notify when the safety guard hands the fans back to macOS (default on).
    public static let safetyNotifications = "safetyNotifications"
}

/// Everything that decides what the menu bar item looks like.
public struct MenuBarConfiguration: Equatable, Sendable {
    public static let defaultItems: [MenuBarItem] = [.cpu, .fan]

    public var icon: MenuBarIcon
    public var heartbeat: HeartbeatMode
    /// No colour in the menu bar: the pulse dot follows the menu bar's ink.
    public var monochrome: Bool
    public var showsReadings: Bool
    public var layout: MenuBarLayout
    public var items: [MenuBarItem]
    public var metric: TemperatureMetric
    public var unit: FanSpeedUnit

    public init(
        icon: MenuBarIcon = .pulse,
        heartbeat: HeartbeatMode = .whenWarm,
        monochrome: Bool = false,
        showsReadings: Bool = true,
        layout: MenuBarLayout = .stacked,
        items: [MenuBarItem] = defaultItems,
        metric: TemperatureMetric = .cpuAverage,
        unit: FanSpeedUnit = .rpm
    ) {
        self.icon = icon
        self.heartbeat = heartbeat
        self.monochrome = monochrome
        self.showsReadings = showsReadings
        self.layout = layout
        self.items = items
        self.metric = metric
        self.unit = unit
    }

    public static func load(from defaults: UserDefaults = .standard) -> MenuBarConfiguration {
        MenuBarConfiguration(
            icon: defaults.string(forKey: SettingsKey.menuBarIcon).flatMap(MenuBarIcon.init) ?? .pulse,
            heartbeat: defaults.string(forKey: SettingsKey.menuBarHeartbeat).flatMap(HeartbeatMode.init) ?? .whenWarm,
            monochrome: defaults.bool(forKey: SettingsKey.menuBarMonochrome),
            showsReadings: defaults.object(forKey: SettingsKey.menuBarShowsReadings) as? Bool ?? true,
            layout: defaults.string(forKey: SettingsKey.menuBarLayout).flatMap(MenuBarLayout.init) ?? .stacked,
            items: defaults.string(forKey: SettingsKey.menuBarItems).map(decodeItems) ?? defaultItems,
            metric: defaults.string(forKey: SettingsKey.temperatureMetric).flatMap(TemperatureMetric.init) ?? .cpuAverage,
            unit: defaults.string(forKey: SettingsKey.fanSpeedUnit).flatMap(FanSpeedUnit.init) ?? .rpm
        )
    }

    /// The icon actually drawn: never leave the item empty.
    public func effectiveIcon(hasReadings: Bool) -> MenuBarIcon {
        icon == .none && !hasReadings ? .pulse : icon
    }

    /// Stored as `cpu,fan`; kept in the canonical order of `MenuBarItem.allCases`.
    public static func decodeItems(_ text: String) -> [MenuBarItem] {
        let names = Set(text.split(separator: ",").map { String($0) })
        return MenuBarItem.allCases.filter { names.contains($0.rawValue) }
    }

    public static func encodeItems(_ items: [MenuBarItem]) -> String {
        MenuBarItem.allCases.filter(items.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// What the menu bar item displays, with deadbands so the item only redraws
/// when the visible text changes. macOS redraws every status item replica (per
/// display and appearance) on each change.
public struct MenuBarState: Equatable, Sendable {
    public static let temperatureDeadband = 0.75
    public static let rpmDeadband = 25.0
    public static let percentDeadband = 1.0
    public static let powerDeadband = 0.5

    public var cpuAverage: Double?
    public var cpuMaximum: Double?
    public var gpuAverage: Double?
    public var gpuMaximum: Double?
    public var fanRPM: Double?
    public var fanPercent: Double?
    public var powerWatts: Double?
    public var hasFan = false
    public var curveActive = false
    public var latched = false

    public init() {}

    /// The next state: values only move once they leave their deadband.
    public func updated(
        cpu: TemperatureGroupSummary?,
        gpu: TemperatureGroupSummary? = nil,
        fan: FanStatusDTO?,
        powerWatts: Double? = nil,
        curveActive: Bool,
        latched: Bool
    ) -> MenuBarState {
        var next = self
        next.cpuAverage = Self.damp(cpuAverage, cpu?.averageCelsius, Self.temperatureDeadband)
        next.cpuMaximum = Self.damp(cpuMaximum, cpu?.maximumCelsius, Self.temperatureDeadband)
        next.gpuAverage = Self.damp(gpuAverage, gpu?.averageCelsius, Self.temperatureDeadband)
        next.gpuMaximum = Self.damp(gpuMaximum, gpu?.maximumCelsius, Self.temperatureDeadband)
        next.fanRPM = Self.damp(fanRPM, fan?.actualRPM, Self.rpmDeadband)
        next.fanPercent = Self.damp(fanPercent, fan.flatMap(PulseStore.percent), Self.percentDeadband)
        next.powerWatts = Self.damp(self.powerWatts, powerWatts, Self.powerDeadband)
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

    public struct Entry: Equatable, Sendable {
        public var item: MenuBarItem
        public var label: String
        public var value: String
    }

    /// The readings to show, in order. A fan item is skipped on fanless Macs.
    public func entries(_ configuration: MenuBarConfiguration) -> [Entry] {
        guard configuration.showsReadings else { return [] }
        return configuration.items.compactMap { item in
            let value: String
            switch item {
            case .cpu:
                value = Format.temperature(configuration.metric == .cpuAverage ? cpuAverage : cpuMaximum)
            case .gpu:
                value = Format.temperature(configuration.metric == .cpuAverage ? gpuAverage : gpuMaximum)
            case .fan:
                guard hasFan else { return nil }
                value = configuration.unit == .rpm ? Format.rpm(fanRPM) : Format.percent(fanPercent)
            case .power:
                value = Format.watts(powerWatts)
            }
            return Entry(item: item, label: item.shortLabel, value: value)
        }
    }

    /// Single-line text. Labels are added once two temperatures could be confused.
    public func inlineText(_ configuration: MenuBarConfiguration) -> String {
        let entries = entries(configuration)
        let labelled = entries.filter { $0.item.isTemperature }.count > 1
        return entries.map { labelled && $0.item.isTemperature ? "\($0.label) \($0.value)" : $0.value }
            .joined(separator: "  ")
    }

    public var symbol: String {
        latched ? "exclamationmark.triangle.fill" : (curveActive ? "fan.fill" : "fan")
    }

    /// Temperature that drives the pulse: the smoothed CPU average.
    public var heatCelsius: Double? { cpuAverage }

    /// Heart rate of the pulse icon: 40 bpm at 45 °C or below, 120 bpm at 95 °C or above.
    public static func beatsPerMinute(celsius: Double?) -> Double {
        guard let celsius, celsius.isFinite else { return 60 }
        let fraction = min(1, max(0, (celsius - 45) / 50))
        return 40 + fraction * 80
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

    public static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return value < 10 ? String(format: "%.1fW", value) : String(format: "%.0fW", value)
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
