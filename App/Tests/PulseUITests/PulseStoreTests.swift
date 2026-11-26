import Foundation
import PolicyEngine
import SMCtlClient
import SMCtlProtocol
import AppKit
import Testing
@testable import PulseUI

@MainActor
struct PulseStoreTests {
    @Test func connectedStoreExposesTelemetryCurvesAndHistory() async {
        let store = await PulseStore.preview(samples: 5)
        #expect(store.daemonState == .connected(version: "0.2.4"))
        #expect(store.activeProfile == "balanced")
        #expect(store.cpu?.label == "CPU")
        #expect(store.groups.map(\.label) == ["CPU", "GPU", "Board"])
        #expect(store.history.count == 5)
        #expect(store.canControlFans)
        #expect(store.profileChoices.map(\.name) == ["auto", "silent", "balanced", "performance", "night", "steady"])
        #expect(store.title(forProfile: "night") == "Night")
    }

    @Test func historyIsBounded() async {
        let store = await PulseStore.preview(samples: PulseStore.historyLength + 20)
        #expect(store.history.count == PulseStore.historyLength)
        #expect(store.history.map(\.date) == store.history.map(\.date).sorted())
    }

    @Test func unavailableDaemonIsReadOnly() async {
        let store = PulseStore(service: SampleService(failing: true), fallback: nil)
        await store.refresh()
        guard case .unavailable(let message) = store.daemonState else {
            Issue.record("expected unavailable, got \(store.daemonState)")
            return
        }
        #expect(message.contains("not running"))
        #expect(!store.canControlFans)
        #expect(store.curves.isEmpty)
    }

    @Test func activatingAProfileRefreshesState() async {
        let service = SampleService(profile: "auto")
        let store = PulseStore(service: service, fallback: nil)
        await store.refresh(forceLists: true)
        await store.activate("performance")
        #expect(store.activeProfile == "performance")
        #expect(store.actionError == nil)
        #expect(store.busyProfile == nil)
    }

    @Test func failedActionsSurfaceAnError() async {
        let store = PulseStore(service: SampleService(), fallback: nil)
        await store.refresh(forceLists: true)
        await store.activate("missing")
        #expect(store.actionError?.contains("not configured") == true)
        #expect(store.activeProfile == "balanced")
    }

    @Test func savingAndDeletingCurves() async throws {
        let store = PulseStore(service: SampleService(), fallback: nil)
        await store.refresh(forceLists: true)
        let spec = FanCurveSpec(name: "work", shape: try FanCurveShape(kind: .linear, startCelsius: 60, endCelsius: 90))
        await store.save(spec, activate: true)
        #expect(store.activeProfile == "work")
        #expect(store.curves.contains { $0.spec.name == "work" && !$0.builtin })
        await store.delete(curve: "work")
        #expect(store.activeProfile == "auto")
        #expect(!store.curves.contains { $0.spec.name == "work" })
    }

    @Test func unknownActiveProfileStillAppearsAsAChoice() async {
        let store = PulseStore(service: SampleService(profile: "auto"), fallback: nil)
        await store.refresh(forceLists: true)
        #expect(!store.profileChoices.contains { $0.name == "quiet" })
        // smctl's RPM built-in "quiet" is not listed by the daemon but can be active.
        let quiet = PulseStore(service: QuietService(), fallback: nil)
        await quiet.refresh(forceLists: true)
        #expect(quiet.profileChoices.last?.name == "quiet")
    }

    @Test func popoverHidesTCWhenTpHotSpotsExist() async {
        let store = PulseStore(service: SensorsService(groups: ["Tp", "TC", "Tg"]), fallback: nil)
        await store.refresh()
        #expect(store.groups.map(\.group) == ["Tp", "TC", "Tg"])
        #expect(store.displayGroups.map(\.group) == ["Tp", "Tg"])
        #expect(store.cpu?.group == "Tp")
    }

    @Test func popoverKeepsTCWithoutTp() async {
        let store = PulseStore(service: SensorsService(groups: ["TC", "TG"]), fallback: nil)
        await store.refresh()
        #expect(store.displayGroups.map(\.group) == ["TC", "TG"])
        #expect(store.cpu?.group == "TC")
    }

    @Test func conflictsAreReported() async {
        let conflict = FanControlConflict(product: "TG Pro", evidence: "process TG Pro", running: true)
        let store = PulseStore(service: SampleService(conflicts: [conflict]), fallback: nil)
        await store.refresh(forceLists: true)
        #expect(store.conflicts == [conflict])
    }
}

/// Reports smctl's `quiet` profile as active.
private final class QuietService: PulseService, @unchecked Sendable {
    let base = SampleService(profile: "auto")
    func telemetry() throws -> TelemetryDTO {
        var telemetry = try base.telemetry()
        telemetry.profile = "quiet"
        return telemetry
    }
    func curves() throws -> FanCurveListDTO { try base.curves() }
    func activate(profile: String) throws {}
    func upsert(_ spec: FanCurveSpec, activate: Bool) throws {}
    func delete(curve name: String) throws {}
    func conflicts() -> [FanControlConflict] { [] }
}

/// Reports one 50 °C sensor per group, e.g. an M1 Pro's `Tp` and `TC`.
private final class SensorsService: PulseService, @unchecked Sendable {
    let base = SampleService(profile: "auto")
    let groups: [String]
    init(groups: [String]) { self.groups = groups }
    func telemetry() throws -> TelemetryDTO {
        var telemetry = try base.telemetry()
        telemetry.temperatures = groups.map { TemperatureDTO(key: "\($0)01", group: $0, celsius: 50) }
        return telemetry
    }
    func curves() throws -> FanCurveListDTO { try base.curves() }
    func activate(profile: String) throws {}
    func upsert(_ spec: FanCurveSpec, activate: Bool) throws {}
    func delete(curve name: String) throws {}
    func conflicts() -> [FanControlConflict] { [] }
}

struct MenuBarStateTests {
    private func cpu(_ average: Double, _ maximum: Double) -> TemperatureGroupSummary {
        TemperatureGroupSummary(group: "Tp", label: "CPU", averageCelsius: average, maximumCelsius: maximum,
                                hottestKey: "Tp3P", count: 12, inactiveCount: 0)
    }

    private func fan(_ rpm: Double) -> FanStatusDTO {
        FanStatusDTO(index: 0, actualRPM: rpm, targetRPM: rpm, minimumRPM: 1000, maximumRPM: 4900, mode: "manual")
    }

    private func gpu(_ average: Double) -> TemperatureGroupSummary {
        TemperatureGroupSummary(group: "Tg", label: "GPU", averageCelsius: average, maximumCelsius: average + 2,
                                hottestKey: "Tg0D", count: 4, inactiveCount: 0)
    }

    @Test func smallFluctuationsDoNotChangeTheState() {
        let first = MenuBarState().updated(cpu: cpu(55.2, 70), gpu: gpu(40), fan: fan(1450), powerWatts: 6.2, curveActive: true, latched: false)
        let jitter = first.updated(cpu: cpu(55.8, 70.5), gpu: gpu(40.6), fan: fan(1462), powerWatts: 6.5, curveActive: true, latched: false)
        #expect(jitter == first, "jitter inside the deadbands must not redraw the menu bar")
        let moved = first.updated(cpu: cpu(56.1, 70), gpu: gpu(40), fan: fan(1450), powerWatts: 6.2, curveActive: true, latched: false)
        #expect(moved != first)
        #expect(moved.cpuAverage == 56.1)
    }

    @Test func entriesFollowItemsMetricAndUnit() {
        let state = MenuBarState().updated(cpu: cpu(55.4, 71.6), gpu: gpu(41.2), fan: fan(2950), powerWatts: 6.24, curveActive: true, latched: false)
        let all = MenuBarConfiguration(layout: .stacked, items: MenuBarItem.allCases)
        #expect(state.entries(all).map(\.value) == ["55°", "41°", "2950", "6.2W"])
        #expect(state.entries(all).map(\.label) == ["CPU", "GPU", "FAN", "PWR"])
        let hottestPercent = MenuBarConfiguration(items: [.cpu, .fan], metric: .cpuMaximum, unit: .percent)
        #expect(state.entries(hottestPercent).map(\.value) == ["72°", "50%"])
    }

    @Test func inlineTextLabelsTemperaturesOnlyWhenAmbiguous() {
        let state = MenuBarState().updated(cpu: cpu(55.4, 71.6), gpu: gpu(41.2), fan: fan(2950), curveActive: true, latched: false)
        #expect(state.inlineText(MenuBarConfiguration(layout: .inline, items: [.cpu, .fan])) == "55°  2950")
        #expect(state.inlineText(MenuBarConfiguration(layout: .inline, items: [.cpu, .gpu, .fan])) == "CPU 55°  GPU 41°  2950")
    }

    @Test func fanlessMacsSkipTheFanAndMissingReadingsShowADash() {
        let fanless = MenuBarState().updated(cpu: cpu(40, 45), fan: nil, curveActive: false, latched: false)
        #expect(fanless.entries(MenuBarConfiguration(items: [.cpu, .fan])).map(\.item) == [.cpu])
        let empty = MenuBarState().updated(cpu: nil, fan: nil, curveActive: false, latched: false)
        #expect(empty.entries(MenuBarConfiguration(items: [.cpu, .gpu])).map(\.value) == ["–", "–"])
    }

    @Test func itemsAreStoredInCanonicalOrder() {
        #expect(MenuBarConfiguration.decodeItems("fan,cpu,bogus") == [.cpu, .fan])
        #expect(MenuBarConfiguration.encodeItems([.power, .cpu]) == "cpu,power")
        #expect(MenuBarConfiguration.decodeItems("") == [])
    }

    @Test func symbolReflectsControlAndSafety() {
        #expect(MenuBarState().updated(cpu: nil, fan: nil, curveActive: false, latched: false).symbol == "fan")
        #expect(MenuBarState().updated(cpu: nil, fan: nil, curveActive: true, latched: false).symbol == "fan.fill")
        #expect(MenuBarState().updated(cpu: nil, fan: nil, curveActive: true, latched: true).symbol == "exclamationmark.triangle.fill")
    }
}

struct MenuBarConfigurationTests {
    @Test func defaultsArePulseDotStackedCPUAndFanBeatingWhenWarm() {
        let configuration = MenuBarConfiguration.load(from: UserDefaults(suiteName: "pulse-tests-\(UUID())")!)
        #expect(configuration.icon == .pulse)
        #expect(configuration.heartbeat == .whenWarm)
        #expect(!configuration.monochrome)
        #expect(configuration.showsReadings)
        #expect(configuration.layout == .stacked)
        #expect(configuration.items == [.cpu, .fan])
    }

    @Test func monochromeIsReadFromDefaults() {
        let defaults = UserDefaults(suiteName: "pulse-tests-\(UUID())")!
        defaults.set(true, forKey: SettingsKey.menuBarMonochrome)
        #expect(MenuBarConfiguration.load(from: defaults).monochrome)
    }

    @Test func readingsCanBeHiddenAndTheItemIsNeverEmpty() {
        let state = MenuBarState().updated(cpu: nil, fan: nil, curveActive: false, latched: false)
        let iconOnly = MenuBarConfiguration(icon: .heartbeat, showsReadings: false)
        #expect(state.entries(iconOnly).isEmpty)
        #expect(iconOnly.effectiveIcon(hasReadings: false) == .heartbeat)
        let nothing = MenuBarConfiguration(icon: .none, showsReadings: false)
        #expect(nothing.effectiveIcon(hasReadings: false) == .pulse, "an empty item would be unclickable")
        #expect(MenuBarConfiguration(icon: .none).effectiveIcon(hasReadings: true) == .none)
    }

    @Test func heartbeatModesAndRate() {
        #expect(!HeartbeatMode.off.beats(celsius: 99))
        #expect(HeartbeatMode.always.beats(celsius: 40))
        #expect(!HeartbeatMode.whenWarm.beats(celsius: 64.9))
        #expect(HeartbeatMode.whenWarm.beats(celsius: 65))
        #expect(!HeartbeatMode.whenWarm.beats(celsius: nil))
        #expect(MenuBarState.beatsPerMinute(celsius: 30) == 40)
        #expect(MenuBarState.beatsPerMinute(celsius: 70) == 80)
        #expect(MenuBarState.beatsPerMinute(celsius: 110) == 120)
        #expect(MenuBarState.beatsPerMinute(celsius: 60) < MenuBarState.beatsPerMinute(celsius: 80))
    }
}

@MainActor
struct MenuBarRendererTests {
    private let entries = [
        MenuBarState.Entry(item: .cpu, label: "CPU", value: "52°"),
        MenuBarState.Entry(item: .fan, label: "FAN", value: "999")
    ]

    private func drawing(_ icon: MenuBarIcon = .pulse, _ entries: [MenuBarState.Entry]? = nil, layout: MenuBarLayout = .stacked,
                         celsius: Double = 55, beat: Double = 0) -> MenuBarDrawing {
        MenuBarDrawing(icon: icon, layout: layout, entries: entries ?? self.entries, heatCelsius: celsius, beat: beat)
    }

    @Test func stackedFitsTheMenuBarAndIsNarrowerThanInline() {
        let stacked = MenuBarRenderer.image(drawing())
        let inline = MenuBarRenderer.image(drawing(layout: .inline))
        #expect(stacked.size.height <= NSStatusBar.system.thickness)
        #expect(stacked.size.width < 70)
        #expect(stacked.size.width <= inline.size.width)
    }

    @Test func onlyTheColouredDotIsNotATemplate() {
        #expect(!MenuBarRenderer.image(drawing(.pulse)).isTemplate)
        #expect(MenuBarRenderer.image(drawing(.heartbeat)).isTemplate)
        #expect(MenuBarRenderer.image(drawing(.fan)).isTemplate)
        #expect(MenuBarRenderer.image(drawing(.none)).isTemplate)
        var mono = drawing(.pulse)
        mono.monochrome = true
        #expect(MenuBarRenderer.image(mono).isTemplate, "monochrome draws the dot in the menu bar ink")
        #expect(mono.dotColor == nil)
        #expect(drawing(.pulse).dotColor == MenuBarRenderer.heatColor(55))
        var latched = drawing(.pulse)
        latched.latched = true
        #expect(MenuBarRenderer.image(latched).isTemplate, "the warning replaces the dot")
    }

    @Test func widthIsStableAcrossBeatsAndGrowingValues() {
        let rest = MenuBarRenderer.image(drawing(beat: 0))
        let peak = MenuBarRenderer.image(drawing(beat: 1))
        #expect(rest.size.width == peak.size.width, "a beat must not shift the menu bar")
        let large = MenuBarRenderer.image(drawing(.pulse, [
            MenuBarState.Entry(item: .cpu, label: "CPU", value: "104°"),
            MenuBarState.Entry(item: .fan, label: "FAN", value: "4900")
        ]))
        #expect(rest.size.width == large.size.width)
    }

    @Test func extraItemsAddColumnsAndIconOnlyIsCompact() {
        let two = MenuBarRenderer.image(drawing())
        let three = MenuBarRenderer.image(drawing(.pulse, entries + [MenuBarState.Entry(item: .gpu, label: "GPU", value: "41°")]))
        #expect(three.size.width > two.size.width)
        #expect(MenuBarRenderer.image(drawing(.pulse, [])).size.width <= 16)
    }

    @Test func textIsCentredOnCapHeight() {
        let font = MenuBarRenderer.valueFont
        let baseline = (MenuBarRenderer.height + font.capHeight) / 2
        let top = baseline - font.capHeight
        #expect(abs(top - (MenuBarRenderer.height - baseline)) < 0.001, "equal space above caps and below baseline")
        let origin = MenuBarRenderer.origin(x: 0, baseline: baseline, font: font)
        #expect(abs(origin.y + font.ascender - baseline) < 0.001)
    }

    @Test func heatColoursFollowTemperature() {
        #expect(MenuBarRenderer.heatColor(50) == .systemGreen)
        #expect(MenuBarRenderer.heatColor(70) == .systemYellow)
        #expect(MenuBarRenderer.heatColor(90) == .systemOrange)
        #expect(MenuBarRenderer.heatColor(100) == .systemRed)
        #expect(MenuBarRenderer.heatColor(nil) == .systemGray)
    }
}

struct ServiceInstallerTests {
    @Test func osascriptErrorsReadPlainly() {
        #expect(ServiceInstaller.cleanMessage("0:120: execution error: pulse: daemon install failed (1)") == "pulse: daemon install failed")
        #expect(ServiceInstaller.cleanMessage("") == "Installation failed.")
    }

    @Test func shellQuotingSurvivesSpacesAndQuotes() {
        #expect(ServiceInstaller.shellCommand(["/Applications/My Apps/Pulse.app/pulse", "daemon", "install"])
            == "'/Applications/My Apps/Pulse.app/pulse' 'daemon' 'install'")
        #expect(ServiceInstaller.shellCommand(["it's"]) == "'it'\\''s'")
    }

    @Test func appleScriptLiteralEscapesQuotesAndBackslashes() {
        #expect(ServiceInstaller.appleScriptLiteral(#"say "hi" \ there"#) == #""say \"hi\" \\ there""#)
    }
}

struct MenuBarPreviewScheduleTests {
    @Test func firesOnlyAtBeatBoundaries() {
        let period = 1.0
        let start = Date(timeIntervalSinceReferenceDate: 100.5)
        let dates = Array(MenuBarPreview.BeatSchedule(period: period, paused: false)
            .entries(from: start, mode: .normal).prefix(5)).map(\.timeIntervalSinceReferenceDate)
        #expect(dates.count == 5)
        #expect(abs(dates[0] - 100.5) < 1e-9)
        #expect(abs(dates[1] - 101) < 1e-9)
        #expect(abs(dates[2] - 101.16) < 1e-9)
        #expect(abs(dates[3] - 102) < 1e-9)
        #expect(MenuBarPreview.isPeak(at: Date(timeIntervalSinceReferenceDate: 101.05), period: period))
        #expect(!MenuBarPreview.isPeak(at: Date(timeIntervalSinceReferenceDate: 101.16), period: period))
    }

    @Test func pausedScheduleFiresOnce() {
        let dates = Array(MenuBarPreview.BeatSchedule(period: 1, paused: true).entries(from: Date(), mode: .normal).prefix(3))
        #expect(dates.count == 1)
    }
}
