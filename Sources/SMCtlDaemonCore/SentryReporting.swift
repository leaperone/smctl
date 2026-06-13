import Foundation
import OSLog
import Sentry
import SMCtlProtocol

private let sentryLogger = Logger(subsystem: "one.leaper.smctl", category: "sentry")

enum SentryReporter {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var started = false

    static func startIfConfigured(config: SentryConfig) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SMCTL_SENTRY_DISABLED"] != "1" else { return }

        let dsn = firstNonEmpty(environment["SMCTL_SENTRY_DSN"], config.dsn)

        guard let dsn else { return }

        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let sentryEnvironment = firstNonEmpty(environment["SMCTL_SENTRY_ENVIRONMENT"], config.environment) ?? "production"
        let tracesSampleRate = min(max(config.traces_sample_rate, 0), 1)

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = sentryEnvironment
            options.releaseName = "smctl@\(SMCtlProtocolInfo.version)"
            options.debug = config.debug
            options.sendDefaultPii = false
            options.tracesSampleRate = NSNumber(value: tracesSampleRate)
            options.beforeSend = { event in
                event.user = nil
                event.serverName = nil
                if var tags = event.tags {
                    tags.removeValue(forKey: "server_name")
                    tags.removeValue(forKey: "user")
                    event.tags = tags
                }
                return event
            }
        }

        sentryLogger.notice("Sentry crash/error reporting enabled for environment \(sentryEnvironment, privacy: .public)")
    }

    static func capture(_ error: Error, context: String) {
        guard isStarted else { return }
        let report = NSError(
            domain: "one.leaper.smctl.daemon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(context): \(String(describing: error))"]
        )
        SentrySDK.capture(error: report)
    }

    private static var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { value in
                guard let value else { return false }
                return !value.isEmpty
            } ?? nil
    }
}
