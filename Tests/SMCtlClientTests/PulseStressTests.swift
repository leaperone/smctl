import Foundation
import os
import Testing
import SMCtlProtocol
@testable import SMCtlClient

private func makeTelemetry(profile: String = "balanced", cpu: Double, gpu: Double = 0, rpm: Double, watts: Double = 5,
                       handedToSystem: Bool = false, latched: Bool = false) -> TelemetryDTO {
    TelemetryDTO(
        timestamp: Date(),
        daemonVersion: "test",
        profile: profile,
        temperatures: [
            TemperatureDTO(key: "Tp01", group: "Tp", celsius: cpu),
            TemperatureDTO(key: "TC0P", group: "TC", celsius: cpu - 5),
            TemperatureDTO(key: "Tg0D", group: "Tg", celsius: gpu),
            TemperatureDTO(key: "Ts0M", group: "Ts", celsius: 30)
        ],
        fans: [FanStatusDTO(index: 0, actualRPM: rpm, targetRPM: rpm, minimumRPM: 1000, maximumRPM: 5000, mode: "manual")],
        curve: [FanCurveStateDTO(index: 0, aggregatedCelsius: cpu - 2, effectiveCelsius: cpu - 4, targetRPM: rpm, handedToSystem: handedToSystem)],
        power: [PowerReadingDTO(key: "PDTR", name: "Package Power", value: watts, unit: "W")],
        safety: SafetyStateDTO(latched: latched, ceilingCelsius: 100, lastTripReason: nil),
        lastError: nil
    )
}

private func sample(_ seconds: Double, _ phase: StressPhase, cpu: Double, rpm: Double, latched: Bool = false) -> StressSample {
    StressSample(seconds: seconds, phase: phase, cpuMaximum: cpu, gpuMaximum: nil, curveInput: nil, curveEffective: nil,
                 fanRPM: rpm, fanPercent: (rpm - 1000) / 40, targetRPM: rpm, packageWatts: 20, handedToSystem: false, latched: latched)
}

@Test
func stressSampleReadsTelemetry() {
    let s = StressSample(seconds: 4, phase: .load, telemetry: makeTelemetry(cpu: 70, gpu: 0, rpm: 3000, watts: 31.5))
    #expect(s.cpuMaximum == 70)
    // A powered-down GPU (~0 °C) has no maximum.
    #expect(s.gpuMaximum == nil)
    #expect(s.curveInput == 68)
    #expect(s.curveEffective == 66)
    #expect(s.fanRPM == 3000)
    #expect(s.fanPercent == 50)
    #expect(s.packageWatts == 31.5)
    #expect(!s.handedToSystem)
}

@Test
func stressSummaryMeasuresRampSteadyAndRest() throws {
    // Fans at 1000 RPM, ramp at 10 s, steady near 3000 RPM, back at rest 20 s after the load.
    var samples: [StressSample] = []
    for t in stride(from: 0.0, through: 60, by: 2) {
        let rpm = t < 10 ? 1000 : min(1000 + (t - 8) * 200, t.truncatingRemainder(dividingBy: 4) == 0 ? 3100 : 2900)
        samples.append(sample(t, .load, cpu: 50 + min(t, 30), rpm: rpm))
    }
    for t in stride(from: 62.0, through: 100, by: 2) {
        samples.append(sample(t, .cool, cpu: 60, rpm: t < 80 ? 2000 : 1050))
    }
    let summary = try #require(StressSummary(samples: samples))
    #expect(summary.startCPU == 50)
    #expect(summary.peakCPU == 80)
    #expect(summary.steadyCPU == 80)
    #expect(summary.startRPM == 1000)
    #expect(summary.peakRPM == 3100)
    #expect(summary.steadyRPM.map { abs($0 - 3000) < 10 } == true)
    #expect(summary.steadySpreadRPM.map { abs($0 - 100) < 5 } == true)
    #expect(summary.rampSeconds == 10)
    #expect(summary.rampCPU == 60)
    #expect(summary.nearPeakSeconds == 18)
    #expect(summary.restSeconds == 20)
    #expect(summary.returnedToRest)
    #expect(summary.endCPU == 60)
    #expect(!summary.tripped)
}

@Test
func stressSummaryWithoutRampOrRest() throws {
    let quiet = [sample(0, .load, cpu: 40, rpm: 1000), sample(2, .load, cpu: 45, rpm: 1050), sample(4, .cool, cpu: 42, rpm: 1000)]
    let summary = try #require(StressSummary(samples: quiet))
    #expect(summary.rampSeconds == nil)
    #expect(summary.nearPeakSeconds == nil)
    #expect(summary.restSeconds == nil)
    #expect(summary.returnedToRest)

    let stuck = [sample(0, .load, cpu: 40, rpm: 1000), sample(2, .load, cpu: 80, rpm: 3000, latched: true), sample(4, .cool, cpu: 70, rpm: 2500)]
    let hot = try #require(StressSummary(samples: stuck))
    #expect(hot.rampSeconds == 2)
    #expect(hot.restSeconds == nil)
    #expect(!hot.returnedToRest)
    #expect(hot.tripped)

    #expect(StressSummary(samples: [sample(0, .cool, cpu: 40, rpm: 1000)]) == nil)
}

@Test
func stressCSVHasOneRowPerSample() {
    let result = StressResult(profile: "mine", startedAt: Date(), plan: StressPlan(), samples: [sample(0, .load, cpu: 40, rpm: 1000)], completed: true)
    let lines = StressResult.csv([result]).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[1] == "mine,load,0.0,40.0,,,,1000.0,0.0,1000.0,20.0,0,0")
}

private final class FakeLoad: StressLoad, @unchecked Sendable {
    let state = OSAllocatedUnfairLock(initialState: (running: false, starts: 0))
    func start() { state.withLock { $0.running = true; $0.starts += 1 } }
    func stop() { state.withLock { $0.running = false } }
}

/// A fake Mac: the CPU heats while the load runs and the fans follow it.
private final class FakeMac: @unchecked Sendable {
    let load = FakeLoad()
    let state = OSAllocatedUnfairLock(initialState: (profile: "silent", cpu: 40.0, activations: [String]()))

    func telemetry() -> TelemetryDTO {
        let running = load.state.withLock { $0.running }
        let snapshot = state.withLock { s -> (String, Double) in
            s.cpu += running ? 5 : -5
            return (s.profile, s.cpu)
        }
        return makeTelemetry(profile: snapshot.0, cpu: snapshot.1, rpm: 1000 + max(snapshot.1 - 40, 0) * 50)
    }

    func activate(_ profile: String) { state.withLock { $0.profile = profile; $0.activations.append(profile) } }
}

@Test
func stressRunnerRunsEachProfileAndRestores() throws {
    let mac = FakeMac()
    let runner = StressRunner(telemetry: { mac.telemetry() }, activate: { mac.activate($0) }, load: { _ in mac.load })
    let plan = StressPlan(loadSeconds: 1, coolSeconds: 1, settleSeconds: 0, sampleInterval: 0.25, holdSeconds: 0)
    var events: [String] = []
    let results = try runner.run(profiles: ["a", "b"], plan: plan) { event in
        switch event {
        case .started(let profile, _, _): events.append("start \(profile)")
        case .finished(let result): events.append("done \(result.profile)")
        case .restored(let profile): events.append("restored \(profile)")
        default: break
        }
    }
    #expect(events == ["start a", "done a", "start b", "done b", "restored silent"])
    #expect(results.map(\.profile) == ["a", "b"])
    #expect(results.map(\.completed) == [true, true])
    let first = try #require(results.first)
    #expect(first.samples.filter { $0.phase == .load }.count == 5)
    #expect(first.samples.filter { $0.phase == .cool }.count == 4)
    #expect(mac.state.withLock { $0.activations } == ["a", "b", "silent"])
    #expect(mac.load.state.withLock { $0.running } == false)
    #expect(first.summary?.rampSeconds != nil)
}

@Test
func stressRunnerStopsWhenCancelledAndStillRestores() throws {
    let mac = FakeMac()
    let runner = StressRunner(telemetry: { mac.telemetry() }, activate: { mac.activate($0) }, load: { _ in mac.load })
    let plan = StressPlan(loadSeconds: 30, coolSeconds: 30, settleSeconds: 0, sampleInterval: 0.1, holdSeconds: 0)
    let started = Date()
    var count = 0
    let results = try runner.run(profiles: ["a", "b"], plan: plan) { event in
        if case .sample = event { count += 1; if count == 5 { runner.cancel() } }
    }
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(results.map(\.profile) == ["a"])
    #expect(results.first?.completed == false)
    #expect(mac.state.withLock { $0.activations } == ["a", "silent"])
    #expect(mac.load.state.withLock { $0.running } == false)
}

@Test
func stressRunnerWaitsForTheMacToCoolBeforeEachProfile() throws {
    let mac = FakeMac()
    let runner = StressRunner(telemetry: { mac.telemetry() }, activate: { mac.activate($0) }, load: { _ in mac.load })
    mac.state.withLock { $0.cpu = 40 }
    let plan = StressPlan(loadSeconds: 1, coolSeconds: 0, settleSeconds: 1, sampleInterval: 0.25, holdSeconds: 0)
    var settled: [String] = []
    var targets: Set<Double> = []
    try runner.run(profiles: ["a", "b"], plan: plan) { event in
        if case .settling(let profile, _, let target, _) = event { settled.append(profile); targets.insert(target) }
    }
    // The first profile starts cool; after its load the second has to wait,
    // for the first one's starting temperature (35 °C) + 2 °C.
    #expect(settled.first == "b")
    #expect(targets == [37])
}

@Test
func stressRunnerStopsWhenAnotherProfileTakesOver() throws {
    let mac = FakeMac()
    let runner = StressRunner(telemetry: { mac.telemetry() }, activate: { mac.activate($0) }, load: { _ in mac.load })
    let plan = StressPlan(loadSeconds: 30, coolSeconds: 30, settleSeconds: 0, sampleInterval: 0.1, holdSeconds: 0)
    let started = Date()
    var count = 0
    var events: [String] = []
    let results = try runner.run(profiles: ["a", "b"], plan: plan) { event in
        switch event {
        case .sample:
            count += 1
            // Someone picks another profile in the popover (not through the runner).
            if count == 3 { mac.state.withLock { $0.profile = "performance" } }
        case .profileChanged(let profile, let active): events.append("\(profile) → \(active)")
        case .started(let profile, _, _): events.append("start \(profile)")
        case .restored(let profile): events.append("restored \(profile)")
        default: break
        }
    }
    #expect(Date().timeIntervalSince(started) < 3, "stops at once instead of measuring the wrong profile")
    #expect(events == ["start a", "a → performance", "restored silent"], "b is not run")
    #expect(results.map(\.profile) == ["a"])
    #expect(results.first?.completed == false)
    #expect(results.first?.profileChange == "performance")
    #expect(mac.load.state.withLock { $0.running } == false)
    #expect(mac.state.withLock { $0.activations } == ["a", "silent"])
}

@Test
func profileChangeIgnoresTheSafetyGuardAndOldSamples() {
    func sample(_ t: Double, profile: String?, latched: Bool = false) -> StressSample {
        StressSample(seconds: t, phase: .load, cpuMaximum: 80, gpuMaximum: nil, curveInput: nil, curveEffective: nil, fanRPM: 2000,
                     fanPercent: 30, targetRPM: 2000, packageWatts: nil, handedToSystem: false, latched: latched, profile: profile)
    }
    let plan = StressPlan()
    #expect(StressResult(profile: "a", startedAt: Date(), plan: plan, samples: [sample(0, profile: "a"), sample(2, profile: "a")],
                         completed: true).profileChange == nil)
    #expect(StressResult(profile: "a", startedAt: Date(), plan: plan, samples: [sample(0, profile: nil), sample(2, profile: nil)],
                         completed: true).profileChange == nil, "samples from before the profile was recorded")
    #expect(StressResult(profile: "a", startedAt: Date(), plan: plan, samples: [sample(0, profile: "a"), sample(2, profile: "auto", latched: true)],
                         completed: true).profileChange == nil, "the safety guard handing the fans to macOS is not a takeover")
    #expect(StressResult(profile: "a", startedAt: Date(), plan: plan, samples: [sample(0, profile: "a"), sample(2, profile: "silent")],
                         completed: false).profileChange == "silent")
}
