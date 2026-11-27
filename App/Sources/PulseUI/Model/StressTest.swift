import Foundation
import Observation
import SMCtlClient
import SMCtlProtocol

/// The last stress test of each curve this session, so a run after a tweak
/// can be compared with the one before.
@MainActor
final class StressHistory {
    static let shared = StressHistory()
    private var last: [String: StressResult] = [:]

    func last(for profile: String) -> StressResult? { last[profile] }
    func record(_ result: StressResult) { last[result.profile] = result }
}

extension StressTestModel: Identifiable {}

/// A stress test of one curve from the app: the same engine as
/// `pulse fan stress`, run off the main thread, its events forwarded here.
@MainActor
@Observable
public final class StressTestModel {
    public enum Duration: Int, CaseIterable, Identifiable {
        case one = 60, two = 120, five = 300
        public var id: Int { rawValue }
        var title: String { "\(rawValue / 60) min" }
    }

    public enum State: Equatable {
        case ready
        /// Waiting for the CPU to cool to the starting temperature of the previous run.
        case settling(cpu: Double?, target: Double)
        case running(StressPhase)
        case stopping
        case finished
        case failed(String)
    }

    public let profile: String
    public let title: String
    public var duration: Duration = .two
    public var load: StressLoadKind = .cpuAndGPU
    public private(set) var state: State = .ready
    public private(set) var samples: [StressSample] = []
    public private(set) var result: StressResult?
    /// The previous run of this curve, drawn behind the current one.
    public private(set) var previous: StressResult?
    /// The profile that took over during the run, which stopped it.
    public private(set) var takenOverBy: String?

    @ObservationIgnored private let service: (any PulseService)?
    /// Told when the run starts and ends, to lock the profile meanwhile.
    @ObservationIgnored private weak var store: PulseStore?
    @ObservationIgnored private var runner: StressRunner?
    @ObservationIgnored private let onFinish: @MainActor () -> Void

    /// The cool-down recorded after the load: as long as the load, at most 2 min.
    var coolSeconds: Int { min(duration.rawValue, 120) }
    var plan: StressPlan {
        StressPlan(loadSeconds: duration.rawValue, coolSeconds: coolSeconds, settleSeconds: 300, load: load)
    }
    /// The plan of the run on screen (the options may have changed since).
    var shownPlan: StressPlan { result?.plan ?? (isRunning ? activePlan : plan) }
    @ObservationIgnored private var activePlan = StressPlan()

    var isRunning: Bool {
        switch state {
        case .settling, .running, .stopping: true
        default: false
        }
    }

    var summary: StressSummary? { result?.summary ?? StressSummary(samples: samples) }
    var elapsed: Double { samples.last?.seconds ?? 0 }

    init(profile: String, title: String, service: (any PulseService)?, store: PulseStore? = nil,
         onFinish: @escaping @MainActor () -> Void = {}) {
        self.profile = profile
        self.title = title
        self.service = service
        self.store = store
        self.onFinish = onFinish
        self.previous = StressHistory.shared.last(for: profile)
    }

    /// A finished run with sample data, for snapshots and previews.
    public static func preview(profile: String, title: String, samples: [StressSample], previous: [StressSample]?) -> StressTestModel {
        let model = StressTestModel(profile: profile, title: title, service: nil)
        let plan = StressPlan(loadSeconds: 120, coolSeconds: 120)
        model.samples = samples
        model.result = StressResult(profile: profile, startedAt: Date(), plan: plan, samples: samples, completed: true)
        model.previous = previous.map { StressResult(profile: profile, startedAt: Date().addingTimeInterval(-600), plan: plan, samples: $0, completed: true) }
        model.state = .finished
        return model
    }

    func start() {
        guard let service, !isRunning else { return }
        if let result, result.profileChange == nil { previous = result }
        result = nil
        takenOverBy = nil
        samples = []
        activePlan = plan
        state = .running(.load)
        let runner = StressRunner(telemetry: { try service.telemetry() }, activate: { try service.activate(profile: $0) })
        self.runner = runner
        store?.stressTestDidStart(self)
        let profile = self.profile
        let plan = activePlan
        Thread.detachNewThread { [weak self] in
            do {
                try runner.run(profiles: [profile], plan: plan) { event in
                    // The main queue keeps the events in order.
                    DispatchQueue.main.async { self?.handle(event) }
                }
                DispatchQueue.main.async { self?.didEnd(error: nil) }
            } catch {
                let message = PulseStore.describe(error)
                DispatchQueue.main.async { self?.didEnd(error: message) }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        state = .stopping
        runner?.cancel()
    }

    private func handle(_ event: StressRunner.Event) {
        switch event {
        case .settling(_, let cpu, let target, _):
            state = .settling(cpu: cpu, target: target)
        case .started:
            state = .running(.load)
        case .sample(_, let sample):
            samples.append(sample)
            if state != .stopping { state = .running(sample.phase) }
        case .profileChanged(_, let active):
            takenOverBy = active
        case .finished(let result):
            self.result = result
            // A run another profile took over doesn't measure this curve: never compare with it.
            if result.profileChange == nil { StressHistory.shared.record(result) }
        case .restored:
            break
        }
    }

    private func didEnd(error: String?) {
        runner = nil
        store?.stressTestDidEnd(self)
        if let error {
            state = .failed(error)
        } else {
            state = result == nil ? .ready : .finished
        }
        onFinish()
    }
}

extension StressTestModel {
    /// A simulated 2 min run on a Mac mini: the CPU climbs to `peakCPU`, the
    /// curve's input follows with a lag, the fan reaches `peakRPM`.
    public static func simulatedSamples(peakCPU: Double, peakRPM: Double, rampAt: Double) -> [StressSample] {
        stride(from: 0.0, through: 240, by: 2).map { t in
            let heating = t <= 120
            let cpu = heating ? 40 + (peakCPU - 40) * (1 - exp(-t / 18)) : 45 + (peakCPU - 45) * exp(-(t - 120) / 8)
            let curve = heating ? 38 + (peakCPU - 12 - 38) * (1 - exp(-t / 30)) : 40 + (peakCPU - 12 - 40) * exp(-(t - 120) / 25)
            let rise = heating ? max(0, min(1, (t - rampAt) / 40)) : max(0, 1 - (t - 120) / 60)
            let rpm = 1000 + (peakRPM - 1000) * rise + (heating && t > rampAt + 40 ? (t.truncatingRemainder(dividingBy: 8) < 4 ? 60 : -60) : 0)
            return StressSample(seconds: t, phase: heating ? .load : .cool, cpuMaximum: cpu, gpuMaximum: heating ? 35 + 15 * (1 - exp(-t / 40)) : 50 - 8 * (t - 120) / 120,
                                curveInput: curve + 2, curveEffective: curve, fanRPM: rpm, fanPercent: (rpm - 1000) / 39, targetRPM: rpm,
                                packageWatts: heating ? 31 : 3, handedToSystem: rpm <= 1000, latched: false)
        }
    }
}
