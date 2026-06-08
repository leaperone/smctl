import Foundation
import OSLog
import PolicyEngine
import SMCtlProtocol

private let alertLogger = Logger(subsystem: "one.leaper.smctl", category: "alert")

/// TOML mapping for one `[[alert]]` table. Mirrors `FanCurveConfig`'s relationship
/// to `FanCurve`: this is the on-disk shape, `rule` is the engine's view.
///
/// Defensive decoding throughout: a hand-edited or older config with missing keys
/// must never blow up `loadConfig` (which would silently reset the whole file).
struct AlertConfig: Codable, Equatable, Sendable {
    var name: String
    var on: String
    var sensor: String?
    var above: Double?
    var forSeconds: Double?
    var cooldown: Double?
    var resolve: Bool?
    var action: String?
    var url: String?
    var command: [String]?

    enum CodingKeys: String, CodingKey {
        case name, on, sensor, above
        case forSeconds = "for"
        case cooldown, resolve, action, url, command
    }

    init(
        name: String,
        on: String,
        sensor: String? = nil,
        above: Double? = nil,
        forSeconds: Double? = nil,
        cooldown: Double? = nil,
        resolve: Bool? = nil,
        action: String? = nil,
        url: String? = nil,
        command: [String]? = nil
    ) {
        self.name = name
        self.on = on
        self.sensor = sensor
        self.above = above
        self.forSeconds = forSeconds
        self.cooldown = cooldown
        self.resolve = resolve
        self.action = action
        self.url = url
        self.command = command
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        on = try container.decodeIfPresent(String.self, forKey: .on) ?? ""
        sensor = try container.decodeIfPresent(String.self, forKey: .sensor)
        above = try container.decodeIfPresent(Double.self, forKey: .above)
        forSeconds = try container.decodeIfPresent(Double.self, forKey: .forSeconds)
        cooldown = try container.decodeIfPresent(Double.self, forKey: .cooldown)
        resolve = try container.decodeIfPresent(Bool.self, forKey: .resolve)
        action = try container.decodeIfPresent(String.self, forKey: .action)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        command = try container.decodeIfPresent([String].self, forKey: .command)
    }

    /// The engine rule, or nil when the config is malformed (unknown trigger kind
    /// or empty name) — invalid rules are dropped, never crash the daemon.
    var rule: AlertRule? {
        guard !name.isEmpty, let kind = AlertTriggerKind(rawValue: on) else { return nil }
        return AlertRule(
            name: name,
            trigger: AlertTrigger(kind: kind, sensor: sensor, above: above),
            forSeconds: forSeconds ?? 0,
            cooldownSeconds: cooldown ?? 300,
            resolve: resolve ?? false
        )
    }

    var resolvedAction: AlertAction {
        switch action {
        case "webhook":
            if let url, !url.isEmpty { return .webhook(url) }
            return .log
        case "exec":
            if let command, !command.isEmpty { return .exec(command) }
            return .log
        default:
            return .log
        }
    }
}

enum AlertAction: Equatable, Sendable {
    case webhook(String)
    case exec([String])
    case log
}

/// Executes alert actions off the daemon's state queue. Three hard rules, because
/// an alert action must NEVER compromise the daemon's real job:
///   1. Isolation — runs on its own queue; never blocks the 1 Hz fan loop.
///   2. Bounded — every exec/webhook has a timeout; a concurrency cap prevents a
///      stuck endpoint from piling up processes.
///   3. Silent failure — a failed action is logged, never propagated.
///
/// Security note: exec runs as root (the daemon is root). The trust boundary is
/// "whoever can edit the root-owned /etc/smctl/config.toml" — identical to
/// `allow_below_minimum`. Commands run via argv arrays only; no shell, no string
/// interpolation into a shell, so there is no command-injection surface.
final class AlertActionRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "one.leaper.smctl.alert.actions", attributes: .concurrent)
    private let slots: DispatchSemaphore
    private let execTimeout: TimeInterval
    private let webhookTimeout: TimeInterval

    init(maxConcurrent: Int = 4, execTimeout: TimeInterval = 10, webhookTimeout: TimeInterval = 15) {
        self.slots = DispatchSemaphore(value: max(1, maxConcurrent))
        self.execTimeout = execTimeout
        self.webhookTimeout = webhookTimeout
    }

    func run(event: AlertEvent, action: AlertAction) {
        queue.async { [weak self] in
            guard let self else { return }
            // Non-blocking admission: if all slots are busy, drop rather than queue
            // unboundedly. A stuck webhook must not let events accumulate forever.
            guard self.slots.wait(timeout: .now()) == .success else {
                alertLogger.error("Alert '\(event.ruleName, privacy: .public)' action dropped: all action slots busy")
                return
            }
            defer { self.slots.signal() }
            switch action {
            case .log:
                self.logAction(event)
            case .webhook(let url):
                self.runWebhook(url: url, event: event)
            case .exec(let command):
                self.runExec(command: command, event: event)
            }
        }
    }

    private func logAction(_ event: AlertEvent) {
        alertLogger.notice("Alert \(event.kind.rawValue, privacy: .public) '\(event.ruleName, privacy: .public)': \(event.reason, privacy: .public)")
    }

    private func runWebhook(url urlString: String, event: AlertEvent) {
        guard let url = URL(string: urlString) else {
            alertLogger.error("Alert '\(event.ruleName, privacy: .public)' webhook skipped: invalid URL")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: webhookTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("smctl-alert/\(SMCtlProtocolInfo.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = webhookBody(event)

        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                alertLogger.error("Alert '\(event.ruleName, privacy: .public)' webhook failed: \(String(describing: error), privacy: .public)")
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                alertLogger.error("Alert '\(event.ruleName, privacy: .public)' webhook HTTP \(http.statusCode, privacy: .public)")
            }
            semaphore.signal()
        }
        task.resume()
        // Bound the wait so a hung connection still frees its slot.
        if semaphore.wait(timeout: .now() + webhookTimeout + 2) == .timedOut {
            task.cancel()
            alertLogger.error("Alert '\(event.ruleName, privacy: .public)' webhook timed out")
        }
    }

    private func webhookBody(_ event: AlertEvent) -> Data? {
        var payload: [String: Any] = [
            "rule": event.ruleName,
            "kind": event.kind.rawValue,
            "trigger": event.triggerKind.rawValue,
            "reason": event.reason,
            "host": ProcessInfo.processInfo.hostName,
            "timestamp": ISO8601DateFormatter().string(from: event.timestamp)
        ]
        if let value = event.value { payload["value"] = value }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private func runExec(command: [String], event: AlertEvent) {
        let substituted = command.map { substitute($0, event: event) }
        guard let executable = substituted.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(substituted.dropFirst())
        // Pass structured fields via the environment too, so scripts can read them
        // without positional-argument juggling.
        var environment = ProcessInfo.processInfo.environment
        environment["SMCTL_ALERT_NAME"] = event.ruleName
        environment["SMCTL_ALERT_KIND"] = event.kind.rawValue
        environment["SMCTL_ALERT_TRIGGER"] = event.triggerKind.rawValue
        environment["SMCTL_ALERT_REASON"] = event.reason
        if let value = event.value { environment["SMCTL_ALERT_VALUE"] = String(value) }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            alertLogger.error("Alert '\(event.ruleName, privacy: .public)' exec failed to launch '\(executable, privacy: .public)': \(String(describing: error), privacy: .public)")
            return
        }
        // Enforce a timeout: kill the process if it overruns.
        let deadline = DispatchTime.now() + execTimeout
        let killer = DispatchWorkItem { [weak process] in
            if process?.isRunning == true {
                process?.terminate()
                alertLogger.error("Alert '\(event.ruleName, privacy: .public)' exec timed out; terminated")
            }
        }
        queue.asyncAfter(deadline: deadline, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        if process.terminationStatus != 0 {
            alertLogger.error("Alert '\(event.ruleName, privacy: .public)' exec exited \(process.terminationStatus, privacy: .public)")
        }
    }

    /// Substitutes {name}/{kind}/{trigger}/{reason}/{value} placeholders. Used only
    /// for argv elements — never assembled into a shell command line.
    private func substitute(_ template: String, event: AlertEvent) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{name}", with: event.ruleName)
        result = result.replacingOccurrences(of: "{kind}", with: event.kind.rawValue)
        result = result.replacingOccurrences(of: "{trigger}", with: event.triggerKind.rawValue)
        result = result.replacingOccurrences(of: "{reason}", with: event.reason)
        result = result.replacingOccurrences(of: "{value}", with: event.value.map { String($0) } ?? "")
        return result
    }
}
