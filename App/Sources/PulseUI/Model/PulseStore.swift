import Foundation
import Observation
import PolicyEngine
import SMCtlClient
import SMCtlProtocol

public enum DaemonState: Equatable, Sendable {
    case connecting
    case connected(version: String)
    /// The daemon is not reachable; the app shows read-only data from the SMC.
    case unavailable(message: String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public struct HistorySample: Identifiable, Equatable, Sendable {
    public var date: Date
    public var cpuAverage: Double?
    public var cpuMaximum: Double?
    public var fanPercent: Double?
    public var id: Date { date }

    public init(date: Date, cpuAverage: Double?, cpuMaximum: Double?, fanPercent: Double?) {
        self.date = date
        self.cpuAverage = cpuAverage
        self.cpuMaximum = cpuMaximum
        self.fanPercent = fanPercent
    }
}

/// A profile the user can pick in the menu.
public struct ProfileChoice: Identifiable, Equatable, Sendable {
    public var name: String
    public var title: String
    public var systemImage: String
    public var builtin: Bool
    public var id: String { name }
}

/// App state: polls the daemon, keeps a short history for the charts and runs
/// user actions. All blocking work happens off the main actor.
@MainActor
@Observable
public final class PulseStore {
    /// 5 minutes at the idle 2 s cadence.
    public static let historyLength = 150
    static let curvesRefreshInterval: TimeInterval = 30
    static let conflictsRefreshInterval: TimeInterval = 60

    public private(set) var telemetry: TelemetryDTO?
    public private(set) var daemonState: DaemonState = .connecting
    public private(set) var curves: [FanCurveEntryDTO] = []
    public private(set) var invalidCurves: [String: String] = [:]
    public private(set) var conflicts: [FanControlConflict] = []
    public private(set) var history: [HistorySample] = []
    public private(set) var busyProfile: String?
    /// Only reassigned when it changes, so the menu bar item redraws rarely.
    public private(set) var menuBar = MenuBarState()
    public var actionError: String?
    /// Called on each change of the daemon's safety guard (see `SafetyNotifier`).
    @ObservationIgnored private var safetyObservers: [@MainActor (SafetyEvent) -> Void] = []
    /// Called after each poll (automatic profile switching).
    @ObservationIgnored public var onRefresh: (@MainActor () -> Void)?

    public func observeSafety(_ observer: @escaping @MainActor (SafetyEvent) -> Void) {
        safetyObservers.append(observer)
    }

    func emitSafetyEvent(_ event: SafetyEvent) {
        safetyObservers.forEach { $0(event) }
    }
    @ObservationIgnored private var safetyTracker = SafetyAlertTracker()

    @ObservationIgnored let service: any PulseService
    @ObservationIgnored private let fallback: DirectSensorService?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isPopoverOpen = false
    @ObservationIgnored private var lastCurvesRefresh: Date?
    @ObservationIgnored private var lastConflictsRefresh: Date?
    /// Hot-spot sensors jump several degrees per second; the menu bar shows an
    /// ~8 s average, which reads calmer and redraws the status item less often.
    @ObservationIgnored private var menuBarAverage = TemperatureSmoother(timeConstantSeconds: 8)
    @ObservationIgnored private var menuBarMaximum = TemperatureSmoother(timeConstantSeconds: 8)
    @ObservationIgnored private var menuBarGPUAverage = TemperatureSmoother(timeConstantSeconds: 8)
    @ObservationIgnored private var menuBarGPUMaximum = TemperatureSmoother(timeConstantSeconds: 8)

    /// New releases and the service's version (see `UpdateCenter`).
    public let updates: UpdateCenter
    /// The stress test running from Settings, if any. It owns the fan profile
    /// until it ends: switching would make its readings measure another curve.
    public private(set) var stressTest: StressTestModel?

    func stressTestDidStart(_ model: StressTestModel) { stressTest = model }
    func stressTestDidEnd(_ model: StressTestModel) {
        if stressTest === model { stressTest = nil }
    }

    /// The popover's profiles: fan control, and no stress test running.
    public var canSwitchProfile: Bool { canControlFans && stressTest == nil }

    public init(service: any PulseService = DaemonPulseService(), fallback: DirectSensorService? = DirectSensorService(),
                updates: UpdateCenter? = nil) {
        self.service = service
        self.fallback = fallback
        self.updates = updates ?? .inert()
        self.updates.onServiceUpdated = { [weak self] in await self?.refresh(forceLists: true) }
    }

    // MARK: Polling

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// PULSE_POLL_INTERVAL (seconds) overrides the cadence, for profiling.
    @ObservationIgnored private let pollOverride: Duration? = {
        guard let value = Double(ProcessInfo.processInfo.environment["PULSE_POLL_INTERVAL"] ?? "") else { return nil }
        return .milliseconds(Int(max(0.5, value) * 1000))
    }()

    /// The daemon's sensor interval on the adapter (1–5 s), nil without a
    /// daemon or from one that predates the setting.
    public var samplingInterval: Int? {
        daemonState.isConnected ? telemetry?.samplingInterval : nil
    }

    /// The interval on battery; nil when it follows the adapter's.
    public var batterySamplingInterval: Int? {
        daemonState.isConnected ? telemetry?.batterySamplingInterval : nil
    }

    /// The interval in effect now (depends on the power source).
    public var currentSamplingInterval: Int? {
        daemonState.isConnected ? telemetry?.currentSamplingInterval : nil
    }

    /// Polls follow the daemon's interval: asking more often would only
    /// return the same readings. Without one, 2 s (1 s with the popover open).
    var pollInterval: Duration {
        if let pollOverride { return pollOverride }
        if let currentSamplingInterval { return .seconds(currentSamplingInterval) }
        return isPopoverOpen ? .seconds(1) : .seconds(2)
    }

    public func popoverDidOpen() {
        isPopoverOpen = true
        Task { await refresh(forceLists: true) }
    }

    public func popoverDidClose() {
        isPopoverOpen = false
    }

    public func refresh(forceLists: Bool = false, now: Date = Date()) async {
        let service = self.service
        let result = await Task.detached { Result { try service.telemetry() } }.value
        switch result {
        case .success(let telemetry):
            self.telemetry = telemetry
            if let event = safetyTracker.update(telemetry) { emitSafetyEvent(event) }
            assignIfChanged(\.daemonState, .connected(version: telemetry.daemonVersion))
            updates.observe(daemonVersion: telemetry.daemonVersion, latestFromDaemon: telemetry.latestVersion, now: now)
        case .failure(let error):
            updates.observe(daemonVersion: nil, latestFromDaemon: nil, now: now)
            assignIfChanged(\.daemonState, .unavailable(message: Self.describe(error)))
            assignIfChanged(\.curves, [])
            assignIfChanged(\.invalidCurves, [:])
            if let fallback {
                telemetry = try? await Task.detached { try fallback.telemetry() }.value
            }
        }
        appendHistory(now: now)
        updateMenuBar(now: now)
        onRefresh?()

        if daemonState.isConnected, forceLists || isStale(lastCurvesRefresh, Self.curvesRefreshInterval, now: now) {
            await refreshCurves(now: now)
        }
        if forceLists || isStale(lastConflictsRefresh, Self.conflictsRefreshInterval, now: now) {
            assignIfChanged(\.conflicts, await Task.detached { service.conflicts() }.value)
            lastConflictsRefresh = now
        }
    }

    private func refreshCurves(now: Date) async {
        let service = self.service
        if let list = try? await Task.detached(operation: { try service.curves() }).value {
            assignIfChanged(\.curves, list.curves)
            assignIfChanged(\.invalidCurves, list.invalid)
            lastCurvesRefresh = now
        }
    }

    /// Observation notifies on every assignment, even of an equal value; skip
    /// those so views that read slow-changing state do not redraw each tick.
    private func assignIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<PulseStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private func isStale(_ date: Date?, _ interval: TimeInterval, now: Date) -> Bool {
        guard let date else { return true }
        return now.timeIntervalSince(date) >= interval
    }

    private func updateMenuBar(now: Date) {
        var smoothedCPU = cpu
        if let average = cpu?.averageCelsius { smoothedCPU?.averageCelsius = menuBarAverage.update(average, now: now) }
        if let maximum = cpu?.maximumCelsius { smoothedCPU?.maximumCelsius = menuBarMaximum.update(maximum, now: now) }
        var smoothedGPU = gpu
        if let average = gpu?.averageCelsius { smoothedGPU?.averageCelsius = menuBarGPUAverage.update(average, now: now) }
        if let maximum = gpu?.maximumCelsius { smoothedGPU?.maximumCelsius = menuBarGPUMaximum.update(maximum, now: now) }
        let next = menuBar.updated(
            cpu: smoothedCPU,
            gpu: smoothedGPU,
            fan: fans.first,
            powerWatts: powerWatts,
            curveActive: daemonState.isConnected && activeProfile != "auto",
            latched: safetyLatched
        )
        if next != menuBar {
            menuBar = next
        }
    }

    private func appendHistory(now: Date) {
        guard telemetry != nil else { return }
        history.append(HistorySample(date: now, cpuAverage: cpu?.averageCelsius, cpuMaximum: cpu?.maximumCelsius, fanPercent: fans.first.flatMap(Self.percent)))
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }

    // MARK: Actions

    public func activate(_ profile: String) async {
        guard busyProfile == nil, stressTest == nil else { return }
        busyProfile = profile
        defer { busyProfile = nil }
        await perform { try $0.activate(profile: profile) }
    }

    @discardableResult
    public func save(_ spec: FanCurveSpec, activate: Bool) async -> Bool {
        await perform { try $0.upsert(spec, activate: activate) }
    }

    @discardableResult
    public func setSamplingInterval(_ seconds: Int?, onBattery: Bool = false) async -> Bool {
        await perform { try $0.setSamplingInterval(seconds, onBattery: onBattery) }
    }

    @discardableResult
    public func delete(curve name: String) async -> Bool {
        await perform { try $0.delete(curve: name) }
    }

    /// Saves a copy of `spec` under a new name and returns that name.
    public func duplicate(_ spec: FanCurveSpec) async -> String? {
        var copy = spec
        let label = CurveNaming.copyLabel(spec.label ?? spec.name.capitalized, existing: Set(curveEntries.compactMap(\.spec.label)))
        copy.label = label
        copy.name = CurveNaming.uniqueName(base: label, existing: curveNames)
        return await save(copy, activate: false) ? copy.name : nil
    }

    /// Saves a new curve (Balanced's shape, as a sensible start) and returns its name.
    public func createCurve() async -> String? {
        let labels = Set(curveEntries.compactMap(\.spec.label))
        var label = "Custom"
        var index = 2
        while labels.contains(label) { label = "Custom \(index)"; index += 1 }
        var spec = FanCurvePresets.balanced
        spec.label = label
        spec.name = CurveNaming.uniqueName(base: label, existing: curveNames)
        return await save(spec, activate: false) ? spec.name : nil
    }

    /// Changes a user curve's display label; its technical name stays the same.
    @discardableResult
    public func rename(curve name: String, to label: String) async -> Bool {
        guard var spec = curveEntries.first(where: { $0.spec.name == name && !$0.builtin })?.spec,
              let label = CurveNaming.cleanLabel(label) else { return false }
        spec.label = label
        return await save(spec, activate: false)
    }

    @discardableResult
    private func perform(_ action: @escaping @Sendable (any PulseService) throws -> Void) async -> Bool {
        let service = self.service
        let result = await Task.detached { Result { try action(service) } }.value
        let succeeded: Bool
        if case .failure(let error) = result {
            actionError = Self.describe(error)
            succeeded = false
        } else {
            actionError = nil
            succeeded = true
        }
        await refresh(forceLists: true)
        return succeeded
    }

    // MARK: Derived state

    public var groups: [TemperatureGroupSummary] {
        TemperatureGroupSummary.summarize(telemetry?.temperatures ?? [])
    }

    /// Groups for the popover. Some Apple silicon Macs (M1 Pro) expose `TC*`
    /// sensors next to the `Tp*` hot-spots; both are labelled CPU, so the `TC`
    /// row is hidden when `Tp` exists, matching `cpu` and the menu bar.
    public var displayGroups: [TemperatureGroupSummary] {
        let all = groups
        guard all.contains(where: { $0.group == "Tp" }) else { return all }
        return all.filter { $0.group != "TC" }
    }

    /// CPU hot-spots on Apple Silicon (`Tp*`), Intel CPU sensors (`TC*`) otherwise.
    public var cpu: TemperatureGroupSummary? {
        groups.first { $0.group == "Tp" } ?? groups.first { $0.group == "TC" }
    }

    public var gpu: TemperatureGroupSummary? {
        groups.first { $0.group == "Tg" } ?? groups.first { $0.group == "TG" }
    }

    /// Whole-system power (PSTR) when available, else the SoC package (PDTR).
    public var powerWatts: Double? {
        let power = telemetry?.power ?? []
        return (power.first { $0.key == "PSTR" } ?? power.first { $0.key == "PDTR" })?.value
    }

    public var fans: [FanStatusDTO] { telemetry?.fans ?? [] }

    public var activeProfile: String { telemetry?.profile ?? "auto" }

    /// Curves for the editor: the daemon's list, or the built-in presets
    /// (read-only) when the daemon is not reachable.
    public var curveEntries: [FanCurveEntryDTO] {
        if daemonState.isConnected, !curves.isEmpty { return curves }
        return FanCurvePresets.all.map { FanCurveEntryDTO(builtin: true, spec: $0) }
    }

    var curveNames: Set<String> { Set(curveEntries.map(\.spec.name)).union(invalidCurves.keys) }

    /// User curves can be created and changed only through the daemon.
    public var canEditCurves: Bool { daemonState.isConnected }

    public var canControlFans: Bool { daemonState.isConnected && !fans.isEmpty }

    /// Readings arrive but the Mac reports no fan (MacBook Air): monitoring only.
    public var isFanless: Bool { telemetry != nil && fans.isEmpty }

    public var safetyLatched: Bool { telemetry?.safety.latched ?? false }

    public var profileChoices: [ProfileChoice] {
        var choices = [ProfileChoice(name: "auto", title: "Auto", systemImage: "apple.logo", builtin: true)]
        choices += curves.map { entry in
            ProfileChoice(
                name: entry.spec.name,
                title: entry.spec.label ?? entry.spec.name.capitalized,
                systemImage: Self.symbol(for: entry.spec.name, builtin: entry.builtin),
                builtin: entry.builtin
            )
        }
        // smctl's RPM built-ins (quiet, full) are not listed but may be active.
        if !choices.contains(where: { $0.name == activeProfile }), activeProfile != "manual" {
            choices.append(ProfileChoice(name: activeProfile, title: activeProfile.capitalized, systemImage: "slider.horizontal.3", builtin: true))
        }
        return choices
    }

    public func title(forProfile name: String) -> String {
        if name == "manual" { return "Manual" }
        return profileChoices.first { $0.name == name }?.title ?? name.capitalized
    }

    // MARK: Formatting helpers

    nonisolated public static func percent(_ fan: FanStatusDTO) -> Double? {
        guard let actual = fan.actualRPM, let minimum = fan.minimumRPM, let maximum = fan.maximumRPM, maximum > minimum else {
            return nil
        }
        return FanSpeedRange(minimumRPM: minimum, maximumRPM: maximum).fraction(forRPM: actual) * 100
    }

    nonisolated static func symbol(for name: String, builtin: Bool) -> String {
        switch name {
        case "silent": return "moon.zzz"
        case "balanced": return "dial.medium"
        case "performance": return "flame"
        case "quiet": return "speaker.wave.1"
        case "full": return "tornado"
        default: return builtin ? "slider.horizontal.3" : "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let error = error as? SMCtlClientError {
            return error.localizedDescription
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
