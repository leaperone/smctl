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
        #expect(store.profileChoices.map(\.name) == ["auto", "silent", "balanced", "performance", "night"])
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

@MainActor
struct MenuBarRendererTests {
    private let entries = [
        MenuBarState.Entry(item: .cpu, label: "CPU", value: "52°"),
        MenuBarState.Entry(item: .fan, label: "FAN", value: "999")
    ]

    @Test func stackedIsNarrowerThanInlineAndFitsTheMenuBar() {
        let image = MenuBarRenderer.stackedImage(entries: entries, symbol: "fan")
        #expect(image.isTemplate)
        #expect(image.size.height <= NSStatusBar.system.thickness)
        #expect(image.size.width < 70)
    }

    @Test func widthDoesNotChangeWhenValuesGrow() {
        let small = MenuBarRenderer.stackedImage(entries: entries, symbol: nil)
        let large = MenuBarRenderer.stackedImage(entries: [
            MenuBarState.Entry(item: .cpu, label: "CPU", value: "104°"),
            MenuBarState.Entry(item: .fan, label: "FAN", value: "4900")
        ], symbol: nil)
        #expect(small.size.width == large.size.width)
    }

    @Test func extraItemsAddColumns() {
        let two = MenuBarRenderer.stackedImage(entries: entries, symbol: nil)
        let three = MenuBarRenderer.stackedImage(entries: entries + [MenuBarState.Entry(item: .gpu, label: "GPU", value: "41°")], symbol: nil)
        #expect(three.size.width > two.size.width)
    }
}

struct ServiceInstallerTests {
    @Test func shellQuotingSurvivesSpacesAndQuotes() {
        #expect(ServiceInstaller.shellCommand(["/Applications/My Apps/Pulse.app/pulse", "daemon", "install"])
            == "'/Applications/My Apps/Pulse.app/pulse' 'daemon' 'install'")
        #expect(ServiceInstaller.shellCommand(["it's"]) == "'it'\\''s'")
    }

    @Test func appleScriptLiteralEscapesQuotesAndBackslashes() {
        #expect(ServiceInstaller.appleScriptLiteral(#"say "hi" \ there"#) == #""say \"hi\" \\ there""#)
    }
}
