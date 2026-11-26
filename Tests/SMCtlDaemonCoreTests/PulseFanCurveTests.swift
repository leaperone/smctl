import Foundation
import XCTest
@testable import SMCtlDaemonCore
@testable import SMCCore
import PolicyEngine
import ProductIdentity
import SMCtlProtocol

final class PulseFanCurveTests: XCTestCase {
    private var configPath: String!

    override func setUp() {
        super.setUp()
        setenv("\(ProductIdentity.environmentPrefix)_SENTRY_DISABLED", "1", 1)
        configPath = NSTemporaryDirectory() + "pulse-test-\(UUID().uuidString).toml"
    }

    override func tearDown() {
        if let configPath { try? FileManager.default.removeItem(atPath: configPath) }
        unsetenv("\(ProductIdentity.environmentPrefix)_SENTRY_DISABLED")
        super.tearDown()
    }

    // MARK: TOML

    func testShapePercentPointsAndPercentRatesDecodeFromToml() throws {
        try """
        [fan]
        profile = "auto"

        [[fan.curves]]
        name = "night"
        label = "Nuit"
        sensors = ["Tp*"]
        shape = { type = "sigmoid", start = 70, end = 100, min = "10%", max = "60%", steepness = 6 }
        hysteresis = 3
        slew_rate = "8%"
        fall_slew_rate = "3%"
        smoothing = 10

        [[fan.curves]]
        name = "steps"
        points = [[60, "20%"], [80, "50%"], [95, "max"]]
        """.write(toFile: configPath, atomically: true, encoding: .utf8)
        let daemon = makeDaemon().daemon

        XCTAssertNil(daemon.configError)
        let night = try XCTUnwrap(daemon.config.fan.curves.first { $0.name == "night" }).spec()
        XCTAssertEqual(night.label, "Nuit")
        XCTAssertEqual(night.sensors, ["Tp*"])
        XCTAssertEqual(night.shape, try FanCurveShape(kind: .sigmoid, startCelsius: 70, endCelsius: 100, minimumFraction: 0.1, maximumFraction: 0.6, steepness: 6))
        XCTAssertEqual(night.riseRate, .percentPerSecond(8))
        XCTAssertEqual(night.fallRate, .percentPerSecond(3))
        XCTAssertEqual(night.smoothingSeconds, 10)
        let steps = try XCTUnwrap(daemon.config.fan.curves.first { $0.name == "steps" }).spec()
        XCTAssertEqual(steps.points.map(\.speed), [.percent(20), .percent(50), .maximum])
    }

    func testLegacySmctlCurveResolvesExactlyAsBefore() throws {
        try """
        [[fan.curves]]
        name = "cooler"
        sensors = ["Tp3P", "Tp0E"]
        points = [[75, 1000], [85, 1600], [95, 2600], [105, 4200], [110, "max"]]
        hysteresis = 4
        slew_rate = 600
        fall_slew_rate = 180
        """.write(toFile: configPath, atomically: true, encoding: .utf8)
        let daemon = makeDaemon().daemon
        let range = FanSpeedRange(minimumRPM: 1000, maximumRPM: 4900)

        let curve = try daemon.curveForProfileLocked("cooler", range: range)

        XCTAssertEqual(curve.points.map(\.temperatureCelsius), [75, 85, 95, 105, 110])
        XCTAssertEqual(curve.points.map(\.rpm), [1000, 1600, 2600, 4200, 4900])
        XCTAssertEqual(curve.hysteresisCelsius, 4)
        XCTAssertEqual(curve.slewRateRPMPerSecond, 600)
        XCTAssertEqual(curve.fallSlewRateRPMPerSecond, 180)
        XCTAssertNil(curve.smoothingSeconds)
    }

    func testUpsertedCurveRoundTripsThroughTheConfigFile() throws {
        let daemon = makeDaemon().daemon
        let specs = [
            FanCurveSpec(
                name: "night", label: "Nuit \"calme\" \\ test", sensors: ["Tp*", "Tg0P"],
                weights: ["Tp*": 1, "Tg0P": 2],
                shape: try FanCurveShape(kind: .steps, startCelsius: 60, endCelsius: 100, minimumFraction: 0.05, maximumFraction: 0.75, stepCount: 5),
                hysteresisCelsius: 2.5, riseRate: .percentPerSecond(6), fallRate: .rpmPerSecond(90), smoothingSeconds: 7
            ),
            FanCurveSpec(
                name: "manual-points",
                points: [FanCurveSpecPoint(55, .rpm(1200)), FanCurveSpecPoint(80, .percent(45.5)), FanCurveSpecPoint(100, .maximum)],
                hysteresisCelsius: 0
            )
        ]
        for spec in specs {
            try daemon.upsertFanCurve(spec, activate: false)
        }

        let reloaded = makeDaemon().daemon
        XCTAssertNil(reloaded.configError)
        for spec in specs {
            XCTAssertEqual(try reloaded.fanCurveSpecLocked(named: spec.name), spec)
        }
    }

    func testPercentagesAreWrittenWithoutFloatingPointNoise() throws {
        let daemon = makeDaemon().daemon
        let shape = try FanCurveShape(kind: .linear, startCelsius: 60, endCelsius: 90, minimumFraction: 0.07, maximumFraction: 0.29)
        try daemon.upsertFanCurve(FanCurveSpec(name: "noise", shape: shape), activate: false)

        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(text.contains("min = \"7%\", max = \"29%\""), text)
        let reloaded = try makeDaemon().daemon.fanCurveSpecLocked(named: "noise")
        XCTAssertEqual(reloaded.shape?.minimumFraction ?? 0, 0.07, accuracy: 1e-12)
        XCTAssertEqual(reloaded.shape?.maximumFraction ?? 0, 0.29, accuracy: 1e-12)
    }

    func testUpsertReplacesExistingCurveAndKeepsOtherSections() throws {
        try """
        [battery]
        limit = "70-80"

        [[alert]]
        name = "hot"
        on = "temp"
        sensor = "any"
        above = 90
        action = "log"
        """.write(toFile: configPath, atomically: true, encoding: .utf8)
        let daemon = makeDaemon().daemon
        try daemon.upsertFanCurve(linearSpec(name: "work", max: 50), activate: false)
        try daemon.upsertFanCurve(linearSpec(name: "work", max: 80), activate: false)

        let reloaded = makeDaemon().daemon
        XCTAssertEqual(reloaded.config.fan.curves.filter { $0.name == "work" }.count, 1)
        XCTAssertEqual(try reloaded.fanCurveSpecLocked(named: "work").shape?.maximumFraction, 0.8)
        XCTAssertEqual(reloaded.config.battery.limit, "70-80")
        XCTAssertEqual(reloaded.config.alerts.map(\.name), ["hot"])
    }

    // MARK: Validation

    func testUpsertRejectsInvalidCurvesWithoutTouchingTheConfig() throws {
        let daemon = makeDaemon().daemon
        let invalid: [FanCurveSpec] = [
            linearSpec(name: "balanced"),                 // reserved preset
            linearSpec(name: "auto"),                     // system mode
            linearSpec(name: "Night Mode"),               // uppercase and space
            linearSpec(name: "bad\"name"),                // would break TOML
            FanCurveSpec(name: "empty"),                  // neither shape nor points
            FanCurveSpec(name: "one", points: [FanCurveSpecPoint(60, .percent(50))]),
            FanCurveSpec(name: "pct", points: [FanCurveSpecPoint(60, .percent(10)), FanCurveSpecPoint(90, .percent(150))]),
            FanCurveSpec(name: "dup", points: [FanCurveSpecPoint(60, .percent(10)), FanCurveSpecPoint(60, .percent(20))]),
            FanCurveSpec(name: "rate", shape: linearSpec(name: "x").shape, riseRate: .percentPerSecond(0))
        ]
        for spec in invalid {
            XCTAssertThrowsError(try daemon.upsertFanCurve(spec, activate: false), spec.name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath), "nothing may be written for invalid curves")
    }

    func testUpsertRefusesToOverwriteAConfigThatFailsToParse() throws {
        let broken = "[fan\nprofile = \"quiet\"\n"
        try broken.write(toFile: configPath, atomically: true, encoding: .utf8)
        let daemon = makeDaemon().daemon
        XCTAssertNotNil(daemon.configError)

        XCTAssertThrowsError(try daemon.upsertFanCurve(linearSpec(name: "work"), activate: false))
        XCTAssertEqual(try String(contentsOfFile: configPath, encoding: .utf8), broken)
    }

    // MARK: Control

    func testPercentCurveDrivesTheFanWithinItsOwnRange() throws {
        let (backend, daemon) = makeDaemon(celsius: 70)
        let spec = FanCurveSpec(name: "flat", points: [FanCurveSpecPoint(50, .percent(0)), FanCurveSpecPoint(90, .percent(100))])

        try daemon.upsertFanCurve(spec, activate: true)

        XCTAssertEqual(daemon.config.fan.profile, "flat")
        XCTAssertEqual(backend.values["F0Md"], [1])
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 2950, accuracy: 0.5, "70C is halfway: 1000 + 50% of 3900")
    }

    func testBuiltInPresetsActivateAndStayWithinRange() throws {
        for preset in FanCurvePresets.all {
            for celsius in [40.0, 75, 90, 104] {
                let (backend, daemon) = makeDaemon(celsius: celsius)
                try daemon.setFanProfile(preset.name)
                XCTAssertEqual(daemon.config.fan.profile, preset.name)
                if backend.values["F0Md"] == [0] {
                    // Below the ramp at a 0% floor: macOS runs the fan.
                    XCTAssertEqual(preset.shape?.minimumFraction, 0, "\(preset.name) at \(celsius)C")
                    XCTAssertLessThanOrEqual(celsius, preset.shape?.startCelsius ?? 0, "\(preset.name) at \(celsius)C")
                    continue
                }
                let target = try XCTUnwrap(backend.float("F0Tg"))
                XCTAssertGreaterThanOrEqual(target, 1000 - 0.5, "\(preset.name) at \(celsius)C")
                XCTAssertLessThanOrEqual(target, 4900 + 0.5, "\(preset.name) at \(celsius)C")
            }
        }
    }

    // MARK: Idle handoff

    func testBelowTheRampAZeroFloorLeavesTheFanToMacOS() throws {
        let (backend, daemon) = makeDaemon(celsius: 40)
        try daemon.upsertFanCurve(
            FanCurveSpec(name: "flat", points: [FanCurveSpecPoint(50, .percent(0)), FanCurveSpecPoint(90, .percent(100))]),
            activate: true
        )

        XCTAssertEqual(daemon.config.fan.profile, "flat")
        XCTAssertEqual(backend.values["F0Md"], [0], "a cool MacBook keeps its fans stopped")
        XCTAssertFalse(backend.writes.contains { $0.key == "F0Tg" || $0.key == "F0Md" }, "writes: \(backend.writes)")
        XCTAssertEqual(daemon.telemetry().curve.first?.targetRPM ?? -1, 0, "reports macOS's target, not the 1000 RPM floor")
    }

    func testTheCurveTakesTheFanAndHandsItBackAfterTheDelay() throws {
        let (backend, daemon) = makeDaemon(celsius: 70)
        let clock = TestClock()
        daemon.now = { clock.date }
        try daemon.upsertFanCurve(
            FanCurveSpec(name: "flat", points: [FanCurveSpecPoint(50, .percent(0)), FanCurveSpecPoint(90, .percent(100))]),
            activate: true
        )
        XCTAssertEqual(backend.values["F0Md"], [1])

        // Cooled to 0%: the floor is held until the delay has passed.
        backend.setTemperature(40)
        daemon.evaluateFanSubsystemLocked()
        XCTAssertEqual(backend.values["F0Md"], [1], "held at the floor first")
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 1000, accuracy: 0.5)
        XCTAssertEqual(daemon.telemetry().curve.first?.handedToSystem, false)

        clock.advance(FanCurveHandoff.releaseDelaySeconds - 1)
        daemon.evaluateFanSubsystemLocked()
        XCTAssertEqual(backend.values["F0Md"], [1], "not yet")

        clock.advance(1)
        daemon.evaluateFanSubsystemLocked()
        XCTAssertEqual(backend.values["F0Md"], [0], "back to macOS after the delay")
        XCTAssertEqual(daemon.config.fan.profile, "flat", "the curve stays active")
        XCTAssertEqual(daemon.telemetry().curve.first?.handedToSystem, true)

        backend.writes.removeAll()
        clock.advance(1)
        daemon.evaluateFanSubsystemLocked()
        XCTAssertTrue(backend.writes.isEmpty, "no repeated handoff: \(backend.writes)")

        // Taking the fan back is immediate.
        backend.setTemperature(70)
        clock.advance(1)
        daemon.evaluateFanSubsystemLocked()
        XCTAssertEqual(backend.values["F0Md"], [1])
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 2950, accuracy: 0.5)
        XCTAssertEqual(daemon.telemetry().curve.first?.handedToSystem, false)
    }

    /// A temperature hovering at the ramp start with no hysteresis or smoothing
    /// must not toggle the fan's mode every second.
    func testHoveringAtTheRampStartDoesNotToggleTheMode() throws {
        let (backend, daemon) = makeDaemon(celsius: 51)
        let clock = TestClock()
        daemon.now = { clock.date }
        try daemon.upsertFanCurve(
            FanCurveSpec(name: "edge", points: [FanCurveSpecPoint(50, .percent(0)), FanCurveSpecPoint(90, .percent(100))]),
            activate: true
        )
        backend.writes.removeAll()
        for second in 0..<60 {
            backend.setTemperature(second.isMultiple(of: 2) ? 49.5 : 50.5)
            clock.advance(1)
            daemon.evaluateFanSubsystemLocked()
        }
        let handoffs = backend.writes.filter { $0.key == "F0Md" && $0.bytes == [0] }.count
        XCTAssertEqual(handoffs, 0, "held at the floor throughout, never handed back: \(backend.writes)")
        XCTAssertEqual(backend.values["F0Md"], [1])
    }

    func testAMacThatIsAlreadyCoolStaysWithMacOSWithoutWaiting() throws {
        let (backend, daemon) = makeDaemon(celsius: 40)
        try daemon.upsertFanCurve(
            FanCurveSpec(name: "flat", points: [FanCurveSpecPoint(50, .percent(0)), FanCurveSpecPoint(90, .percent(100))]),
            activate: true
        )
        XCTAssertEqual(backend.values["F0Md"], [0])
        XCTAssertEqual(daemon.telemetry().curve.first?.handedToSystem, true)
    }

    // MARK: Idle modes

    private func zeroFloorCurve(_ idle: FanCurveIdle, hysteresis: Double = 0) -> FanCurveSpec {
        FanCurveSpec(name: "edge", points: [FanCurveSpecPoint(50, .percent(0)), FanCurveSpecPoint(90, .percent(100))],
                     hysteresisCelsius: hysteresis, idle: idle)
    }

    /// Activates `spec` at 70 °C (fan under the curve), then cools to 40 °C and
    /// runs `seconds` one-second ticks.
    private func coolDown(_ spec: FanCurveSpec, allowStopping: Bool = false, sensors: [String: Double] = [:],
                          seconds: Int) throws -> (PulseFakeSMC, SmctlDaemon, TestClock) {
        let (backend, daemon) = makeDaemon(celsius: 70, sensors: sensors)
        daemon.config.safety.allow_below_minimum = allowStopping
        let clock = TestClock()
        daemon.now = { clock.date }
        try daemon.upsertFanCurve(spec, activate: true)
        backend.setTemperature(40)
        for _ in 0...seconds {
            daemon.evaluateFanSubsystemLocked()
            clock.advance(1)
        }
        return (backend, daemon, clock)
    }

    func testIdleMinimumHoldsTheFloorAndNeverHandsOff() throws {
        let (backend, daemon, _) = try coolDown(zeroFloorCurve(.minimum), seconds: 60)
        XCTAssertEqual(backend.values["F0Md"], [1])
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 1000, accuracy: 0.5)
        let state = try XCTUnwrap(daemon.telemetry().curve.first)
        XCTAssertFalse(state.handedToSystem)
        XCTAssertFalse(state.stopped)
    }

    func testIdleOffWithoutTheSafetyOptInActsLikeSystem() throws {
        let (backend, daemon, _) = try coolDown(zeroFloorCurve(.off), allowStopping: false, seconds: 20)
        XCTAssertEqual(backend.values["F0Md"], [0], "handed to macOS, not stopped")
        XCTAssertFalse(backend.writes.contains { $0.key == "F0Tg" && $0.bytes == FanController.float32LittleEndianBytes(0) })
        XCTAssertEqual(daemon.telemetry().curve.first?.handedToSystem, true)
        XCTAssertFalse(daemon.telemetry().safety.allowsStoppingFans)
    }

    func testIdleOffStopsTheFanAfterTheDelayAndRestartsWhenTheCurveRises() throws {
        let (backend, daemon, clock) = try coolDown(zeroFloorCurve(.off), allowStopping: true, seconds: 5)
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 1000, accuracy: 0.5, "floor held during the delay")
        for _ in 0..<15 {
            daemon.evaluateFanSubsystemLocked()
            clock.advance(1)
        }
        XCTAssertEqual(backend.values["F0Md"], [1], "Pulse keeps the fan, stopped")
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 0, accuracy: 0.5)
        let state = try XCTUnwrap(daemon.telemetry().curve.first)
        XCTAssertTrue(state.stopped)
        XCTAssertEqual(state.targetRPM, 0)
        XCTAssertTrue(daemon.telemetry().safety.allowsStoppingFans)

        backend.writes.removeAll()
        daemon.evaluateFanSubsystemLocked()
        XCTAssertTrue(backend.writes.isEmpty, "no rewrite while stopped: \(backend.writes)")

        backend.setTemperature(70)
        daemon.evaluateFanSubsystemLocked()
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 2950, accuracy: 0.5, "the curve takes over immediately")
        XCTAssertEqual(daemon.telemetry().curve.first?.stopped, false)
    }

    func testAStoppedFanRestartsWhenAnySensorNearsItsLimit() throws {
        // The curve watches the CPU only; the enclosure heats up without airflow.
        var spec = zeroFloorCurve(.off)
        spec.sensors = ["Tp*"]
        let (backend, daemon, clock) = try coolDown(spec, allowStopping: true, sensors: ["Ts00": 30], seconds: 20)
        XCTAssertEqual(daemon.telemetry().curve.first?.stopped, true)

        backend.values["Ts00"] = FanController.float32LittleEndianBytes(Float(FanCurveHandoff.stopOtherLimitCelsius + 1))
        daemon.evaluateFanSubsystemLocked()
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 1000, accuracy: 0.5, "restarted at its minimum")
        XCTAssertEqual(daemon.telemetry().curve.first?.stopped, false)

        // Just under the limit is not enough to stop again: 5 °C of headroom, then the delay.
        backend.values["Ts00"] = FanController.float32LittleEndianBytes(Float(FanCurveHandoff.stopOtherLimitCelsius - 2))
        for _ in 0..<30 { clock.advance(1); daemon.evaluateFanSubsystemLocked() }
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 1000, accuracy: 0.5)

        backend.values["Ts00"] = FanController.float32LittleEndianBytes(30)
        for _ in 0..<16 { clock.advance(1); daemon.evaluateFanSubsystemLocked() }
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 0, accuracy: 0.5, "stopped again once cool")
    }

    func testIdleIsSavedOnlyWhenNotTheDefault() throws {
        let daemon = makeDaemon().daemon
        try daemon.upsertFanCurve(zeroFloorCurve(.off), activate: false)
        var other = zeroFloorCurve(.system)
        other.name = "plain"
        try daemon.upsertFanCurve(other, activate: false)
        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(text.contains("idle = \"off\""), text)
        XCTAssertEqual(text.components(separatedBy: "idle =").count, 2, "system is not written")
        let reloaded = makeDaemon().daemon
        XCTAssertEqual(try reloaded.fanCurveSpecLocked(named: "edge").idle, .off)
        XCTAssertEqual(try reloaded.fanCurveSpecLocked(named: "plain").idle, .system)
    }

    func testAnUnknownIdleValueMakesTheCurveInvalid() throws {
        try """
        [[fan.curves]]
        name = "odd"
        sensors = []
        points = [[50, "0%"], [90, "100%"]]
        hysteresis = 0
        idle = "sometimes"
        """.write(toFile: configPath, atomically: true, encoding: .utf8)
        let daemon = makeDaemon().daemon
        XCTAssertNotNil(daemon.listFanCurves().invalid["odd"])
    }

    func testSpecsFromOlderClientsDecodeWithTheSystemIdle() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FanCurvePresets.balanced)) as! [String: Any]
        json.removeValue(forKey: "idle")
        let decoded = try JSONDecoder().decode(FanCurveSpec.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.idle, .system)
        XCTAssertEqual(decoded, FanCurvePresets.balanced)
    }

    func testCurveStateFromAnOlderDaemonDecodesAsNotHandedOff() throws {
        let json = #"{"index":0,"aggregatedCelsius":60,"effectiveCelsius":60,"targetRPM":1500}"#
        let state = try JSONDecoder().decode(FanCurveStateDTO.self, from: Data(json.utf8))
        XCTAssertFalse(state.handedToSystem)
        let roundTrip = try JSONDecoder().decode(FanCurveStateDTO.self, from: JSONEncoder().encode(
            FanCurveStateDTO(index: 0, aggregatedCelsius: 60, effectiveCelsius: 60, targetRPM: 0, handedToSystem: true)))
        XCTAssertTrue(roundTrip.handedToSystem)
    }

    func testAFloorAboveZeroKeepsTheFanSpinning() throws {
        let (backend, daemon) = makeDaemon(celsius: 40)
        try daemon.setFanProfile("performance")
        XCTAssertEqual(backend.values["F0Md"], [1])
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 1390, accuracy: 0.5, "10% of 1000–4900")
    }

    func testDeadbandSkipsRedundantWritesButRewritesWhenControlIsLost() throws {
        let (backend, daemon) = makeDaemon(celsius: 70)
        try daemon.upsertFanCurve(
            FanCurveSpec(name: "flat", points: [FanCurveSpecPoint(50, .percent(0)), FanCurveSpecPoint(90, .percent(100))]),
            activate: true
        )
        backend.writes.removeAll()

        // Same temperature: target unchanged, nothing to write.
        daemon.evaluateFanSubsystemLocked()
        XCTAssertTrue(backend.writes.isEmpty, "writes: \(backend.writes)")

        // +0.2C moves the target by ~20 RPM, under the 50 RPM deadband.
        backend.setTemperature(70.2)
        daemon.evaluateFanSubsystemLocked()
        XCTAssertTrue(backend.writes.isEmpty, "writes: \(backend.writes)")

        // +5C moves it by ~490 RPM: written.
        backend.setTemperature(75)
        daemon.evaluateFanSubsystemLocked()
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 3437.5, accuracy: 0.5)

        // macOS took the fan back (e.g. after sleep): rewrite even though the target matches.
        backend.writes.removeAll()
        backend.values["F0Md"] = [0]
        daemon.evaluateFanSubsystemLocked()
        XCTAssertEqual(backend.values["F0Md"], [1])
        XCTAssertTrue(backend.writes.contains { $0.key == "F0Tg" })
    }

    /// The app saves edits to the active curve without re-activating it: the
    /// next tick must already use the new curve (it is resolved by name).
    func testSavingTheActiveCurveAppliesOnTheNextTick() throws {
        let (backend, daemon) = makeDaemon(celsius: 70)
        try daemon.upsertFanCurve(
            FanCurveSpec(name: "flat", points: [FanCurveSpecPoint(50, .percent(0)), FanCurveSpecPoint(90, .percent(100))]),
            activate: true
        )
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 2950, accuracy: 0.5)

        try daemon.upsertFanCurve(
            FanCurveSpec(name: "flat", points: [FanCurveSpecPoint(50, .percent(0)), FanCurveSpecPoint(70, .percent(100))]),
            activate: false
        )
        XCTAssertEqual(daemon.config.fan.profile, "flat", "still active")
        daemon.evaluateFanSubsystemLocked()
        XCTAssertEqual(try XCTUnwrap(backend.float("F0Tg")), 4900, accuracy: 0.5, "70C is now the top of the curve")
    }

    func testDeletingTheActiveCurveHandsFansBackToTheSystem() throws {
        let (backend, daemon) = makeDaemon(celsius: 70)
        try daemon.upsertFanCurve(linearSpec(name: "work"), activate: true)
        XCTAssertEqual(backend.values["F0Md"], [1])

        try daemon.deleteFanCurve(named: "work")

        XCTAssertEqual(backend.values["F0Md"], [0])
        XCTAssertEqual(daemon.config.fan.profile, "auto")
        XCTAssertTrue(daemon.config.fan.curves.isEmpty)
        XCTAssertEqual(makeDaemon().daemon.config.fan.profile, "auto", "persisted")
    }

    func testDeleteRejectsBuiltInsAndUnknownNames() throws {
        let daemon = makeDaemon().daemon
        XCTAssertThrowsError(try daemon.deleteFanCurve(named: "balanced"))
        XCTAssertThrowsError(try daemon.deleteFanCurve(named: "quiet"))
        XCTAssertThrowsError(try daemon.deleteFanCurve(named: "missing"))
    }

    // MARK: Read APIs

    func testListShowsPresetsUserCurvesAndInvalidEntries() throws {
        try """
        [[fan.curves]]
        name = "broken"
        shape = { type = "zigzag", start = 60, end = 90 }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)
        let daemon = makeDaemon().daemon
        try? FileManager.default.removeItem(atPath: configPath)  // allow the upsert below
        daemon.configError = nil
        try daemon.upsertFanCurve(linearSpec(name: "work"), activate: false)

        let list = daemon.listFanCurves()

        XCTAssertEqual(list.activeProfile, "auto")
        XCTAssertEqual(list.curves.filter(\.builtin).map(\.spec.name), ["silent", "balanced", "performance"])
        XCTAssertEqual(list.curves.filter { !$0.builtin }.map(\.spec.name), ["work"])
        XCTAssertTrue(list.invalid["broken"]?.contains("zigzag") == true, "\(list.invalid)")
    }

    func testTelemetryReportsCachedSnapshotAndCurveState() throws {
        let (_, daemon) = makeDaemon(celsius: 70)
        try daemon.upsertFanCurve(
            FanCurveSpec(name: "flat", points: [FanCurveSpecPoint(50, .percent(0)), FanCurveSpecPoint(90, .percent(100))]),
            activate: true
        )

        let telemetry = daemon.telemetry()

        XCTAssertEqual(telemetry.profile, "flat")
        XCTAssertEqual(telemetry.temperatures.map(\.key), ["Tp01"])
        XCTAssertEqual(telemetry.temperatures.first?.celsius ?? 0, 70, accuracy: 0.01)
        XCTAssertEqual(telemetry.curve.first?.targetRPM ?? 0, 2950, accuracy: 0.5)
        XCTAssertEqual(telemetry.curve.first?.aggregatedCelsius ?? 0, 70, accuracy: 0.01)
        XCTAssertFalse(telemetry.safety.latched)

        try daemon.setFanProfile("auto")
        XCTAssertTrue(daemon.telemetry().curve.isEmpty, "no curve state while macOS is in control")
    }

    func testAutoProfileTicksSkipSensorReadsAndTelemetryReadsOnDemand() throws {
        let (backend, daemon) = makeDaemon(celsius: 55)
        backend.reads = []
        daemon.tickFanAndAlertsLocked()
        daemon.tickFanAndAlertsLocked()
        XCTAssertFalse(backend.reads.contains("Tp01"), "auto, no alerts: nothing needs per-second temperatures")

        XCTAssertEqual(daemon.telemetry().temperatures.first?.celsius ?? -1, 55, accuracy: 0.01, "telemetry reads on demand")
        backend.reads = []
        _ = daemon.telemetry()
        XCTAssertFalse(backend.reads.contains("Tp01"), "a fresh snapshot is reused")

        try daemon.upsertFanCurve(linearSpec(name: "test"), activate: true)
        backend.reads = []
        daemon.tickFanAndAlertsLocked()
        XCTAssertTrue(backend.reads.contains("Tp01"), "curves and the safety guard read every tick")
    }

    func testTelemetryAndCurveDTOsRoundTripOverTheWireFormat() throws {
        let (_, daemon) = makeDaemon(celsius: 70)
        let telemetry = daemon.telemetry()
        XCTAssertEqual(try SMCtlProtocolCoding.decode(TelemetryDTO.self, from: SMCtlProtocolCoding.encode(telemetry)).profile, telemetry.profile)
        let request = UpsertFanCurveRequestDTO(spec: FanCurvePresets.balanced, activate: true)
        XCTAssertEqual(try SMCtlProtocolCoding.decode(UpsertFanCurveRequestDTO.self, from: SMCtlProtocolCoding.encode(request)), request)
    }

    // MARK: Helpers

    private func linearSpec(name: String, max: Double = 100) -> FanCurveSpec {
        FanCurveSpec(name: name, shape: try! FanCurveShape(kind: .linear, startCelsius: 60, endCelsius: 95, maximumFraction: max / 100))
    }

    /// A daemon over a fake SMC with one fan (1000–4900 RPM) and, when `celsius`
    /// is given, one readable `Tp01` sensor so curves can run without tripping
    /// the blind-sensor guard.
    private func makeDaemon(celsius: Double? = nil, sensors: [String: Double] = [:]) -> (backend: PulseFakeSMC, daemon: SmctlDaemon) {
        let backend = PulseFakeSMC()
        backend.values["F0Md"] = [0]
        backend.values["F0Tg"] = FanController.float32LittleEndianBytes(0)
        backend.values["F0Mn"] = FanController.float32LittleEndianBytes(1000)
        backend.values["F0Mx"] = FanController.float32LittleEndianBytes(4900)
        if let celsius { backend.setTemperature(celsius) }
        for (key, value) in sensors { backend.values[key] = FanController.float32LittleEndianBytes(Float(value)) }
        let daemon = SmctlDaemon(
            backend: backend,
            reader: celsius == nil ? nil : SensorReader(backend: backend),
            capabilities: Capabilities(
                fans: [FanCapability(index: 0, actualKey: "F0Ac", targetKey: "F0Tg", minimumKey: "F0Mn", maximumKey: "F0Mx", modeKey: "F0Md")],
                ftstAvailable: false
            ),
            configPath: configPath
        )
        return (backend, daemon)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var date: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Minimal SMC fake: stores written bytes, reports 1-byte keys as ui8 and 4-byte
/// keys as little-endian floats, like Apple Silicon fan and temperature keys.
private final class PulseFakeSMC: SMCWriteBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: [UInt8]] = [:]
    var values: [String: [UInt8]] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    var writes: [(key: String, bytes: [UInt8])] = []
    private var readLog: [String] = []
    var reads: [String] {
        get { lock.withLock { readLog } }
        set { lock.withLock { readLog = newValue } }
    }

    func setTemperature(_ celsius: Double) {
        values["Tp01"] = FanController.float32LittleEndianBytes(Float(celsius))
    }

    func float(_ key: String) -> Double? {
        guard let bytes = values[key], bytes.count == 4 else { return nil }
        return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
    }

    func readKeyInfo(_ key: String) throws -> SMCKeyInfo {
        guard let bytes = values[key] else { throw SMCError.notFound }
        return SMCKeyInfo(
            dataSize: UInt32(bytes.count),
            dataType: FourCharCode.unchecked(bytes.count == 4 ? "flt " : "ui8 "),
            dataAttributes: 0xC0
        )
    }

    func readValue(_ key: String) throws -> SMCReadValue {
        lock.withLock { readLog.append(key) }
        return SMCReadValue(key: key, info: try readKeyInfo(key), bytes: values[key] ?? [])
    }

    func writeRawValue(_ key: String, bytes: [UInt8]) throws {
        writes.append((key, bytes))
        values[key] = bytes
    }
}
