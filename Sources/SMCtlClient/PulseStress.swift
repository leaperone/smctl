import Foundation
import Metal
import os
import SMCtlProtocol

// Stress test for tuning fan curves, shared by `pulse fan stress` and the app:
// a heat load on every CPU core and the GPU, run under a profile while the
// telemetry is recorded, then a cool-down, then a summary of how the curve
// reacted. The load runs in the calling process, so it stops with it.

// MARK: - Plan and samples

public enum StressLoadKind: String, Codable, Sendable, CaseIterable {
    case cpuAndGPU
    case cpu
}

public struct StressPlan: Codable, Equatable, Sendable {
    /// Seconds of load, then seconds recorded once it stops.
    public var loadSeconds: Int
    public var coolSeconds: Int
    /// Before each profile, wait up to this long for the CPU to cool back to
    /// within `settleMarginCelsius` of where the first profile started, so
    /// every profile starts from the same point. 0 skips the wait.
    public var settleSeconds: Int
    public var load: StressLoadKind
    public var sampleInterval: Double
    /// After activating a profile, seconds for its curve to take hold of the
    /// fans before the first reading.
    public var holdSeconds: Double

    public static let settleMarginCelsius = 2.0

    public init(loadSeconds: Int = 120, coolSeconds: Int = 120, settleSeconds: Int = 300, load: StressLoadKind = .cpuAndGPU,
                sampleInterval: Double = 2, holdSeconds: Double = 4) {
        self.loadSeconds = loadSeconds
        self.coolSeconds = coolSeconds
        self.settleSeconds = settleSeconds
        self.load = load
        self.sampleInterval = sampleInterval
        self.holdSeconds = holdSeconds
    }
}

public enum StressPhase: String, Codable, Sendable {
    case load
    case cool
}

/// One reading. `seconds` counts from the start of the load.
public struct StressSample: Codable, Equatable, Sendable {
    public var seconds: Double
    public var phase: StressPhase
    public var cpuMaximum: Double?
    public var gpuMaximum: Double?
    /// The curve's input (aggregated sensors) and the temperature it acts on
    /// after hysteresis and smoothing; the hottest fan's when there are several.
    public var curveInput: Double?
    public var curveEffective: Double?
    /// The fastest fan, in RPM and in % of its range.
    public var fanRPM: Double?
    public var fanPercent: Double?
    public var targetRPM: Double?
    public var packageWatts: Double?
    /// The curve is at 0 %: macOS runs the fans.
    public var handedToSystem: Bool
    public var latched: Bool
    /// The profile the daemon was running; nil in samples recorded before it was kept.
    public var profile: String?

    public init(seconds: Double, phase: StressPhase, cpuMaximum: Double?, gpuMaximum: Double?, curveInput: Double?, curveEffective: Double?,
                fanRPM: Double?, fanPercent: Double?, targetRPM: Double?, packageWatts: Double?, handedToSystem: Bool, latched: Bool,
                profile: String? = nil) {
        self.seconds = seconds
        self.phase = phase
        self.cpuMaximum = cpuMaximum
        self.gpuMaximum = gpuMaximum
        self.curveInput = curveInput
        self.curveEffective = curveEffective
        self.fanRPM = fanRPM
        self.fanPercent = fanPercent
        self.targetRPM = targetRPM
        self.packageWatts = packageWatts
        self.handedToSystem = handedToSystem
        self.latched = latched
        self.profile = profile
    }

    public init(seconds: Double, phase: StressPhase, telemetry: TelemetryDTO) {
        let groups = TemperatureGroupSummary.summarize(telemetry.temperatures)
        func hottest(_ label: String) -> Double? {
            groups.filter { $0.label == label }.compactMap(\.maximumCelsius).max()
        }
        let fan = telemetry.fans.max { ($0.actualRPM ?? 0) < ($1.actualRPM ?? 0) }
        var percent: Double?
        if let fan, let rpm = fan.actualRPM, let low = fan.minimumRPM, let high = fan.maximumRPM, high > low {
            percent = min(max((rpm - low) / (high - low) * 100, 0), 100)
        }
        let curve = telemetry.curve.max { $0.effectiveCelsius < $1.effectiveCelsius }
        self.init(
            seconds: seconds,
            phase: phase,
            cpuMaximum: hottest("CPU"),
            gpuMaximum: hottest("GPU"),
            curveInput: curve?.aggregatedCelsius,
            curveEffective: curve?.effectiveCelsius,
            fanRPM: fan?.actualRPM,
            fanPercent: percent,
            targetRPM: fan?.targetRPM,
            packageWatts: telemetry.power.first { $0.key == "PDTR" }?.value,
            handedToSystem: telemetry.curve.isEmpty || telemetry.curve.allSatisfy(\.handedToSystem),
            latched: telemetry.safety.latched,
            profile: telemetry.profile
        )
    }

    public static func hottestCPU(_ telemetry: TelemetryDTO) -> Double? {
        StressSample(seconds: 0, phase: .load, telemetry: telemetry).cpuMaximum
    }
}

// MARK: - Summary

/// How the curve reacted, from the samples of one run.
public struct StressSummary: Codable, Equatable, Sendable {
    /// The "steady" figures average the last 30 s of load.
    public static let steadyWindowSeconds = 30.0
    /// The fans "speed up" once 300 RPM above where they started.
    public static let rampThresholdRPM = 300.0
    /// Back "at rest" within 100 RPM of where they started.
    public static let restMarginRPM = 100.0

    public var startCPU: Double?
    public var peakCPU: Double?
    public var steadyCPU: Double?
    public var peakGPU: Double?
    public var startRPM: Double
    public var peakRPM: Double
    public var peakPercent: Double?
    public var steadyRPM: Double?
    /// Standard deviation of the speed over the steady window: a high value
    /// means the fan hunts (more smoothing, hysteresis or a slower fall).
    public var steadySpreadRPM: Double?
    /// When the fans sped up, and the CPU temperature then. Nil: never.
    public var rampSeconds: Double?
    public var rampCPU: Double?
    /// When the fans reached 90 % of their rise.
    public var nearPeakSeconds: Double?
    /// Seconds after the load stopped until the fans were back at rest. Nil
    /// when they never sped up, or did not come back within the cool-down
    /// (`returnedToRest` tells which).
    public var restSeconds: Double?
    public var returnedToRest: Bool
    public var endCPU: Double?
    public var peakWatts: Double?
    public var tripped: Bool

    public init?(samples: [StressSample]) {
        let load = samples.filter { $0.phase == .load }
        let cool = samples.filter { $0.phase == .cool }
        guard let first = load.first, let loadEnd = load.last?.seconds else { return nil }
        let steady = load.filter { $0.seconds >= loadEnd - Self.steadyWindowSeconds }
        let rpms = samples.map { $0.fanRPM ?? 0 }
        startCPU = first.cpuMaximum
        peakCPU = samples.compactMap(\.cpuMaximum).max()
        steadyCPU = Self.mean(steady.compactMap(\.cpuMaximum))
        peakGPU = samples.compactMap(\.gpuMaximum).max()
        startRPM = first.fanRPM ?? 0
        peakRPM = rpms.max() ?? 0
        peakPercent = samples.compactMap(\.fanPercent).max()
        let steadyRPMs = steady.compactMap(\.fanRPM)
        steadyRPM = Self.mean(steadyRPMs)
        if let mean = steadyRPM, steadyRPMs.count > 1 {
            steadySpreadRPM = (steadyRPMs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(steadyRPMs.count)).squareRoot()
        }
        let start = startRPM
        let ramp = load.first { ($0.fanRPM ?? 0) > start + Self.rampThresholdRPM }
        rampSeconds = ramp?.seconds
        rampCPU = ramp?.cpuMaximum
        if peakRPM > start + Self.rampThresholdRPM {
            let target = start + 0.9 * (peakRPM - start)
            nearPeakSeconds = samples.first { ($0.fanRPM ?? 0) >= target }?.seconds
        }
        let rest = ramp == nil ? nil : cool.first { ($0.fanRPM ?? 0) <= start + Self.restMarginRPM }
        restSeconds = rest.map { $0.seconds - loadEnd }
        returnedToRest = ramp == nil || rest != nil
        endCPU = samples.last?.cpuMaximum
        peakWatts = samples.compactMap(\.packageWatts).max()
        tripped = samples.contains(where: \.latched)
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

public struct StressResult: Codable, Equatable, Sendable {
    public var profile: String
    public var startedAt: Date
    public var plan: StressPlan
    public var samples: [StressSample]
    /// False when the run was stopped before the end of the cool-down.
    public var completed: Bool

    public init(profile: String, startedAt: Date, plan: StressPlan, samples: [StressSample], completed: Bool) {
        self.profile = profile
        self.startedAt = startedAt
        self.plan = plan
        self.samples = samples
        self.completed = completed
    }

    public var summary: StressSummary? { StressSummary(samples: samples) }

    /// The profile that took over during the run (from the popover, an
    /// automation rule or the command line), if any: the samples after it do not
    /// measure `profile`. Changes while the safety guard is engaged don't count.
    public var profileChange: String? {
        samples.first { !$0.latched && $0.profile != nil && $0.profile != profile }?.profile
    }

    /// One row per sample, every profile in one table, for a chart.
    public static func csv(_ results: [StressResult]) -> String {
        func cell(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "" }
        var lines = ["profile,phase,seconds,cpu_max,gpu_max,curve_input,curve_effective,fan_rpm,fan_percent,target_rpm,package_w,macos,latched"]
        for result in results {
            for s in result.samples {
                lines.append([result.profile, s.phase.rawValue, cell(s.seconds), cell(s.cpuMaximum), cell(s.gpuMaximum),
                              cell(s.curveInput), cell(s.curveEffective), cell(s.fanRPM), cell(s.fanPercent), cell(s.targetRPM),
                              cell(s.packageWatts), s.handedToSystem ? "1" : "0", s.latched ? "1" : "0"].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Heat load

/// Vector FMA chains on every CPU core and, unless CPU only, a Metal compute
/// kernel: about twice the power of a CPU-only load (~36 W vs ~18 W on an M1
/// Pro). Runs on threads of this process until `stop()`.
public protocol StressLoad: Sendable {
    func start()
    func stop()
}

public final class StressHeatLoad: StressLoad, @unchecked Sendable {
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let kind: StressLoadKind

    public init(kind: StressLoadKind) {
        self.kind = kind
    }

    deinit { stop() }

    private var isRunning: Bool { running.withLock { $0 } }

    public func start() {
        let alreadyRunning = running.withLock { state -> Bool in
            defer { state = true }
            return state
        }
        guard !alreadyRunning else { return }
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            spawn { [self] in burnCPU() }
        }
        if kind == .cpuAndGPU {
            spawn { [self] in burnGPU() }
        }
    }

    public func stop() {
        running.withLock { $0 = false }
    }

    private func spawn(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        // User-initiated work runs on the performance cores.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // Independent chains that converge (x → 1), so values stay finite.
    private func burnCPU() {
        var a = (0..<8).map { SIMD8<Float>(repeating: Float($0)) }
        let b = SIMD8<Float>(repeating: 0.9999999), c = SIMD8<Float>(repeating: 0.0000001)
        while isRunning {
            for _ in 0..<200_000 { for i in 0..<8 { a[i] = a[i] * b + c } }
            if a[0][0] < -1 { print(a[7]) }  // never true; keeps the loop alive
        }
    }

    // Dependent FMAs over a large grid, resubmitted until stopped.
    private func burnGPU() {
        let source = """
        kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float x = float(id) * 1e-6, y = 0.9999999;
            for (int i = 0; i < 4096; i++) { x = fma(x, y, 1e-7); y = fma(y, 0.9999999, 1e-7); }
            out[id] = x + y;
        }
        """
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "burn"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue(),
              let buffer = device.makeBuffer(length: (1 << 20) * 4, options: .storageModePrivate) else {
            return  // CPU load only
        }
        while isRunning {
            guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchThreads(MTLSize(width: 1 << 20, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
    }
}

// MARK: - Runner

/// Runs the plan on each profile in turn: activate it, wait for the Mac to
/// cool to the starting point, load, cool down. Blocks the calling thread;
/// `cancel()` from any thread stops it within a fraction of a second. The
/// profile active before the run is restored at the end, even when stopped.
/// If another profile takes over meanwhile, the run stops: its samples would no
/// longer measure the profile under test.
public final class StressRunner: @unchecked Sendable {
    public enum Event: Sendable {
        /// Waiting for the CPU to cool to `target` before `profile` starts.
        case settling(profile: String, cpu: Double?, target: Double, elapsed: Int)
        case started(profile: String, index: Int, count: Int)
        case sample(profile: String, StressSample)
        /// Another profile took over during the run of `profile`: the run stops
        /// there, and the profiles after it are not run.
        case profileChanged(profile: String, to: String)
        case finished(StressResult)
        case restored(profile: String)
    }

    private let telemetry: @Sendable () throws -> TelemetryDTO
    private let activate: @Sendable (String) throws -> Void
    private let makeLoad: @Sendable (StressLoadKind) -> any StressLoad
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    public init(telemetry: @escaping @Sendable () throws -> TelemetryDTO, activate: @escaping @Sendable (String) throws -> Void,
                load: @escaping @Sendable (StressLoadKind) -> any StressLoad = { StressHeatLoad(kind: $0) }) {
        self.telemetry = telemetry
        self.activate = activate
        self.makeLoad = load
    }

    public func cancel() { cancelled.withLock { $0 = true } }
    public var isCancelled: Bool { cancelled.withLock { $0 } }

    /// Returns the finished runs; one stopped midway is included with
    /// `completed == false` when it has samples under load.
    @discardableResult
    public func run(profiles: [String], plan: StressPlan, onEvent: (Event) -> Void = { _ in }) throws -> [StressResult] {
        let initial = try telemetry()
        let original = initial.profile
        let baseline = StressSample.hottestCPU(initial)
        let load = makeLoad(plan.load)
        defer {
            load.stop()
            if (try? activate(original)) != nil { onEvent(.restored(profile: original)) }
        }
        var results: [StressResult] = []
        var takenOver = false
        for (index, profile) in profiles.enumerated() where !isCancelled && !takenOver {
            try activate(profile)
            if let baseline { settle(profile: profile, target: baseline + StressPlan.settleMarginCelsius, plan: plan, onEvent: onEvent) }
            guard wait(seconds: plan.holdSeconds) else { break }
            onEvent(.started(profile: profile, index: index, count: profiles.count))
            let startedAt = Date()
            var samples: [StressSample] = []
            func record(_ phase: StressPhase) {
                guard let snapshot = try? telemetry() else { return }
                let sample = StressSample(seconds: Date().timeIntervalSince(startedAt).rounded(), phase: phase, telemetry: snapshot)
                samples.append(sample)
                onEvent(.sample(profile: profile, sample))
                if !takenOver, !sample.latched, let active = sample.profile, active != profile {
                    takenOver = true
                    onEvent(.profileChanged(profile: profile, to: active))
                }
            }
            record(.load)
            if !takenOver { load.start() }
            var tick = 1
            while !isCancelled, !takenOver, Double(tick) * plan.sampleInterval <= Double(plan.loadSeconds) {
                guard wait(until: startedAt.addingTimeInterval(Double(tick) * plan.sampleInterval)) else { break }
                record(.load)
                tick += 1
            }
            load.stop()
            let total = Double(plan.loadSeconds + plan.coolSeconds)
            while !isCancelled, !takenOver, Double(tick) * plan.sampleInterval <= total {
                guard wait(until: startedAt.addingTimeInterval(Double(tick) * plan.sampleInterval)) else { break }
                record(.cool)
                tick += 1
            }
            guard samples.count > 1 || takenOver else { break }
            let result = StressResult(profile: profile, startedAt: startedAt, plan: plan, samples: samples,
                                      completed: !isCancelled && !takenOver)
            results.append(result)
            onEvent(.finished(result))
        }
        return results
    }

    private func settle(profile: String, target: Double, plan: StressPlan, onEvent: (Event) -> Void) {
        let start = Date()
        let deadline = start.addingTimeInterval(Double(plan.settleSeconds))
        while Date() < deadline, !isCancelled {
            guard let snapshot = try? telemetry(), let cpu = StressSample.hottestCPU(snapshot), cpu > target else { return }
            onEvent(.settling(profile: profile, cpu: cpu, target: target, elapsed: Int(Date().timeIntervalSince(start))))
            guard wait(until: min(Date().addingTimeInterval(5), deadline)) else { return }
        }
    }

    private func wait(seconds: Double) -> Bool {
        wait(until: Date().addingTimeInterval(seconds))
    }

    /// Sleeps in short slices so a cancel is seen quickly; false if cancelled.
    private func wait(until deadline: Date) -> Bool {
        while !isCancelled {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return true }
            Thread.sleep(forTimeInterval: min(left, 0.1))
        }
        return false
    }
}
